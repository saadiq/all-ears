import { isCurrentEpoch } from "./epoch";
import {
  liveTracks,
  setEncodedAudioListener,
  setTrackSink,
  trackProvenance,
  webAudioTracks,
  type EncodedAudioFrameLike,
  type EncodedAudioListener,
  type TrackProvenanceRecord,
  type TrackSink,
} from "./rtc-hook";
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
import { mainPerf, perfDetailEnabled, perfEnabled } from "./perf-main";
import type { Counter, Gauge, Histogram } from "./perf";

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

const TARGET_SAMPLE_RATE = 16000;
// Bounded per-participant ring buffer. ~10 frames/s; 50 frames ≈ 5 s of slack
// before we drop the oldest frame (back-pressure toward the transport).
const RING_CAPACITY = 50;

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

// ── Capture-path instrumentation ─────────────────────────────────────────────
//
// One group shared by every pipeline, not one per participant: the question is
// what the capture path costs this thread in total, and per-participant series
// would multiply the record count by the tile count for no extra insight.
//
// Stage boundaries mirror consume()'s structure exactly, so a hot stage names
// the code to look at. Everything here is resolved once and cached — the hot
// path does two boolean reads and, when the detail tier is off, nothing else.

interface CaptureMetrics {
  frame: Histogram;
  downmix: Histogram;
  speaking: Histogram;
  debugLog: Histogram;
  resample: Histogram;
  accumulate: Histogram;
  post: Histogram;
  frames: Counter;
  samples: Counter;
  posted: Counter;
  tracks: Gauge;
  decodeQueue: Gauge;
}

let metricsCache: CaptureMetrics | null = null;

function captureMetrics(): CaptureMetrics {
  if (!metricsCache) {
    const g = mainPerf().group("capture");
    metricsCache = {
      frame: g.histogram("frame"),
      downmix: g.histogram("downmix"),
      speaking: g.histogram("speaking"),
      debugLog: g.histogram("debuglog"),
      resample: g.histogram("resample"),
      accumulate: g.histogram("accumulate"),
      post: g.histogram("post"),
      frames: g.counter("frames"),
      samples: g.counter("samples"),
      posted: g.counter("posted"),
      tracks: g.gauge("tracks"),
      decodeQueue: g.gauge("decode_queue"),
    };
  }
  return metricsCache;
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
// when nothing has decoded anywhere on the call (see silentReport). Not reset on
// epoch handoff — a mid-call re-inject must not forget that audio once flowed.
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

const FRAME_SAMPLES = 1600; // 100 ms @ 16 kHz → ~10 frames/s

// Debug instrumentation for live-call verification — off by default, no
// rebuild needed to use. Enable per-tab from the page's DevTools console:
//   localStorage.setItem("__earsDebugAudio", "1")   // then reload the tab
//   localStorage.removeItem("__earsDebugAudio")     // to turn back off
// Adds a throttled peak/RMS log per participant (proves PCM is non-silent,
// not just flowing) and dumps recent frame sizes/timestamps if AudioDecoder
// errors (WebCodecs gives no other way to correlate an error to a frame).
function debugAudioEnabled(): boolean {
  try {
    return localStorage.getItem("__earsDebugAudio") === "1";
  } catch {
    return false;
  }
}
// Read fresh each call (not cached at module load) — a stale cached value was
// a plausible reason debug logging silently stayed off across an epoch handoff
// or re-injection even with the localStorage flag set to "1".
function DEBUG_AUDIO_NOW(): boolean {
  return debugAudioEnabled();
}

// Phase 4 investigation instrumentation (meet-speaking-indicator-correlation
// prompt): edge-triggered speaking-start/stop events per track, in the same
// shape/timestamp-precision as the DOM MutationObserver log used to watch
// Meet's tile speaking indicator, so the two can be diffed directly. Gated by
// the same __earsDebugAudio flag — no behavior change when off.
const SPEAK_THRESHOLD = 0.005; // matches the existing periodic AUDIO/silent cutoff below

interface AudioLogEntry {
  t: number;
  iso: string;
  participantId: string;
  trackId: string;
  state: "start" | "stop";
  framePeak: number;
}
interface AudioLogWindow extends Window {
  __earsAudioLog?: AudioLogEntry[];
}
function audioLog(): AudioLogEntry[] {
  const g = window as unknown as AudioLogWindow;
  if (!g.__earsAudioLog) g.__earsAudioLog = [];
  return g.__earsAudioLog;
}

// WebCodecs AudioData surface we use (avoids ambient-declaration conflicts).
interface AudioDataLike {
  readonly sampleRate: number;
  readonly numberOfFrames: number;
  readonly numberOfChannels: number;
  readonly format: string | null;
  copyTo(dest: Float32Array, options: { planeIndex: number; format?: string }): void;
  close(): void;
}

interface FrameSource {
  /** Begin producing frames. Called at most once. */
  start(): void;
  /** Stop producing frames and release resources. Idempotent. */
  stop(): void;
}

type FrameSourceFactory = (
  onFrame: (frame: AudioDataLike) => void,
  onFatalError: (reason: string) => void,
) => FrameSource;

/** One track → its own frame source, resampler, ring buffer, and PCM emitter. */
// A track that unmutes but never yields a decoded frame is the silent-capture
// failure (journal #72): on Meet the encoded-audio tee may never wrap the
// receiver, so the decoder is fed nothing and the whole call records silence
// while +track/unmute/identity all still look healthy. The grace window covers
// the ~1-frame latency between an unmute and the first decoded frame with wide
// margin, so a brief blip never false-positives.
export const SILENT_CAPTURE_GRACE_MS = 4_000;

/**
 * Decide how to surface a track that unmuted but produced no decoded frame.
 * Meet delivers no audio for an unmuted-but-silent participant (DTX / noise
 * suppression), so "no frames" alone is NOT proof of breakage. Escalate to a
 * loud warning only when nothing has decoded anywhere on the call
 * (`anyAudioThisCall === false`) — the same condition the call-level tee
 * watchdog flags. If other participants are being captured, this one is simply
 * quiet: a benign info note, never a scary ⚠ (journal #67: quiet ≠ broken).
 */
export function silentReport(
  participantId: string,
  platform: Platform | undefined,
  anyAudioThisCall: boolean,
  graceMs: number,
): { level: "warn" | "info"; text: string } {
  const secs = Math.round(graceMs / 1000);
  if (anyAudioThisCall) {
    return {
      level: "info",
      text:
        `${participantId} unmuted but no audio decoded in ${secs}s` +
        " — likely silent or noise-suppressed (other participants are being captured)",
    };
  }
  const hint =
    platform === "meet"
      ? " — Meet exposes no decodable track audio, so no encoded frames reached the decoder" +
        " (createEncodedStreams not intercepted, or Meet changed its audio pipeline)." +
        " Reload the tab to re-arm."
      : "";
  return {
    level: "warn",
    text: `⚠ ${participantId} unmuted but no audio decoded in ${secs}s — capture is SILENT for this participant${hint}`,
  };
}

/**
 * Per-track detector for the silent-capture failure. `armOnUnmute()` starts a
 * one-shot timer; unless `noteFrame()` lands before it fires, `onSilent` runs
 * once (latched for the track's life). Kept free of TrackCapture's
 * window/postMessage wiring so it unit-tests under fake timers.
 */
export class SilentCaptureWatchdog {
  private firstFrameSeen = false;
  private reported = false;
  private timer?: ReturnType<typeof setTimeout>;

  constructor(
    private readonly onSilent: (graceMs: number) => void,
    private readonly graceMs: number = SILENT_CAPTURE_GRACE_MS,
  ) {}

  /** The track unmuted — a decoded frame must follow. Arm once; ignore repeat
   * unmutes and any unmute after a frame already proved capture live. */
  armOnUnmute(): void {
    if (this.firstFrameSeen || this.reported || this.timer !== undefined) return;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      if (this.firstFrameSeen || this.reported) return;
      this.reported = true;
      this.onSilent(this.graceMs);
    }, this.graceMs);
  }

  /** A decoded frame arrived — capture is live; cancel the watchdog for good. */
  noteFrame(): void {
    if (this.firstFrameSeen) return;
    this.firstFrameSeen = true;
    this.clearTimer();
  }

  stop(): void {
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.timer !== undefined) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
  }
}

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

// ── Standard path: MediaStreamTrackProcessor (Zoom, Teams) ─────────────────
//
// Read decoded audio frames straight off the MediaStreamTrack (WebCodecs
// breakout box). Unlike a WebAudio MediaStreamAudioSourceNode, this needs no
// AudioContext and no playing media element, so it doesn't hit the remote-track
// silence bug (verified: on real Meet the WebAudio tap read digital silence
// even with a playing mirror; the breakout box reads the true audio — though
// on Meet even this reads nothing at all, see MeetDecodeSource below).

type TrackProcessorCtor = new (init: { track: MediaStreamTrack }) => {
  readable: ReadableStream<AudioDataLike>;
};

class TrackProcessorSource implements FrameSource {
  private stopped = false;
  private reader?: ReadableStreamDefaultReader<AudioDataLike>;
  private unmuteHandler?: () => void;

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly onFrame: (frame: AudioDataLike) => void,
    private readonly onFatalError: (reason: string) => void,
  ) {}

  start(): void {
    if (this.track.muted) {
      // A MediaStreamTrackProcessor constructed on a MUTED track never delivers
      // frames — even after the track unmutes — and a track allows only one
      // processor ever. So defer construction until the track's first unmute.
      const onUnmute = () => {
        this.track.removeEventListener("unmute", onUnmute);
        this.unmuteHandler = undefined;
        if (!this.stopped) this.begin();
      };
      this.unmuteHandler = onUnmute;
      this.track.addEventListener("unmute", onUnmute);
      return;
    }
    this.begin();
  }

  stop(): void {
    this.stopped = true;
    if (this.unmuteHandler) {
      this.track.removeEventListener("unmute", this.unmuteHandler);
      this.unmuteHandler = undefined;
    }
    this.reader?.cancel().catch(() => {});
  }

  private begin(): void {
    const Ctor = (globalThis as unknown as { MediaStreamTrackProcessor?: TrackProcessorCtor })
      .MediaStreamTrackProcessor;
    if (!Ctor) {
      this.onFatalError("MediaStreamTrackProcessor unavailable");
      return;
    }
    try {
      this.reader = new Ctor({ track: this.track }).readable.getReader();
    } catch (err) {
      this.onFatalError(`failed to construct processor: ${String(err)}`);
      return;
    }
    void this.loop();
  }

  private async loop(): Promise<void> {
    const reader = this.reader!;
    while (!this.stopped) {
      let done = false;
      let value: AudioDataLike | undefined;
      try {
        ({ done, value } = await reader.read());
      } catch (err) {
        if (!this.stopped) this.onFatalError(`reader.read() threw: ${String(err)}`);
        return;
      }
      if (done) {
        if (!this.stopped) this.onFatalError("track reader closed");
        return;
      }
      if (!value) continue;
      try {
        this.onFrame(value);
      } finally {
        value.close();
      }
    }
  }
}

function trackProcessorSource(track: MediaStreamTrack): FrameSourceFactory {
  return (onFrame, onFatalError) => new TrackProcessorSource(track, onFrame, onFatalError);
}

// ── Meet path: AudioDecoder fed by rtc-hook.ts's encoded-audio tee ─────────
//
// Standard path never works on Meet (confirmed empirically — see rtc-hook.ts
// and specs/extension.md §Audio extraction). Readiness here is "rtc-hook.ts
// has a tee'd branch for this track and is willing to dispatch frames to us",
// not track-mute state: once createEncodedStreams() is in play, Meet's own
// decode pipeline owns track.muted and it stops reflecting anything
// meaningful for our purposes.

interface EncodedAudioChunkInit {
  type: "key" | "delta";
  timestamp: number;
  data: ArrayBuffer;
}
type EncodedAudioChunkCtor = new (init: EncodedAudioChunkInit) => unknown;

interface AudioDecoderLike {
  configure(config: { codec: string; sampleRate: number; numberOfChannels: number }): void;
  decode(chunk: unknown): void;
  close(): void;
}
type AudioDecoderCtor = new (init: {
  output: (frame: AudioDataLike) => void;
  error: (err: Error) => void;
}) => AudioDecoderLike;

// A single transient bad frame puts the whole AudioDecoder into a permanent
// error state (WebCodecs gives no per-frame recovery, and the error callback
// carries no chunk reference). Killing the participant's capture over one such
// frame is wrong: live evidence shows the *same* track decodes cleanly on a
// fresh decoder immediately afterwards (a decoder that died mid-call went on
// to decode ~9.8k subsequent frames with zero errors once reconstructed). So
// MeetDecodeSource restarts its decoder in place — the encoded-audio tee keeps
// feeding this track for its whole life, so a rebuilt decoder resumes with no
// participant-left/joined churn and no daemon-source close.
//
// The spiral issue #22 fixes: Meet changes the Opus stream mid-call (bitrate /
// DTX as speakers pause) and a short burst of frames won't decode from a cold
// decoder. The old budget counted every rebuild equally, so a poisoned burst
// re-fed into a fresh decoder frame-by-frame exhausted all 5 restarts in under
// a second and dropped the track. Two changes break that, distinguishing "same
// frame fails repeatedly" (skip it) from "decoder broken" (rebuild):
//
//   1. A rebuilt decoder that dies before decoding anything (a *barren*
//      restart) does NOT re-feed the frames that just failed. It cools down for
//      DECODER_RESTART_COOLDOWN_MS — dropping the poisoned window — then
//      rebuilds on the next live frame: "resume at the next decodable
//      boundary", not "replay the recent frame window". That paces barren
//      restarts at most one per cooldown, so one bad burst can't burn the whole
//      budget in <1s.
//   2. A decoder that WAS decoding cleanly (>= DECODER_HEALTHY_FRAMES) before an
//      error is a distinct incident, not a spiral: it rebuilds immediately
//      (near-zero audio loss) and its recovery resets the restart budget. Only
//      barren restarts count toward giving up.
//
// Past DECODER_MAX_RESTARTS barren restarts within a sliding
// DECODER_RESTART_WINDOW_MS we stop and fall through to the fatal path (stops
// the pipeline once; TrackCapture then emits a capture-failed event so the
// daemon can attribute the gap instead of just seeing the source go quiet).
const DECODER_RESTART_WINDOW_MS = 30_000;
export const DECODER_MAX_RESTARTS = 5;
// A rebuilt decoder that decodes this many frames (~200ms of Opus at 20ms /
// frame) has proven it can decode from a cold start — the poisoned boundary is
// behind it. Reaching it resets the restart budget; an error after it rebuilds
// immediately instead of counting toward give-up.
export const DECODER_HEALTHY_FRAMES = 10;
// After a barren restart, drop incoming frames for this long before spending the
// next restart. Long enough for a mid-stream Opus parameter change to finish so
// the rebuilt decoder lands on a decodable boundary; short enough that recovery
// costs ~1s of audio, not the whole speaking turn.
export const DECODER_RESTART_COOLDOWN_MS = 1_000;

/** Injection seam for MeetDecodeSource — production reads globals + rtc-hook;
 * tests supply fakes and a controllable clock. All optional. */
export interface MeetDecodeDeps {
  decoderCtor?: AudioDecoderCtor;
  chunkCtor?: EncodedAudioChunkCtor;
  /** Subscribe to (listener) / unsubscribe from (null) this track's encoded-audio tee. */
  subscribe?: (track: MediaStreamTrack, listener: EncodedAudioListener | null) => void;
  /** ms clock for the restart sliding window. */
  now?: () => number;
}

/** One recently-fed encoded frame, kept for post-hoc error forensics. */
interface FrameForensic {
  byteLength: number;
  timestamp: number;
  /** Opus TOC byte (config / stereo / frame-count code). A mid-stream bitrate
   * or DTX change — the suspected poison — shows up here as a changed config. */
  toc: number;
}

/**
 * Unwrap an RFC 2198 RED payload to its primary (current) block, or return
 * null when `data` doesn't parse as RED.
 *
 * Meet wraps its Opus stream in RED adaptively (redundancy kicks in under
 * packet loss), and those packets reach the encoded-audio tee as-is: the
 * 2026-07-24 live captures show every "AudioDecoder error: Decoding error"
 * frame starting 0xEF — not an Opus TOC but the RED block header
 * `F=1 | PT=111` (111 is Meet's Opus payload type). Feeding RED to a plain
 * Opus decoder fails per-packet, which is journal #45's entire error class.
 *
 * Wire shape (RFC 2198): N redundant-block headers (4 bytes each, F bit set:
 * F|PT, 14-bit timestamp offset, 10-bit block length), one primary header
 * (1 byte, F bit clear), then the blocks in header order — redundant blocks
 * first at their declared lengths, primary block last taking the remainder.
 * The primary block is the current frame; redundant blocks re-carry earlier
 * frames the decoder has usually already seen, so only the primary is fed.
 *
 * Defensive by contract: a genuine Opus TOC can also carry the high bit, so
 * a payload is only treated as RED when the full header chain parses — every
 * header PT identical and the declared redundant lengths fitting exactly
 * inside the payload. Anything else returns null and is fed to the decoder
 * unchanged.
 */
export function unwrapRedPayload(data: ArrayBuffer): ArrayBuffer | null {
  const bytes = new Uint8Array(data);
  let offset = 0;
  let redundantBytes = 0;
  let redundantHeaders = 0;
  let primaryPT = -1;
  while (offset < bytes.length) {
    const first = bytes[offset]!;
    const pt = first & 0x7f;
    if (primaryPT === -1) primaryPT = pt;
    else if (pt !== primaryPT) return null; // mixed PTs — not a RED chain
    if ((first & 0x80) === 0) {
      // Primary header (1 byte) — blocks follow.
      if (redundantHeaders === 0) return null; // no redundancy → plain payload
      const blocksStart = offset + 1;
      const primaryStart = blocksStart + redundantBytes;
      if (primaryStart >= bytes.length) return null; // lengths don't fit
      return bytes.slice(primaryStart).buffer;
    }
    if (offset + 4 > bytes.length) return null; // truncated header
    redundantBytes += ((bytes[offset + 2]! & 0x03) << 8) | bytes[offset + 3]!;
    redundantHeaders += 1;
    offset += 4;
  }
  return null; // ran out of bytes before a primary header
}

export class MeetDecodeSource implements FrameSource {
  private stopped = false;
  private decoder?: AudioDecoderLike;
  private decoderCtor?: AudioDecoderCtor;
  private chunkCtor?: EncodedAudioChunkCtor;
  private readonly subscribe: (track: MediaStreamTrack, listener: EncodedAudioListener | null) => void;
  private readonly now: () => number;
  /** ms timestamps of barren restarts still inside the sliding window. */
  private restarts: number[] = [];
  /** Successful decodes since the current decoder was built. 0 = barren so far;
   * >= DECODER_HEALTHY_FRAMES = the decoder has recovered. */
  private framesSinceBuild = 0;
  /** Set when the decoder has died and is cooling down before its next rebuild;
   * frames arriving before now() reaches it + COOLDOWN are dropped (skipping the
   * poisoned window). undefined while a decoder is live. */
  private coolingSince?: number;
  // AudioDecoder's error callback gives a generic DOMException with no reference
  // to which chunk failed, so keep a small rolling window of what we recently
  // fed it. Always populated (small, cheap) — you can't arm the debug flag after
  // the error already happened, and issue #22 needs this for every error.
  private recentFrames: FrameForensic[] = [];
  // Per-track give-up summary (logged when we stop restarting).
  private readonly startedAt: number;
  private totalFramesDecoded = 0;
  private totalErrors = 0;
  private framesDroppedRecovering = 0;
  /** RED payloads unwrapped to their primary block (see unwrapRedPayload). */
  private redFramesUnwrapped = 0;
  private firstErrorReason?: string;
  private lastErrorReason?: string;

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly onFrame: (frame: AudioDataLike) => void,
    private readonly onFatalError: (reason: string) => void,
    private readonly deps: MeetDecodeDeps = {},
  ) {
    this.subscribe = deps.subscribe ?? setEncodedAudioListener;
    this.now = deps.now ?? (() => Date.now());
    this.startedAt = this.now();
  }

  start(): void {
    const DecoderCtor = this.deps.decoderCtor ?? (globalThis as unknown as { AudioDecoder?: AudioDecoderCtor }).AudioDecoder;
    const ChunkCtor = this.deps.chunkCtor ?? (globalThis as unknown as { EncodedAudioChunk?: EncodedAudioChunkCtor }).EncodedAudioChunk;
    if (!DecoderCtor || !ChunkCtor) {
      // Not expected to trigger (AudioDecoder opus support confirmed on-build),
      // but fall back cleanly: skip this participant, don't crash the hook.
      this.onFatalError("AudioDecoder/EncodedAudioChunk unavailable — cannot decode Meet audio");
      return;
    }
    this.decoderCtor = DecoderCtor;
    this.chunkCtor = ChunkCtor;
    if (!this.buildDecoder()) return; // construction failed — fatal already reported
    this.subscribe(this.track, (frame) => this.onEncodedFrame(frame));
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.subscribe(this.track, null);
    this.closeDecoder();
  }

  /** Construct + configure a fresh decoder. Returns false (after reporting a
   * fatal error) if construction itself fails — that's not recoverable. */
  private buildDecoder(): boolean {
    try {
      this.decoder = new this.decoderCtor!({
        output: (frame) => this.onDecodedFrame(frame),
        error: (err) => this.onDecoderError(`AudioDecoder error: ${err.message ?? String(err)}`),
      });
      // Stereo, not mono: every "Decoding error" frame captured live carries
      // TOC 0xef — Opus config 29 with the STEREO flag set. Meet switches its
      // per-speaker stream between mono and stereo packets mid-call, and a
      // mono-configured decoder dies on each stereo packet (journal #45's
      // whole error class, root-caused 2026-07-24 during the drift capture —
      // dev/captures/2026-07-24-meet-collections-drift.md). An Opus decoder
      // configured stereo decodes BOTH: mono packets upmix to two identical
      // channels, and consume()'s downmix folds either shape back to mono.
      this.decoder.configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 2 });
      this.framesSinceBuild = 0;
      this.coolingSince = undefined;
      return true;
    } catch (err) {
      this.onFatalError(`failed to construct AudioDecoder: ${String(err)}`);
      return false;
    }
  }

  private closeDecoder(): void {
    try {
      this.decoder?.close();
    } catch {
      // already closed (an errored decoder self-closes)
    }
    this.decoder = undefined;
  }

  /** A frame decoded successfully. Track health so a decoder that gets going
   * again resets the restart budget (its failure was a distinct incident, not a
   * spiral). */
  private onDecodedFrame(frame: AudioDataLike): void {
    this.framesSinceBuild++;
    this.totalFramesDecoded++;
    if (this.framesSinceBuild === DECODER_HEALTHY_FRAMES && this.restarts.length > 0) {
      console.debug(
        `[ears][capture] ${this.track.id} decoder recovered — ` +
          `${DECODER_HEALTHY_FRAMES} frames decoded since rebuild; restart budget reset`,
      );
      this.restarts = [];
    }
    this.onFrame(frame);
  }

  /** Decoder-level failure (error callback or decode() throw). A decoder that
   * was healthy rebuilds immediately; a barren one cools down (see the class
   * comment) so a poisoned burst can't spiral through the budget. */
  private onDecoderError(reason: string): void {
    if (this.stopped) return;
    const now = this.now();
    this.totalErrors++;
    this.firstErrorReason ??= reason;
    this.lastErrorReason = reason;

    const decodedThisLife = this.framesSinceBuild;
    const healthy = decodedThisLife >= DECODER_HEALTHY_FRAMES;
    this.logDecoderError(reason, decodedThisLife, healthy);
    this.closeDecoder();

    if (healthy) {
      // Isolated error after a clean run — a distinct incident, not the spiral.
      // Rebuild immediately (near-zero audio loss) and clear the barren budget.
      this.restarts = [];
      console.warn(`[ears][capture] ${this.track.id} decoder rebuilt in place after a healthy run — ${reason}`);
      this.buildDecoder();
      return;
    }

    // Barren: the decoder died before proving it could decode from here. Don't
    // re-feed the same frames — cool down, dropping them, and rebuild on the
    // next live frame past the cooldown (see onEncodedFrame). Budget is spent at
    // that rebuild, so barren restarts can't accumulate faster than one per
    // cooldown.
    this.coolingSince = now;
    const pending = this.restarts.filter((t) => now - t <= DECODER_RESTART_WINDOW_MS).length;
    console.warn(
      `[ears][capture] ${this.track.id} decoder died barren (${decodedThisLife} frame(s) since rebuild) — ` +
        `cooling down ${DECODER_RESTART_COOLDOWN_MS}ms before restart ${pending + 1}/${DECODER_MAX_RESTARTS}`,
    );
  }

  /** Rebuild after a barren restart's cooldown. Spends a budget slot; gives up
   * (fatal, exactly once) if the budget is exhausted. Returns false on give-up. */
  private restartDecoder(): boolean {
    const now = this.now();
    this.restarts = this.restarts.filter((t) => now - t <= DECODER_RESTART_WINDOW_MS);
    if (this.restarts.length >= DECODER_MAX_RESTARTS) {
      this.giveUp(now);
      return false;
    }
    this.restarts.push(now);
    console.warn(
      `[ears][capture] ${this.track.id} decoder restart ${this.restarts.length}/${DECODER_MAX_RESTARTS} ` +
        `(resuming at a fresh frame; ${this.framesDroppedRecovering} frame(s) dropped while recovering)`,
    );
    return this.buildDecoder();
  }

  /** Restart budget exhausted: log a per-track summary and go fatal once. */
  private giveUp(now: number): void {
    const seconds = ((now - this.startedAt) / 1000).toFixed(1);
    console.error(
      `[ears][capture] ${this.track.id} giving up — capture summary: ` +
        `${this.totalFramesDecoded} frame(s) decoded over ${seconds}s, ` +
        `${this.totalErrors} decoder error(s), ${this.restarts.length} restart(s) in window, ` +
        `${this.framesDroppedRecovering} frame(s) dropped while recovering, ` +
        `${this.redFramesUnwrapped} RED payload(s) unwrapped; ` +
        `first error: ${this.firstErrorReason ?? "n/a"}; last error: ${this.lastErrorReason ?? "n/a"}`,
    );
    this.onFatalError(
      `${this.lastErrorReason ?? "decoder error"} — ${this.restarts.length} decoder restarts within ` +
        `${DECODER_RESTART_WINDOW_MS / 1000}s, giving up`,
    );
  }

  private logDecoderError(reason: string, decodedThisLife: number, healthy: boolean): void {
    const last = this.recentFrames.at(-1);
    const frameDesc = last
      ? `${last.byteLength}B ts=${last.timestamp} toc=0x${(last.toc & 0xff).toString(16).padStart(2, "0")}`
      : "none";
    console.error(
      `[ears][capture] ${this.track.id} ${reason} — ${healthy ? "decoder was healthy" : "barren decoder"}, ` +
        `${decodedThisLife} frame(s) decoded since rebuild; failing frame ~${frameDesc}`,
    );
    if (DEBUG_AUDIO_NOW()) {
      console.debug(
        `[ears][debug][audio] ${this.track.id} decoder error — last ${this.recentFrames.length} frames fed:`,
        this.recentFrames,
      );
    }
  }

  private onEncodedFrame(raw: EncodedAudioFrameLike): void {
    if (this.stopped) return;
    // Meet interleaves RED-encapsulated packets into the Opus stream when its
    // redundancy kicks in; unwrap those to their primary Opus block before
    // decode (see unwrapRedPayload). Non-RED payloads pass through untouched.
    let frame = raw;
    const primary = unwrapRedPayload(raw.data);
    if (primary) {
      frame = { data: primary, timestamp: raw.timestamp };
      this.redFramesUnwrapped++;
      if (this.redFramesUnwrapped === 1) {
        console.debug(
          `[ears][capture] ${this.track.id} RED-encapsulated audio detected — unwrapping primary Opus blocks`,
        );
      }
    }
    this.recordFrame(frame);
    if (!this.decoder) {
      // Decoder died and is cooling down: drop frames from before the next
      // decodable boundary rather than re-feeding the poisoned window into a
      // fresh decoder (the old restart spiral). Rebuild once the cooldown has
      // elapsed, resuming at this live frame.
      const cooling = this.coolingSince ?? 0;
      if (this.now() - cooling < DECODER_RESTART_COOLDOWN_MS) {
        this.framesDroppedRecovering++;
        return;
      }
      if (!this.restartDecoder()) return; // gave up — fatal already reported
    }
    if (!this.decoder || !this.chunkCtor) return;
    try {
      // Opus has no inter-frame prediction — every chunk is a keyframe.
      this.decoder.decode(new this.chunkCtor({ type: "key", timestamp: frame.timestamp, data: frame.data }));
      // A queue that grows means decode is falling behind delivery — the one
      // capture-path backlog that isn't visible from timing the JS stages,
      // because WebCodecs decodes off-thread.
      if (perfEnabled()) {
        const depth = (this.decoder as { decodeQueueSize?: number }).decodeQueueSize;
        if (typeof depth === "number") captureMetrics().decodeQueue.set(depth);
      }
    } catch (err) {
      this.onDecoderError(`decode() threw: ${String(err)}`);
    }
  }

  private recordFrame(frame: EncodedAudioFrameLike): void {
    const toc = frame.data.byteLength > 0 ? new Uint8Array(frame.data)[0]! : -1;
    this.recentFrames.push({ byteLength: frame.data.byteLength, timestamp: frame.timestamp, toc });
    if (this.recentFrames.length > 8) this.recentFrames.shift();
  }
}

function meetDecodeSource(track: MediaStreamTrack): FrameSourceFactory {
  return (onFrame, onFatalError) => new MeetDecodeSource(track, onFrame, onFatalError);
}

/**
 * Streaming linear resampler (inRate → outRate), phase-continuous across chunks.
 * Linear interpolation is adequate for speech at these rates. Shared unmodified
 * by every frame source — TrackCapture doesn't know or care where a frame came from.
 */
export class LinearResampler {
  private readonly step: number; // input samples advanced per output sample
  private cursor = 0; // fractional read position within the pending buffer
  private buf = new Float32Array(0);

  constructor(inRate: number, outRate: number) {
    this.step = inRate / outRate;
  }

  process(input: Float32Array): Float32Array {
    const merged = new Float32Array(this.buf.length + input.length);
    merged.set(this.buf);
    merged.set(input, this.buf.length);

    const out: number[] = [];
    let pos = this.cursor;
    while (Math.floor(pos) + 1 < merged.length) {
      const i = Math.floor(pos);
      const frac = pos - i;
      out.push(merged[i]! * (1 - frac) + merged[i + 1]! * frac);
      pos += this.step;
    }
    const keep = Math.floor(pos);
    this.buf = merged.slice(keep);
    this.cursor = pos - keep;
    return Float32Array.from(out);
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

// Bounded ring buffer, drop-oldest, with a logged dropped counter — never grows
// unbounded. Drop-oldest keeps the freshest audio when the consumer stalls.
export class RingBuffer {
  private q: Int16Array[] = [];
  private dropped = 0;
  constructor(
    private readonly capacity: number,
    private readonly label: string,
  ) {}

  push(frame: Int16Array): void {
    if (this.q.length >= this.capacity) {
      this.q.shift();
      this.dropped++;
      if (this.dropped % 50 === 1) {
        console.warn(`[ears][capture] ring overflow for ${this.label}: dropped ${this.dropped} frame(s)`);
      }
    }
    this.q.push(frame);
  }

  drain(): Int16Array[] {
    const out = this.q;
    this.q = [];
    return out;
  }
}
