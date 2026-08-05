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
