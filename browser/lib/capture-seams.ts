// Capture seams: the several places a platform's decoded participant audio can
// be reached, and the runtime arbitration that picks whichever one is actually
// carrying audio on THIS call.
//
// Why this exists (journal #31, #73, #82, #93, #103, #104): Meet's internal
// audio path moved four times in twelve days — createEncodedStreams tee →
// NetEQ SAB WASM → off the RTP receiver path per-call → no neteq worklet at
// all. Every previous fix hardcoded one seam in startPipeline and broke on the
// next migration. #82 is the decisive observation: the migration happens per
// CALL, not per build, so the choice cannot be made at compile time or even at
// page load — only by watching which seam yields frames on the live call.
//
// The arbitration is deliberately per-CALL rather than per-track. A per-track
// choice would need to know which WebAudio track belongs to which receiver
// track, and rtc-hook.ts:654 records that those ids never match. Per-call
// sidesteps that entirely and matches the observed failure mode: when Meet
// migrates, it migrates the whole call's audio at once.
//
// This module is the pure half — seam ordering and the escalation state
// machine, no DOM and no clock reads (tier-0 per docs/engineering-practices.md,
// callers pass timestamps in). The DOM-touching half (discovering tracks,
// building frame sources) lives in audio-tap.ts next to the pipeline it feeds.

import type { Platform } from "./protocol";

/**
 * A way of reaching decoded participant audio.
 *
 * - `receiver-track` — MediaStreamTrackProcessor on the RTP receiver track the
 *   `ontrack` hook handed us. Carries identity, works on Zoom/Teams and on Meet
 *   builds that keep audio on the receiver path.
 * - `webaudio-track` — MediaStreamTrackProcessor on a track Meet passed to
 *   `createMediaStreamSource` (rtc-hook.ts's passive wrap). Carries real audio
 *   on builds where the receiver tracks are silent decoys (journal #105), but
 *   no identity — see `seamUsesReceiverTracks`.
 * - `meet-encoded-tee` — AudioDecoder fed by the createEncodedStreams tee.
 *   Validated on the Jul 18 build (journal #31), dead since Jul 21 (#73), kept
 *   because Meet has reverted paths before and the cost of keeping it is a
 *   table entry.
 * - `graph-bridge` — a MediaStreamAudioDestinationNode branched off the native
 *   node downstream of Meet's neteq worklet (`__earsGraphBridge`, journal #98).
 *   Not in any `seamOrderFor` list: it is activated by its own flag at the
 *   moment Meet wires the node, not chosen by arbitration. It appears here so
 *   pipelines it feeds are labelled honestly in the debug report.
 */
export type SeamId = "receiver-track" | "webaudio-track" | "meet-encoded-tee" | "graph-bridge";

/**
 * How long an unmuted-but-frameless call waits before trying the next seam.
 *
 * Matched to SILENT_CAPTURE_GRACE_MS in audio-tap.ts, which uses the same
 * signal for its per-participant warning: an `unmute` means the platform says
 * this participant is producing audio, so a decoded frame must follow. Waiting
 * on unmute rather than on pipeline start is what stops a genuinely quiet call
 * from escalating through every seam before anyone has spoken.
 */
export const SEAM_ESCALATION_GRACE_MS = 4_000;

/**
 * Seams to try for `platform`, most-preferred first.
 *
 * `receiver-track` leads everywhere because it is the only seam whose tracks
 * carry identity directly (the transceiver and stream reach `resolveIdentity`).
 * Falling past it costs attribution quality, so it is never skipped
 * speculatively — only after it demonstrably fails to produce a frame.
 */
export function seamOrderFor(platform: Platform): SeamId[] {
  switch (platform) {
    case "meet":
      // WebAudio before the tee: the registry is filled by a passive prototype
      // wrap that runs on every build, whereas the tee only exists if Meet
      // itself calls createEncodedStreams — which it has not since journal #73.
      return ["receiver-track", "webaudio-track", "meet-encoded-tee"];
    default:
      // Zoom and Teams read real audio straight off the receiver track
      // (journal #31). Speculative fallbacks there would risk double-capture
      // for no benefit, so they stay on the one seam that works.
      return ["receiver-track"];
  }
}

/**
 * Whether a seam builds its pipelines on the `ontrack` receiver track.
 *
 * This one predicate answers both questions that matter, because they have the
 * same answer. Such a seam (a) takes its tracks from the hook's live registry
 * rather than discovering its own, and (b) carries identity, since the
 * transceiver and stream reach `resolveIdentity`.
 *
 * `meet-encoded-tee` counts: the tee fires on the receiver and its pipeline is
 * keyed on the receiver track — only the *frames* come from the decoder. That
 * is why it delivered named per-participant audio on the Jul 18 build
 * (journal #31).
 *
 * Seams that are false here have track ids that never match a hooked receiver
 * (rtc-hook.ts:654), so they start under a provisional id and are named later
 * by the existing speaking-onset correlation (SpeakingCorrelator →
 * adapter.onIdentify → handleIdentityUpgrade).
 */
export function seamUsesReceiverTracks(seam: SeamId): boolean {
  return seam === "receiver-track" || seam === "meet-encoded-tee";
}

/**
 * Track provenance as the adoption policy consumes it — data in, so this
 * tier-0 module stays pure. Mirrors rtc-hook.ts's TrackProvenanceRecord; an
 * id with no entry is simply unknown.
 */
export interface TrackProvenanceInfo {
  origin: "local" | "remote";
  /** Lineage root — clones of one root carry the same audio. */
  rootId: string;
  /** Registration order; the earliest-registered track per root is kept. */
  seq: number;
}

/**
 * Which of the seam's currently-available tracks to adopt.
 *
 * Pure so the rules are testable without a DOM:
 * - the receiver seam never adopts here (its tracks arrive through the
 *   `ontrack` sink, and adopting them again would double-capture);
 * - a `local`-origin track is never adopted — that is the user's own audio,
 *   which the daemon's mic source already records (the 2026-08-05 call
 *   adopted three copies of the local mic and quadruplicated the transcript);
 * - one track per lineage root: clones carry identical audio, so the
 *   earliest-registered wins, and a root with any member already adopted is
 *   settled;
 * - a track already adopted is never adopted twice however often the
 *   reconcile sweep runs;
 * - an id with no provenance entry always adopts (its own root): a wrongly
 *   dropped remote track is unrecoverable data loss, so unknown fails safe.
 *
 * Adopting on `unknown` is only safe because it is reversible: see
 * ``seamTracksToRetire``, which the same sweep runs first.
 */
export function seamTracksToAdopt(
  seam: SeamId,
  availableIds: readonly string[],
  adoptedIds: ReadonlySet<string>,
  provenance?: ReadonlyMap<string, TrackProvenanceInfo>,
): string[] {
  if (seamUsesReceiverTracks(seam)) return [];
  const rootOf = (id: string): string => provenance?.get(id)?.rootId ?? id;
  const seqOf = (id: string): number => provenance?.get(id)?.seq ?? Number.MAX_SAFE_INTEGER;
  const adoptedRoots = new Set<string>();
  for (const id of adoptedIds) adoptedRoots.add(rootOf(id));
  const keeperByRoot = new Map<string, string>();
  for (const id of availableIds) {
    if (provenance?.get(id)?.origin === "local") continue;
    const root = rootOf(id);
    if (adoptedRoots.has(root)) continue;
    const keeper = keeperByRoot.get(root);
    if (keeper === undefined || seqOf(id) < seqOf(keeper)) keeperByRoot.set(root, id);
  }
  const keep = new Set(keeperByRoot.values());
  return availableIds.filter((id) => keep.has(id) && !adoptedIds.has(id));
}

/** What to do with a receiver track the `ontrack` hook just handed us. */
export type ReceiverAdmission = "start" | "defer-until-unmute" | "skip";

/**
 * Whether a receiver track should start a pipeline now, wait, or be ignored.
 *
 * The `defer-until-unmute` verdict exists because Meet pre-allocates remote
 * audio transceivers before there is anyone to fill them: journal #142 found
 * three in a SOLO call, and #165 confirmed the same three on a two-person call
 * with only the carrying one ever unmuting. Starting a pipeline for each one
 * mints a `speaker-<n>` attendee for a participant who does not exist — the
 * phantom roster entries in every session file since July.
 *
 * Deferring costs nothing. A muted track carries no audio by definition, and
 * `AudioFrameSource` already could not build its processor until that same
 * unmute edge (a MediaStreamTrackProcessor constructed on a muted track never
 * delivers frames, even after it unmutes). The pipeline was always starting at
 * first unmute; this only stops us *announcing a participant* before then.
 *
 * Scope: receiver tracks only. Webaudio-seam tracks all report `muted=false`
 * even when inert — on 2026-08-12 all three were unmuted and two transcribed to
 * zero segments (#171) — so `muted` cannot filter those, and silence alone must
 * never retire a source, because a genuinely quiet participant looks identical
 * under DTX / noise suppression.
 */
export function admitReceiverTrack(
  seam: SeamId,
  opts: { muted: boolean; alreadyCapturing: boolean },
): ReceiverAdmission {
  if (opts.alreadyCapturing) return "skip";
  // Past the receiver-based seams the tracks are known-silent decoys (#82).
  if (!seamUsesReceiverTracks(seam)) return "skip";
  return opts.muted ? "defer-until-unmute" : "start";
}

/**
 * Adopted tracks that have since been classified `local` — the user's own
 * audio, captured a second time behind the daemon's mic source.
 *
 * The counterpart to `seamTracksToAdopt`'s "unknown adopts" rule, and the
 * reason that rule can stay as permissive as it is. Provenance only ever
 * improves: a track can arrive unclassified (the hook installing after Meet's
 * `getUserMedia`, or Meet handing over a processed track whose lineage was
 * never recorded) and be named `local` later, when the page hands it to a
 * sender. Reading provenance once, at adoption, threw that away — so a local
 * track that lost its first race stayed adopted for the whole call (the
 * 2026-08-06 call transcribed the user twice and left the identity correlator
 * with two tracks carrying one voice, which it could not name consistently).
 *
 * Retiring fails safe in the same direction as adopting: a `local` verdict is
 * *evidence*, never the absence of it, so this only ever acts on a positive
 * classification. An unknown track is left alone exactly as it is at adoption.
 */
export function seamTracksToRetire(
  adoptedIds: ReadonlySet<string>,
  provenance?: ReadonlyMap<string, TrackProvenanceInfo>,
): string[] {
  return [...adoptedIds].filter((id) => provenance?.get(id)?.origin === "local");
}

/**
 * The subset of `MediaStreamTrack.getSettings()` locality is decided on.
 * Data in, so this module stays pure — the DOM read happens at the boundary.
 *
 * `deviceId` is named here to document that it is *not* consulted: it is
 * present and truthy on decoded remote tracks too, so it discriminates
 * nothing. See ``looksLikeCaptureDevice``.
 */
export interface TrackSettingsLike {
  deviceId?: string;
  groupId?: string;
}

/**
 * Whether these settings describe a capture device — a microphone, not a
 * decoded remote stream.
 *
 * The positive locality signal that does not depend on having witnessed the
 * `getUserMedia` call: a track backed by a real input device reports the
 * device group it belongs to, and nothing else does. Still classification from
 * the page's own API contract rather than from signal analysis, the same rule
 * the rest of provenance follows.
 *
 * **`groupId` only, and deliberately not `deviceId`.** Verified against a live
 * Meet call on Chrome 151 (2026-08-06), reading `getSettings()` off every track
 * in the webaudio registry plus a local `RTCPeerConnection` loopback:
 *
 * | track                          | `deviceId`          | `groupId` |
 * | ------------------------------ | ------------------- | --------- |
 * | `getUserMedia` mic             | `"default"`         | present   |
 * | Meet's WebAudio-minted tracks  | echoes the track id | absent    |
 * | WebRTC decoded remote (ontrack)| a UUID              | absent    |
 * | `MediaStreamAudioDestinationNode` | `"WebAudio-…"`   | absent    |
 *
 * `deviceId` is truthy on *every* shape, so testing it would have called every
 * remote participant local and dropped their audio — the one direction this
 * classifier must never fail in. `groupId` separated the six local mic tracks
 * from the three `ontrack` tracks with no false positives in either direction,
 * and caught two local tracks provenance had as `unknown`.
 *
 * Known blind spot, by construction rather than by accident: a *processed*
 * local mic (Meet's noise suppression re-mints the track through WebAudio)
 * reports no `groupId` either, so it reads as unknown here and adopts.
 * ``seamTracksToRetire`` is what covers that case, once the page hands the
 * processed track to a sender.
 */
export function looksLikeCaptureDevice(settings: TrackSettingsLike | undefined): boolean {
  return Boolean(settings?.groupId);
}

/**
 * Decides which seam the call is capturing through.
 *
 * Escalation rule: an `unmute` arms a grace window; if no frame decodes on the
 * active seam before it expires, that seam is not carrying this call's audio
 * and the next one is tried. The first frame proves the seam and locks it in
 * permanently — a proven seam falling quiet means participants stopped talking,
 * never that the seam broke, so it must not churn.
 *
 * Deterministic and clock-free: `tick` is the only thing that advances time and
 * the caller supplies `now`.
 */
export class SeamArbiter {
  private index = 0;
  /** Deadline for the active seam to produce a frame, or null when unarmed. */
  private deadline: number | null = null;
  private provenSeam = false;

  constructor(
    private readonly seams: SeamId[] | string[],
    private readonly graceMs: number = SEAM_ESCALATION_GRACE_MS,
  ) {
    if (seams.length === 0) throw new Error("SeamArbiter needs at least one seam");
  }

  get active(): string {
    return this.seams[this.index]!;
  }

  /** True once the active seam has decoded a frame — it is then permanent. */
  get proven(): boolean {
    return this.provenSeam;
  }

  /** True when there is no further seam to fall back to. */
  get exhausted(): boolean {
    return this.index >= this.seams.length - 1;
  }

  /**
   * A participant unmuted: the platform is claiming audio is flowing now, so a
   * frame must follow. Arms the grace window unless the seam is already proven.
   * A later unmute pushes the deadline out rather than inheriting a stale one,
   * so the active seam always gets a full window from the most recent claim.
   */
  noteUnmute(now: number): void {
    if (this.provenSeam) return;
    this.deadline = now + this.graceMs;
  }

  /**
   * A frame decoded. `seam` guards against a straggler from a torn-down seam
   * landing after escalation and wrongly proving the new one; omit it when the
   * caller has no seam to attribute the frame to.
   */
  noteFrame(_now: number, seam?: string): void {
    if (seam !== undefined && seam !== this.active) return;
    this.provenSeam = true;
    this.deadline = null;
  }

  /**
   * Advance time. Returns the newly-activated seam when this tick escalated,
   * or null when nothing changed. Escalation re-arms the grace so a dead
   * second seam falls through to a third on the next window.
   */
  tick(now: number): string | null {
    if (this.provenSeam || this.deadline === null) return null;
    if (now < this.deadline) return null;
    if (this.exhausted) {
      // Nothing left to try. Disarm so the caller isn't asked to re-tear-down
      // the same seam every tick for the rest of the call.
      this.deadline = null;
      return null;
    }
    this.index += 1;
    this.deadline = now + this.graceMs;
    return this.active;
  }
}
