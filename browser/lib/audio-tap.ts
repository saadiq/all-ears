import { isCurrentEpoch } from "./epoch";
import {
  liveTracks,
  setTrackSink,
  trackProvenance,
  webAudioTracks,
  type TrackProvenanceRecord,
  type TrackSink,
} from "./rtc-hook";
import { meetDecodeSource } from "./meet-decode";
import {
  SeamArbiter,
  seamUsesReceiverTracks,
  seamOrderFor,
  seamTracksToAdopt,
  seamTracksToRetire,
  admitReceiverTrack,
  type SeamId,
} from "./capture-seams";
import type { PlatformAdapter } from "./identity/adapter";
import { flushAttribution, recordAttribution } from "./attribution-recorder";
import {
  postToIsolated,
  syntheticParticipant,
  type ParticipantOrigin,
  type ParticipantRef,
  type Platform,
} from "./protocol";
import type { PlatformParticipantId } from "./identity/adapter";
import { perfDetailEnabled, perfEnabled } from "./perf-main";
import {
  audioLog,
  captureMetrics,
  DEBUG_AUDIO_NOW,
  SPEAK_THRESHOLD,
  type AudioLogEntry,
} from "./capture-instrumentation";
import {
  FRAME_SAMPLES,
  LinearResampler,
  RING_CAPACITY,
  RingBuffer,
  SilentCaptureWatchdog,
  silentReport,
  TARGET_SAMPLE_RATE,
  trackProcessorSource,
  type AudioDataLike,
  type FrameSource,
  type FrameSourceFactory,
} from "./frame-pipeline";

// The per-epoch capture sink. Owns the N→N map: one live MediaStreamTrack →
// one isolated pipeline. Every pipeline records under a stable per-track
// handle (`t<n>`); identity never rides the source id — a resolved platform
// id flows to the daemon as an attendee upsert linking the handle's source
// (see handleIdentity), so identity can never block or restart audio.
//
// Each pipeline: a platform-dependent frame source → downmix → resample to
// 16 kHz mono → Int16 frames → a bounded ring buffer → postToIsolated. Two
// frame sources feed the same downstream logic (see §Frame sources below):
// MediaStreamTrackProcessor for Zoom/Teams, and an AudioDecoder fed by
// rtc-hook.ts's Meet encoded-audio tee for Meet. Neither is ever connected to
// an AudioContext destination: no playback, no feedback into the user's mic.

/**
 * Where a pipeline's frames come from. Receiver-based seams carry the RTC
 * context the adapter's `identify()` needs; the others have none, so their
 * sources stay anonymous until speaking correlation names their owner.
 */
interface PipelineOrigin {
  seam: SeamId;
  rtc?: { stream: MediaStream };
  /** Source track id when the captured track is a clone (non-receiver seams). */
  sourceTrackId?: string;
}

interface Pipeline {
  participant: ParticipantRef;
  generation: number;
  origin: PipelineOrigin;
  stop(): void;
  /** Whether this pipeline has decoded at least one audio frame (debug report). */
  receiving(): boolean;
}

interface CaptureConfig {
  epoch: number;
  platform: Platform;
  adapter: PlatformAdapter | null;
}

interface TeardownWindow extends Window {
  __earsTeardown?: () => void;
}

const pipelines = new Map<MediaStreamTrack, Pipeline>();
// Which seam this call is capturing through, and the escalation state machine
// that moves off a seam producing no audio. Rebuilt per epoch in initCapture.
let arbiter: SeamArbiter | undefined;
// Registry track id → the clone we captured it under, for seams whose tracks
// come from somewhere other than the `ontrack` hook. Keyed by the ORIGINAL id
// so a re-adoption sweep doesn't capture the same source track twice; the
// clone's own id differs and is what reaches `pipelines`.
const adoptedSeamTracks = new Map<string, MediaStreamTrack>();
const generations = new Map<string, number>(); // capture handle → segment counter
// Source handles: one short opaque slug (`t<n>`) per admitted track, minted at
// first admission and NEVER changed for the track's life (R3). The earsd
// source id is `browser:<platform>:<slug>` — a handle on a captured track,
// carrying no identity guess. Whose voice a source carries lives exclusively
// in the attendee/speaker layer (participant-identified upserts, and the
// daemon's reconciled `[[speaker]]` map). Keyed by the SOURCE track id
// (`origin.sourceTrackId` for clone-captured seams) so a re-adoption — epoch
// handoff, reconcile sweep, fresh clone of the same page track — keeps the
// handle. Bounded by the tracks seen in the page's life; never cleared.
let trackHandleCounter = 0;
const trackHandles = new Map<string, ParticipantRef>();
// track.id → the handle its pipeline captured under, so an identity that
// confirms by track id (adapter onIdentity) — even after the track died —
// can be translated back to the source whose audio is on disk.
const participantsByTrackId = new Map<string, ParticipantRef>();
let cfg: CaptureConfig;

// True once ANY participant on this call has produced a decoded frame. Gates the
// per-track silent warning: Meet legitimately delivers no audio for an unmuted
// but silent participant (DTX / noise suppression), so "unmuted + no frames" is
// not on its own proof of breakage. Only escalate to a loud "SILENT" warning
// when nothing has decoded anywhere on the call (see silentReport). Not reset
// by initCapture, so it survives same-module epoch handoffs (a capture toggle
// off/on mid-call must not forget that audio once flowed). It does NOT survive
// a genuine re-injection: each injected epoch loads a fresh module instance
// (see rtc-hook.ts's header), so the flag starts false there and the silent
// warning is merely re-armed — a false negative it may repeat, never suppress.
let anyAudioDecodedThisCall = false;

// Low-frequency safety net: sweep liveTracks() for any track this epoch owns
// but has no pipeline for, and (re)adopt it. Covers a new-attendee track whose
// dispatchTrack landed between epoch handoff replays, and any pipeline that
// died without the track ending (belt-and-braces alongside decoder restart).
const RECONCILE_INTERVAL_MS = 3000;
let reconcileTimer: ReturnType<typeof setInterval> | undefined;

/**
 * Take over capture for `config.epoch`. Tears down the previous epoch's
 * pipelines (no doubling), points the hook's sink here, and replays the live
 * track registry (no dropped streams) so a re-inject is seamless.
 */
export function initCapture(config: CaptureConfig): void {
  cfg = config;

  const g = window as unknown as TeardownWindow;
  const prevTeardown = g.__earsTeardown;
  const epochAdapter = config.adapter;
  g.__earsTeardown = (): void => {
    teardownAll();
    // The epoch owns its adapter: hook.content.ts mints a fresh one per epoch,
    // and tearing the epoch down disposes it, so identity state (the Meet
    // engine's bindings, roster, correlators) never outlives the capture it
    // served (refactor plan R2; bug B10). Captured in this closure, not read
    // from `cfg` — by the time a superseding initCapture runs this teardown,
    // `cfg` already names the NEW epoch's adapter. After teardownAll so the
    // final attribution flush precedes disposal.
    try {
      epochAdapter?.dispose?.();
    } catch {
      // best-effort — identity teardown must never affect capture teardown
    }
  };
  prevTeardown?.(); // stop the superseded epoch before we start emitting

  arbiter = new SeamArbiter(seamOrderFor(config.platform));
  adoptedSeamTracks.clear();

  setTrackSink(sink);
  cfg.adapter?.onIdentity?.(handleIdentity);
  // Forward roster names (id → display name) the adapter resolves to the daemon,
  // decoupled from track capture, so a participant's name reaches session.toml
  // even when the speaking-onset correlation never tied them to a track (#23).
  cfg.adapter?.onRoster?.((entries) => {
    if (!isCurrentEpoch(cfg.epoch) || entries.length === 0) return;
    postToIsolated({ kind: "participant-roster", platform: cfg.platform, entries });
  });

  // Catch-up: adopt tracks that were already live when this epoch loaded.
  for (const [track, rec] of liveTracks()) {
    sink(track, rec.stream);
  }

  // Arm the reconciler for this epoch (prevTeardown cleared any prior timer).
  if (reconcileTimer !== undefined) clearInterval(reconcileTimer);
  reconcileTimer = setInterval(reconcile, RECONCILE_INTERVAL_MS);

  postToIsolated({ kind: "status", text: `capture epoch ${config.epoch} active (${config.platform})` });
  console.debug(`[ears][capture] capture active — epoch ${config.epoch}, platform ${config.platform}`);
}

/** Capture-side state for the popup's debug report (see hook.content.ts). */
export function captureDebugState(): {
  platform: Platform | undefined;
  epoch: number | undefined;
  pipelineCount: number;
  anyAudioDecodedThisCall: boolean;
  /** Active seam and whether a frame has proved it — the first thing to read
   * when a call records silence (journal #100-#106). */
  seam: { active: string; proven: boolean; exhausted: boolean } | undefined;
  participants: Array<{
    id: string;
    origin: ParticipantOrigin;
    generation: number;
    receiving: boolean;
    seam: SeamId;
    sourceTrackId?: string;
  }>;
} {
  return {
    platform: cfg?.platform,
    epoch: cfg?.epoch,
    pipelineCount: pipelines.size,
    anyAudioDecodedThisCall,
    seam: arbiter
      ? { active: arbiter.active, proven: arbiter.proven, exhausted: arbiter.exhausted }
      : undefined,
    participants: [...pipelines.values()].map((p) => ({
      id: p.participant.id,
      origin: p.participant.kind,
      generation: p.generation,
      receiving: p.receiving(),
      seam: p.origin.seam,
      sourceTrackId: p.origin.sourceTrackId,
    })),
  };
}

/**
 * A confirmed platform identity for a captured track — pushed by an adapter
 * (Meet's speaking-onset correlation, see lib/identity/meet.ts) at any point
 * in the track's life, including after it ended. The pipeline is untouched:
 * the source keeps its handle, no frames are lost, and no spurious
 * `participant-left` is stamped (R3; the restart this replaced was bug B11).
 * The identity is forwarded as an attendee upsert linking this source.
 */
function handleIdentity(trackId: string, id: PlatformParticipantId): void {
  if (!isCurrentEpoch(cfg.epoch)) return;
  const captured = participantsByTrackId.get(trackId);
  if (!captured) return;
  postIdentity(trackId, captured.id, id);
}

/** Forward a confirmed identity: an attendee upsert joining the platform id
 * (and display name, when the adapter has one) to the source handle whose
 * audio is on disk. Recorded in the flight log with the track id so a replay
 * can join it to the engine's `provisional-binding` events (the cause). */
function postIdentity(trackId: string, captureId: string, id: PlatformParticipantId): void {
  const displayName = cfg.adapter?.displayName?.(id);
  recordAttribution({
    type: "identity-link",
    t: Date.now(),
    trackId,
    captureId,
    participantId: id,
  });
  postToIsolated({
    kind: "participant-identified",
    platform: cfg.platform,
    participantId: id,
    captureId,
    ...(displayName ? { displayName } : {}),
  });
  console.debug(
    `[ears][capture] identity: source ${captureId} → ${id}${displayName ? ` "${displayName}"` : ""}`,
  );
}

/**
 * Receiver tracks deferred because they were muted when dispatched, keyed to
 * their listener cleanup.
 *
 * Meet pre-allocates remote audio transceivers before there is anyone to fill
 * them — journal #142 saw three in a SOLO call, and #165 confirmed the same
 * three on a two-person call with only the carrying one ever unmuting. Every
 * one that reaches ``startPipeline`` becomes a phantom track-handle attendee
 * in session.toml and an `attendee_joined` in events.jsonl, for a participant
 * who does not exist; that noise has been in every session file since July.
 *
 * `muted` is the discriminator, and it costs nothing to wait on: a muted track
 * carries no audio by definition, and ``AudioFrameSource`` already could not
 * build its processor until the same edge (a MediaStreamTrackProcessor
 * constructed on a muted track never delivers frames, even after it unmutes).
 * So the pipeline was always going to start at first unmute — this only stops
 * us announcing a participant before then.
 *
 * NOTE this covers receiver/`ontrack` tracks only. The webaudio seam's tracks
 * all report `muted=false` even when inert: on the 2026-08-12 call all three
 * were unmuted, yet `webaudio-track-2` and `-3` transcribed to zero segments
 * (#171). Suppressing those needs a different signal — they carry frames, the
 * frames are just silent — and silence alone must not retire a source, because
 * a genuinely quiet participant looks identical (DTX / noise suppression).
 */
const deferredMutedTracks = new Map<MediaStreamTrack, () => void>();

/** Start once `track` unmutes, so a never-filled transceiver never becomes an
 * attendee. Idempotent per track; self-cleaning on unmute, end, or teardown. */
function deferUntilUnmuted(track: MediaStreamTrack, stream: MediaStream): void {
  if (deferredMutedTracks.has(track)) return;
  const epoch = cfg.epoch;
  const cleanup = (): void => {
    track.removeEventListener("unmute", onUnmute);
    track.removeEventListener("ended", onEnded);
    deferredMutedTracks.delete(track);
  };
  function onUnmute(): void {
    cleanup();
    recordAttribution({ type: "track-unmuted", t: Date.now(), trackId: track.id });
    // Re-run the same admission check sink ran: an epoch handoff, a seam
    // escalation, or another path adopting this track may all have happened
    // while we waited. `muted` is false by definition on this edge.
    if (!isCurrentEpoch(epoch)) return;
    const seam = activeSeam();
    if (admitReceiverTrack(seam, { muted: false, alreadyCapturing: pipelines.has(track) }) !== "start") return;
    startPipeline(track, { seam, rtc: { stream } });
  }
  function onEnded(): void {
    cleanup();
    recordAttribution({ type: "track-ended", t: Date.now(), trackId: track.id });
    console.debug(
      `[ears][capture] muted receiver track ${track.id} ended without ever unmuting` +
        ` — no attendee was created (pre-allocated transceiver, journal #165)`,
    );
  }
  track.addEventListener("unmute", onUnmute);
  track.addEventListener("ended", onEnded);
  deferredMutedTracks.set(track, cleanup);
  recordAttribution({
    type: "deferred",
    t: Date.now(),
    trackId: track.id,
    seam: activeSeam(),
    reason: "muted at dispatch — waiting for first unmute (journal #165)",
  });
  console.debug(`[ears][capture] deferring muted receiver track ${track.id} until it unmutes`);
}

const sink: TrackSink = (track, stream) => {
  if (!isCurrentEpoch(cfg.epoch)) return; // a newer epoch owns capture
  const seam = activeSeam();
  noteTrackAppeared(track, seam);
  switch (admitReceiverTrack(seam, { muted: track.muted, alreadyCapturing: pipelines.has(track) })) {
    case "skip":
      return;
    case "defer-until-unmute":
      return deferUntilUnmuted(track, stream);
    case "start":
      return startPipeline(track, { seam, rtc: { stream } });
  }
};

/** Track ids already recorded as `track-appeared` (flight recorder) — the
 * reconcile sweep re-runs sink/adoption every 3s, and appearance is news once. */
const appearedTracks = new Set<string>();

function noteTrackAppeared(track: MediaStreamTrack, seam: SeamId): void {
  if (appearedTracks.has(track.id)) return;
  appearedTracks.add(track.id);
  const prov = trackProvenance(track.id);
  recordAttribution({
    type: "track-appeared",
    t: Date.now(),
    trackId: track.id,
    seam,
    muted: track.muted,
    ...(prov ? { origin: prov.origin, rootId: prov.rootId } : {}),
  });
}

function activeSeam(): SeamId {
  return (arbiter?.active ?? "receiver-track") as SeamId;
}

/**
 * Adopt every track the active seam offers that isn't already captured.
 *
 * Non-receiver seams capture a CLONE: the source track is one the page is
 * actively playing, and a MediaStreamTrackProcessor consumes the track it is
 * given. Cloning keeps Meet's own playback whole — verified read-only during
 * the live investigation before this path existed (journal #105).
 */
/** Skip decisions already logged, so the 3s reconcile sweep states each one
 * once instead of repeating it for the rest of the call. */
const loggedSeamSkips = new Set<string>();

function adoptSeamTracks(): void {
  const seam = activeSeam();
  if (seam !== "webaudio-track") return; // no other seam self-discovers tracks
  const available = webAudioTracks();
  const adopted = new Set(adoptedSeamTracks.keys());
  // Provenance for available AND adopted ids: an already-adopted clone must
  // settle its whole lineage root, or the sweep adopts its siblings later.
  const provenance = new Map<string, TrackProvenanceRecord>();
  for (const id of [...available.map((t) => t.id), ...adopted]) {
    const record = trackProvenance(id);
    if (record) provenance.set(id, record);
  }
  // Retire before adopting: a track named `local` since it was adopted is the
  // user's own audio arriving over a second road, and the sweep is the first
  // moment that verdict can be acted on. Freeing its lineage root first also
  // lets a genuine sibling be adopted in the same pass.
  for (const id of seamTracksToRetire(adopted, provenance)) {
    retireSeamTrack(id, provenance.get(id));
    adopted.delete(id);
  }

  const wanted = new Set(seamTracksToAdopt(seam, available.map((t) => t.id), adopted, provenance));
  for (const source of available) {
    if (!wanted.has(source.id)) {
      if (!adopted.has(source.id) && !loggedSeamSkips.has(source.id)) {
        loggedSeamSkips.add(source.id);
        const record = provenance.get(source.id);
        const reason =
          record?.origin === "local"
            ? `local via=${record.via} root=${record.rootId}`
            : `duplicate of root ${record?.rootId ?? source.id}`;
        console.debug(`[ears][capture] skip webaudio track ${source.id}: ${reason}`);
      }
      continue;
    }
    let clone: MediaStreamTrack;
    try {
      clone = source.clone();
    } catch (err) {
      console.debug(`[ears][capture] could not clone webaudio track ${source.id}: ${String(err)}`);
      continue;
    }
    const record = provenance.get(source.id);
    const provDesc = record ? `${record.origin} via=${record.via}` : "unknown provenance";
    console.debug(`[ears][capture] adopt webaudio track ${source.id} (${provDesc})`);
    noteTrackAppeared(source, seam);
    recordAttribution({ type: "adopted", t: Date.now(), trackId: source.id, seam, reason: provDesc });
    adoptedSeamTracks.set(source.id, clone);
    startPipeline(clone, { seam, sourceTrackId: source.id });
  }
}

/**
 * Stop capturing a track that proved to be the user's own audio.
 *
 * Deliberately the same teardown a seam escalation performs — stop the
 * pipeline, stop our clone, forget the adoption — so the daemon sees the
 * ordinary `participant-left` shape it already handles, not a new one. The
 * source keeps whatever it captured before the verdict landed: a few seconds
 * of duplicate audio is the price of "unknown adopts", and far cheaper than
 * the whole call.
 */
function retireSeamTrack(id: string, record?: TrackProvenanceRecord): void {
  const clone = adoptedSeamTracks.get(id);
  adoptedSeamTracks.delete(id);
  recordAttribution({
    type: "retired",
    t: Date.now(),
    trackId: id,
    reason: `local via=${record?.via ?? "?"} root=${record?.rootId ?? id}`,
  });
  console.debug(
    `[ears][capture] retire webaudio track ${id}: ` +
      `local via=${record?.via ?? "?"} root=${record?.rootId ?? id} ` +
      "(the daemon's mic source already records this audio)",
  );
  // The track stays in the WebAudio registry, so this sweep will offer it
  // again and the adopt policy will decline it. Mark the skip as already
  // stated: the retire line above is the explanation, and a "skip" line
  // immediately under it would say the same thing twice.
  loggedSeamSkips.add(id);
  if (!clone) return;
  stopPipeline(clone);
  clone.stop();
}

/**
 * The active seam produced no audio in its grace window: tear its pipelines
 * down and adopt the next seam's tracks.
 *
 * Everything downstream of the frame source is seam-agnostic, so this is a
 * source swap rather than a capture restart — the daemon sees the same
 * participant-left / participant-joined shape it already handles for a
 * reconnect.
 */
function escalateSeam(from: SeamId, to: SeamId): void {
  recordAttribution({
    type: "escalated",
    t: Date.now(),
    from,
    to,
    reason: "no frame decoded within the unmute grace window",
  });
  console.warn(
    `[ears][capture] no audio decoded on seam "${from}" — escalating to "${to}". ` +
      "See capture-seams.ts / journal #103-#105.",
  );
  postToIsolated({ kind: "status", text: `capture seam → ${to} (previous seam produced no audio)` });
  for (const track of [...pipelines.keys()]) stopPipeline(track);
  for (const clone of adoptedSeamTracks.values()) clone.stop();
  adoptedSeamTracks.clear();
  loggedSeamSkips.clear(); // the new seam re-decides every track — re-log
  // Re-adopt under the new seam. A seam with nothing to adopt right now still
  // gets its full grace — tracks can appear later when a participant joins,
  // and the arbiter re-arms on the next unmute either way.
  if (seamUsesReceiverTracks(to)) {
    for (const [track, rec] of liveTracks()) sink(track, rec.stream);
  } else {
    adoptSeamTracks();
  }
}

function startPipeline(track: MediaStreamTrack, origin: PipelineOrigin): void {
  const participant = handleFor(track, origin);
  participantsByTrackId.set(track.id, participant);
  const generation = (generations.get(participant.id) ?? 0) + 1;
  generations.set(participant.id, generation);

  // Identity harvest — the handle stays what it is either way. Receiver-seam
  // tracks carry the RTC context the adapter can match on (Zoom's MSID parse,
  // Meet's tile correlation); a hit becomes an attendee upsert linking this
  // source, never a different source id. Other seams' tracks have ids that
  // never match a hooked receiver (rtc-hook.ts, ids-never-match finding), so
  // there is nothing to match on and their owner is named later — by the same
  // upsert — once speaking correlation resolves them.
  const platformId =
    origin.rtc && seamUsesReceiverTracks(origin.seam)
      ? (cfg.adapter?.identify(track, origin.rtc.stream) ?? null)
      : null;

  // The active seam selects the frame source. Every track-shaped seam shares
  // the one MediaStreamTrackProcessor implementation — only Meet's encoded tee
  // needs a decoder of its own, because it carries encoded frames rather than
  // a track. See capture-seams.ts for why the seam is chosen at runtime.
  const makeSource =
    origin.seam === "meet-encoded-tee" ? meetDecodeSource(track) : trackProcessorSource(track);
  const capture = new TrackCapture(participant.id, () => pipeline.generation, makeSource, () => stopPipeline(track), track, origin.seam);
  const pipeline: Pipeline = {
    participant,
    generation,
    origin,
    stop() {
      capture.stop();
    },
    receiving: () => capture.receiving,
  };
  pipelines.set(track, pipeline);
  capture.start();

  recordAttribution({
    type: "admitted",
    t: Date.now(),
    trackId: track.id,
    seam: origin.seam,
    participantId: participant.id,
    participantOrigin: participant.kind,
    generation,
  });
  postToIsolated({ kind: "participant-joined", platform: cfg.platform, participant, generation });
  console.debug(
    `[ears][capture] +track → ${participant.id} (gen ${generation}) — ${pipelines.size} live`,
  );
  if (platformId) postIdentity(track.id, participant.id, platformId);

  // Lifecycle. Delete from the map *before* stop() so a late frame can't
  // resurrect a dead entry.
  const end = () => {
    recordAttribution({ type: "track-ended", t: Date.now(), trackId: track.id });
    stopPipeline(track);
  };
  track.addEventListener("ended", end);
  track.addEventListener("mute", () => {
    recordAttribution({ type: "track-muted", t: Date.now(), trackId: track.id });
    console.debug(`[ears][capture] mute → ${participant.id}`);
  });
  track.addEventListener("unmute", () => {
    recordAttribution({ type: "track-unmuted", t: Date.now(), trackId: track.id });
    console.debug(`[ears][capture] unmute → ${participant.id}`);
    // Meet identity: an unmute pairs with the collections channel's per-device
    // mic-open edge (the only per-device event that channel still carries).
    try {
      cfg.adapter?.onTrackUnmute?.(track);
    } catch {
      // best-effort — identity must never affect capture
    }
  });
}

function stopPipeline(track: MediaStreamTrack): void {
  const pipeline = pipelines.get(track);
  if (!pipeline) return;
  pipelines.delete(track);
  pipeline.stop();
  postToIsolated({ kind: "participant-left", participantId: pipeline.participant.id, generation: pipeline.generation });
  console.debug(`[ears][capture] -track → ${pipeline.participant.id} (gen ${pipeline.generation}) — ${pipelines.size} live`);
}

function teardownAll(): void {
  if (reconcileTimer !== undefined) {
    clearInterval(reconcileTimer);
    reconcileTimer = undefined;
  }
  for (const track of [...pipelines.keys()]) stopPipeline(track);
  // Clones exist only for this epoch's capture; the page's own tracks are
  // untouched. Stopping them releases the processors holding them open.
  for (const clone of adoptedSeamTracks.values()) clone.stop();
  adoptedSeamTracks.clear();
  // Drop unmute listeners for tracks this epoch was waiting on; the next epoch
  // replays the live registry and re-defers whatever is still muted.
  for (const cleanup of [...deferredMutedTracks.values()]) cleanup();
  loggedSeamSkips.clear();
  // A superseded epoch's queued evidence still belongs to this call.
  flushAttribution();
}

/** Adopt any epoch-owned live track that lost (or never got) a pipeline, and
 * re-harvest the participant roster so names for silent (never-speaking)
 * participants still reach the daemon (#23). */
function reconcile(): void {
  if (!isCurrentEpoch(cfg.epoch)) return;
  // Seam arbitration rides the existing sweep rather than adding a timer: the
  // grace window is seconds, so 3s resolution is ample and it keeps the whole
  // escalation on one cadence.
  const before = activeSeam();
  const next = arbiter?.tick(Date.now());
  if (next) escalateSeam(before, next as SeamId);
  for (const [track, rec] of liveTracks()) {
    if (!pipelines.has(track)) sink(track, rec.stream);
  }
  adoptSeamTracks();
  cfg.adapter?.pollIdentities?.();
  // The attribution flight recorder's batch cadence rides this sweep too —
  // one 3s clock for everything low-frequency in the capture path.
  flushAttribution();
  // Piggy-backed on the existing 3s sweep rather than adding a timer: the
  // pipeline count is what per-frame cost scales with, so it's the denominator
  // for every capture-stage number.
  if (perfEnabled()) captureMetrics().tracks.set(pipelines.size);
}

/**
 * The stable per-track handle for a pipeline: minted at first admission,
 * identical on every re-adoption of the same source track (see the
 * `trackHandles` comment). Deliberately opaque — the handle names a captured
 * track, never a person, so no binding mistake can ever be a recording
 * mistake (R3, finding F2).
 */
function handleFor(track: MediaStreamTrack, origin: PipelineOrigin): ParticipantRef {
  const key = origin.sourceTrackId ?? track.id;
  const existing = trackHandles.get(key);
  if (existing) return existing;
  trackHandleCounter += 1;
  const handle = syntheticParticipant(`t${trackHandleCounter}`);
  trackHandles.set(key, handle);
  return handle;
}

// ── Shared pipeline: frame source → 16 kHz mono pcm_s16le ───────────────────
// (frame-pipeline.ts holds the seam-agnostic pieces; TrackCapture composes them)

/** One track → its own frame source, resampler, ring buffer, and PCM emitter. */
class TrackCapture {
  private stopped = false;
  private resampler?: LinearResampler;
  private readonly acc: number[] = []; // 16 kHz mono float, awaiting a full frame
  private readonly ring: RingBuffer;
  private source?: FrameSource;
  private firstFrameSeen = false;
  private readonly silentWatchdog: SilentCaptureWatchdog;
  private unmuteHandler?: () => void;
  // Debug-only state — see DEBUG_AUDIO above.
  private vSum = 0;
  private vPeak = 0;
  private vCount = 0;
  private speaking = false; // edge-detection state, see SPEAK_THRESHOLD above — always tracked, not debug-only
  private readonly trackId: string;
  /** Monotonic per-participant frame counter stamped on every posted PCM frame
   * (wraps at 2^32 — ~2.7 years at this frame rate). Paired with a send
   * timestamp so earsd can distinguish silence from a stalled delivery path. */
  private seq = 0;

  constructor(
    private readonly participantId: string,
    private readonly currentGeneration: () => number,
    private readonly makeSource: FrameSourceFactory,
    private readonly onFatal: () => void,
    private readonly track: MediaStreamTrack,
    private readonly seam: SeamId,
  ) {
    this.ring = new RingBuffer(RING_CAPACITY, participantId);
    this.trackId = track.id;
    this.silentWatchdog = new SilentCaptureWatchdog((graceMs) => this.reportSilent(graceMs));
  }

  /** Whether at least one audio frame has decoded on this track (debug report). */
  get receiving(): boolean {
    return this.firstFrameSeen;
  }

  start(): void {
    this.source = this.makeSource(
      (frame) => this.consume(frame),
      (reason) => this.fail(reason),
    );
    this.source.start();
    // An unmute means the platform says this participant is producing audio now,
    // so a decoded frame must follow; if none does, capture is silently dropping
    // them (journal #72). Arm on unmute, not on start — a genuinely quiet
    // participant yields no frames and that is not a failure.
    // The same unmute drives two things: the per-participant silent warning,
    // and the call-level seam arbitration (an unmute is the platform asserting
    // audio is flowing, so a frameless grace window means the SEAM is wrong,
    // not that this participant is quiet).
    this.unmuteHandler = () => {
      this.silentWatchdog.armOnUnmute();
      arbiter?.noteUnmute(Date.now());
    };
    this.track.addEventListener("unmute", this.unmuteHandler);
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    if (this.unmuteHandler) {
      this.track.removeEventListener("unmute", this.unmuteHandler);
      this.unmuteHandler = undefined;
    }
    this.silentWatchdog.stop();
    this.source?.stop();
  }

  private fail(reason: string): void {
    console.error(`[ears][capture] ${this.participantId} capture failed: ${reason}`);
    // Tell the isolated relay (and through it the background/daemon) that this
    // participant's capture died mid-call, so the audio gap is attributable
    // rather than looking like the source just went quiet (issue #22).
    postToIsolated({ kind: "capture-failed", participantId: this.participantId, generation: this.currentGeneration(), reason });
    this.stop();
    this.onFatal();
  }

  /** The silent-capture watchdog fired: this participant unmuted but no decoded
   * frame ever arrived. Loud console error plus a `status` line the isolated-
   * world relay logs (and can surface in the popup/daemon). See journal #72. */
  private reportSilent(graceMs: number): void {
    const report = silentReport(this.participantId, cfg?.platform, anyAudioDecodedThisCall, graceMs);
    if (report.level === "warn") {
      console.error(`[ears][capture] ${report.text}`);
      postToIsolated({ kind: "status", text: report.text });
    } else {
      // Benign: the pipeline works, this participant is just quiet. Keep it low
      // so it never reads as a failure to a user scanning the console.
      console.debug(`[ears][capture] ${report.text}`);
    }
  }

  private consume(frame: AudioDataLike): void {
    if (!this.firstFrameSeen) {
      this.firstFrameSeen = true;
      anyAudioDecodedThisCall = true;
      this.silentWatchdog.noteFrame();
      // Proves the seam for the whole call — from here it is never escalated
      // off, so a participant simply going quiet can't cause seam churn.
      arbiter?.noteFrame(Date.now(), this.seam);
      console.debug(`[ears][capture] ✓ ${this.participantId} first audio frame — capture confirmed live`);
    }
    // Two boolean reads per frame. The `performance.now()` calls below are
    // detail-gated: at ~50 frames/s per active speaker they are cheap but not
    // free, and this runs on the thread Meet renders video on.
    const metrics = perfEnabled() ? captureMetrics() : null;
    const detail = metrics !== null && perfDetailEnabled();
    const t0 = detail ? performance.now() : 0;

    const inRate = frame.sampleRate;
    const nFrames = frame.numberOfFrames;
    const nCh = frame.numberOfChannels;
    const format = frame.format ?? "f32-planar";

    // Downmix to mono float32.
    const mono = new Float32Array(nFrames);
    if (format.endsWith("-planar")) {
      const plane = new Float32Array(nFrames);
      for (let ch = 0; ch < nCh; ch++) {
        frame.copyTo(plane, { planeIndex: ch, format: "f32-planar" });
        for (let i = 0; i < nFrames; i++) mono[i]! += plane[i]! / nCh;
      }
    } else {
      const inter = new Float32Array(nFrames * nCh);
      frame.copyTo(inter, { planeIndex: 0, format: "f32" });
      for (let i = 0; i < nFrames; i++) {
        let s = 0;
        for (let ch = 0; ch < nCh; ch++) s += inter[i * nCh + ch]!;
        mono[i] = s / nCh;
      }
    }
    const tDownmix = detail ? performance.now() : 0;

    // Always tracked (not debug-gated): MeetAdapter's collections-datachannel
    // correlation needs a real speaking-edge signal, not just a debug log —
    // see lib/identity/meet.ts and PlatformAdapter.onTrackSpeaking.
    this.updateSpeaking(mono);
    const tSpeaking = detail ? performance.now() : 0;

    if (DEBUG_AUDIO_NOW()) this.debugLog(mono, inRate);
    const tDebugLog = detail ? performance.now() : 0;

    // Resample native → 16 kHz and slice into fixed frames.
    if (!this.resampler) this.resampler = new LinearResampler(inRate, TARGET_SAMPLE_RATE);
    const out = this.resampler.process(mono);
    const tResample = detail ? performance.now() : 0;

    for (let i = 0; i < out.length; i++) this.acc.push(out[i]!);

    while (this.acc.length >= FRAME_SAMPLES) {
      const chunk = this.acc.splice(0, FRAME_SAMPLES);
      const int16 = new Int16Array(FRAME_SAMPLES);
      for (let i = 0; i < FRAME_SAMPLES; i++) {
        let s = chunk[i]!;
        if (s > 1) s = 1;
        else if (s < -1) s = -1;
        int16[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
      }
      this.ring.push(int16);
    }
    const tAccumulate = detail ? performance.now() : 0;

    for (const f of this.ring.drain()) {
      // seq is per-participant and monotonic across the pipeline's life; the
      // daemon uses the pair to tell a silent speaker from a stalled extension.
      this.seq = (this.seq + 1) >>> 0;
      postToIsolated({
        kind: "pcm",
        participantId: this.participantId,
        generation: this.currentGeneration(),
        samples: f,
        seq: this.seq,
        sentAt: Date.now(),
      });
      metrics?.posted.add();
    }

    if (metrics) {
      metrics.frames.add();
      metrics.samples.add(nFrames);
      if (detail) {
        const tPost = performance.now();
        metrics.downmix.observe(tDownmix - t0);
        metrics.speaking.observe(tSpeaking - tDownmix);
        metrics.debugLog.observe(tDebugLog - tSpeaking);
        metrics.resample.observe(tResample - tDebugLog);
        metrics.accumulate.observe(tAccumulate - tResample);
        metrics.post.observe(tPost - tAccumulate);
        metrics.frame.observe(tPost - t0);
      }
    }
  }

  // Edge-triggered start/stop, ~frame-resolution (10-100ms depending on
  // source) — comparable granularity to the DOM speaking-indicator's
  // mutation-observer log (journal #47/#48), so the two can be correlated by
  // timestamp. Always runs (see the call site in consume()): the collections-
  // datachannel correlation (lib/identity/meet-correlator.ts) needs this
  // signal live, not just when __earsDebugAudio is set. Debug logging below
  // stays gated; only the edge detection and the adapter callback are unconditional.
  private updateSpeaking(mono: Float32Array): void {
    let framePeak = 0;
    for (let i = 0; i < mono.length; i++) {
      const a = Math.abs(mono[i]!);
      if (a > framePeak) framePeak = a;
    }
    const isSpeaking = framePeak > SPEAK_THRESHOLD;
    if (isSpeaking === this.speaking) return;
    this.speaking = isSpeaking;
    cfg.adapter?.onTrackSpeaking?.(this.track, isSpeaking);
    // Always recorded (unlike the debug log below): these onsets are the audio
    // half of every speaking-onset correlation, so a recorded call can replay
    // the exact evidence the correlators saw.
    recordAttribution({
      type: "audio-onset",
      t: Date.now(),
      participantId: this.participantId,
      trackId: this.trackId,
      state: isSpeaking ? "start" : "stop",
      framePeak: Number(framePeak.toFixed(4)),
    });

    if (DEBUG_AUDIO_NOW()) {
      const t = Date.now();
      const entry: AudioLogEntry = {
        t,
        iso: new Date(t).toISOString(),
        participantId: this.participantId,
        trackId: this.trackId,
        state: isSpeaking ? "start" : "stop",
        framePeak: Number(framePeak.toFixed(4)),
      };
      audioLog().push(entry);
      console.debug(
        `[ears][debug][audio] ${entry.iso} ${this.participantId} (track ${this.trackId}) speaking-${entry.state} peak=${entry.framePeak}`,
      );
    }
  }

  // Throttled to ~1 log/s/participant — frame counts alone don't prove the
  // samples aren't all-zero, so this checks actual amplitude. DEBUG_AUDIO-gated.
  private debugLog(mono: Float32Array, inRate: number): void {
    for (let i = 0; i < mono.length; i++) {
      const a = Math.abs(mono[i]!);
      if (a > this.vPeak) this.vPeak = a;
      this.vSum += mono[i]! * mono[i]!;
    }
    this.vCount += mono.length;

    if (this.vCount >= inRate) {
      const rms = Math.sqrt(this.vSum / this.vCount);
      console.debug(
        `[ears][debug][audio] ${this.participantId} rms=${rms.toFixed(4)} peak=${this.vPeak.toFixed(4)} ` +
          `(${this.vPeak > 0.005 ? "AUDIO" : "silent"})`,
      );
      this.vSum = 0;
      this.vPeak = 0;
      this.vCount = 0;
    }
  }
}


/**
 * Dev-only: run a LOCAL MediaStream through the real capture path, bypassing the
 * RTC hook (the sandboxed test harness can't establish a WebRTC loopback).
 */
export function __devCaptureStream(
  stream: MediaStream,
  participantId: string,
  seam: SeamId = "receiver-track",
): void {
  const track = stream.getAudioTracks()[0];
  if (!track) return;
  // Dev/graph-bridge ids (`graphtap-<n>`, harness labels) are ours, never the
  // platform's — declare them synthetic.
  postToIsolated({ kind: "participant-joined", platform: cfg?.platform ?? "meet", participant: syntheticParticipant(participantId), generation: 1 });
  new TrackCapture(participantId, () => 1, trackProcessorSource(track), () => {}, track, seam).start();
}
