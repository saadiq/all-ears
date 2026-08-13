// The pure decision half of Meet identity (docs/plans/attribution-refactor.md
// R2). MeetAdapter (meet.ts) is the sensor shell — MutationObserver wiring,
// tile scans, collections listener registration, everything that *produces*
// observations — and this engine is where the observations become decisions.
//
// Contract, per the plan and docs/engineering-practices.md tier 0:
//   - No DOM, no WebRTC objects, no clock reads. Every entry point takes the
//     caller's epoch-ms timestamp, so a recorded attribution log (R1's event
//     vocabulary, attribution-log.ts) can drive the engine deterministically —
//     see meet-identity-replay.test.ts.
//   - Inputs are observations shaped like the flight recorder's events: track
//     speaking onsets, track unmutes, tile speaking-ring bursts, collections
//     mic edges, roster scans.
//   - Outputs are typed decisions (MeetIdentityDecision). The shell translates
//     them into today's onIdentify/onRename/onRoster callbacks and records
//     each binding decision as a `provisional-binding` event — the decision
//     type deliberately mirrors that event's fields.
//
// The one impurity is injected: TrackPresence answers "does the shell hold a
// usable MediaStreamTrack for this id, and is it live?". Track objects are
// page-entangled and stay in the shell; the engine only ever needs those two
// predicates (the bound vs bound-late-rename choice, and the one-device-one-
// live-track rule). A replay supplies them from the log's track lifecycle
// events.

import type { BindingOutcome, CorrelatorId } from "../attribution-log";
import type { ParticipantId, RosterEntry } from "../protocol";
import { SpeakingCorrelator, type CorrelatorMatch } from "./meet-correlator";

// Consecutive confirming turns (SpeakingCorrelator) required before a match
// becomes a binding decision. Shipped at 3 (conservative per Task 4), loosened
// to 1 after the 2026-07-19 live run showed zero ambiguous matches, then
// raised back to 2 on 2026-08-05: a live call confirmed a join on a single
// unmute-edge turn while two same-room devices were hearing the same voice —
// exactly the coincidence a 1-turn threshold cannot reject (the correlator's
// distinct-tracks guard only sees ONE track's onset when the other device is
// muted). One coincidence is cheap; two consecutive coincidences for the same
// (track, device) pairing are not. The DOM speaking-ring correlator added the
// same day supplies a device onset per natural turn, so reaching 2 no longer
// requires two deliberate mute toggles — normal conversation gets there in
// two turns. Counts are per correlator instance, never summed across them
// (one physical toggle can legitimately match in two correlators at once and
// must not self-corroborate).
export const CONFIRM_THRESHOLD = 2;
const CORRELATION_WINDOW_MS = 200; // journal #50: onset pairs landed within tens of ms
// The collections mic-open edge and the track's "unmute" event land close but
// not tens-of-ms close: the DC message rides a different transport than the
// RTP unmute, and the 2026-07-24 controlled test measured them within the
// same second (≤ ~900ms apart) on every toggle. 2s covers that with margin
// while staying far under the ~5s a human takes between deliberate toggles.
const UNMUTE_CORRELATION_WINDOW_MS = 2_000;
// The speaking-ring burst rides Meet's render pipeline (worklet → UI state →
// RAF-batched class churn), landing later after the audio onset than the
// tens-of-ms the 200ms audio window assumes. Turns are seconds apart and the
// correlator's distinct-tracks guard handles overlap, so 1s is safe margin.
const DOM_CORRELATION_WINDOW_MS = 1_000;

/** The shell's answers about the MediaStreamTrack objects it holds — the only
 * page state a binding decision depends on. */
export interface TrackPresence {
  /** Whether the shell holds a track object for `trackId` that an onIdentify
   * pipeline restart could use. */
  hasTrack(trackId: string): boolean;
  /** Whether that track's readyState is still "live". */
  isTrackLive(trackId: string): boolean;
}

/** A confirmed correlator match and what the engine decided about it. Mirrors
 * the flight recorder's `provisional-binding` event so the shell records it
 * verbatim. The `refused-*` outcomes are the journal-#158 guards. */
export interface MeetBindingDecision {
  kind: "binding";
  t: number;
  trackId: string;
  deviceId: ParticipantId;
  correlator: CorrelatorId;
  confirmations: number;
  outcome: BindingOutcome;
  /** On "refused-rebind": the device the track already carries. */
  boundDeviceId?: ParticipantId;
  /** On "refused-device-claimed": the live track already carrying the device. */
  owningTrackId?: string;
}

export type MeetIdentityDecision =
  | MeetBindingDecision
  /** The "(You)" marker resolved: `deviceId` is the local participant, now
   * excluded from all correlation for the life of the engine. */
  | { kind: "local-resolved"; t: number; deviceId: ParticipantId }
  /** Newly-resolved or changed (id → name) pairs since the last roster
   * decision — the delta the shell forwards via onRoster, with `isLocal`
   * marked on the local participant's row. */
  | { kind: "roster"; t: number; entries: RosterEntry[] }
  /** A roster exists but no row carries the "(You)" marker — a build or
   * locale that never renders it must not look like working code (MUST-NOT
   * #13). Decided at most once per engine. */
  | { kind: "no-self-marker"; t: number; namedCount: number };

/**
 * The newly-resolved or changed (id → name) pairs in `names` that `emitted`
 * hasn't seen yet, as roster entries — and mutates `emitted` to record them.
 * Pure and side-effect-scoped to `emitted`: the engine calls it on every
 * roster observation and decides only the delta, so a participant's name
 * reaches the daemon once (not once per 3s poll) and a corrected name (Meet
 * swaps a placeholder for the real one) re-emits. Empty names are already
 * excluded upstream (only truthy names enter `names`).
 */
export function rosterDelta(
  names: ReadonlyMap<ParticipantId, string>,
  emitted: Map<ParticipantId, string>,
): RosterEntry[] {
  const fresh: RosterEntry[] = [];
  for (const [id, name] of names) {
    if (emitted.get(id) === name) continue;
    emitted.set(id, name);
    fresh.push({ participantId: id, displayName: name });
  }
  return fresh;
}

/**
 * Holds all Meet binding state — the three SpeakingCorrelator instances, the
 * track→device and device→track binding maps, and the local participant's
 * latched device id. One instance per capture epoch (the shell owns exactly
 * one and dies with it).
 */
export class MeetIdentityEngine {
  // ── Correlators (see file-header doc in meet.ts for the live evidence) ──
  /** Collections mic-open edge ↔ decoded-audio onset. Only fires in the
   * join-unmuted case on current builds (the channel lost per-turn events,
   * 2026-07-24); kept because it costs nothing and re-arms if they return. */
  private readonly correlator = new SpeakingCorrelator(CORRELATION_WINDOW_MS);
  /** Collections mic-open edge ↔ track-level unmute — the pairing the current
   * build's channel actually supports. */
  private readonly unmuteCorrelator = new SpeakingCorrelator(UNMUTE_CORRELATION_WINDOW_MS);
  /** Tile speaking-ring burst ↔ decoded-audio onset — the per-turn pairing
   * the collections channel lost (2026-08-05). */
  private readonly domCorrelator = new SpeakingCorrelator(DOM_CORRELATION_WINDOW_MS);

  /** track.id → deviceId already decided. A track binds to one device for its
   * life: a repeat match decides nothing, and a match naming a *different*
   * device is refused outright (journal #158 — a rebind restarts the capture
   * pipeline under a new source id, so a pairing that oscillates shreds one
   * participant's speech across two named sources). The correlator's symmetric
   * ambiguity rule is what should stop the oscillation upstream; this bounds
   * the damage of any that gets through to one wrong name instead of a
   * 30-minute flip-flop. */
  private readonly upgradedTracks = new Map<string, ParticipantId>();
  /** deviceId → the track.id currently bound to it, so one participant can't
   * own two live tracks at once. A device whose owning track has ended stops
   * blocking — that's a genuine rejoin, not a competing claim. */
  private readonly deviceOwners = new Map<ParticipantId, string>();
  /** The local participant's own device id, latched once observed — it cannot
   * change for the life of a call. undefined means "not established", which
   * excludes nobody (the pre-#158 behaviour, wrong in a bounded way). */
  private localDeviceId: ParticipantId | undefined;
  /** id → last-known display name. Kept for the engine's life (leave/rejoin
   * gets a fresh identify() anyway). */
  private readonly names = new Map<ParticipantId, string>();
  /** id → name already decided into a roster delta, so each observation
   * decides only what is new (see rosterDelta). */
  private readonly emittedNames = new Map<ParticipantId, string>();
  private warnedNoSelfMarker = false;

  constructor(private readonly tracks: TrackPresence) {}

  /** The latched local device id, or undefined while unestablished. */
  get localDevice(): ParticipantId | undefined {
    return this.localDeviceId;
  }

  /** Snapshot of the track → device bindings decided so far. */
  bindings(): ReadonlyMap<string, ParticipantId> {
    return new Map(this.upgradedTracks);
  }

  /** A track's decoded audio crossed a speaking edge at `at`. Only onsets feed
   * the correlators (see meet-correlator.ts). */
  trackSpeaking(trackId: string, speaking: boolean, at: number): MeetIdentityDecision[] {
    if (!speaking) return [];
    const out: MeetIdentityDecision[] = [];
    this.applyMatch(out, this.correlator.recordAudioOnset(trackId, at), "collections", at);
    this.applyMatch(out, this.domCorrelator.recordAudioOnset(trackId, at), "dom", at);
    return out;
  }

  /** A track's RTP resumed ("unmute") at `at` — pairs with the collections
   * mic-open edge. (RTP also resumes after DTX silence with no collections
   * edge; those unmutes age out of the correlator's history.) */
  trackUnmuted(trackId: string, at: number): MeetIdentityDecision[] {
    const out: MeetIdentityDecision[] = [];
    this.applyMatch(out, this.unmuteCorrelator.recordAudioOnset(trackId, at), "unmute", at);
    return out;
  }

  /** A tile speaking-ring burst onset for `deviceId` at `at`. The local
   * participant's bursts are dropped at the door — that is the real fix for
   * journal #158: the user's bursts while they backchannel over someone else's
   * turn are what land inside a remote track's onset window and confirm a
   * wrong pairing. The correlator's ambiguity rules can only make that pairing
   * *harder* to reach; they cannot know it is nonsense. */
  deviceSpeaking(deviceId: ParticipantId, at: number): MeetIdentityDecision[] {
    if (this.isLocalDevice(deviceId)) return [];
    const out: MeetIdentityDecision[] = [];
    this.applyMatch(out, this.domCorrelator.recordDeviceOnset(deviceId, at), "dom", at);
    return out;
  }

  /** A parsed collections-datachannel mute edge. Only the mic-open edge is a
   * correlatable onset, and the local participant's own toggle is excluded for
   * the same reason as deviceSpeaking. */
  collectionsEdge(deviceId: ParticipantId, micOpen: boolean, at: number): MeetIdentityDecision[] {
    if (!micOpen) return [];
    if (this.isLocalDevice(deviceId)) return [];
    const out: MeetIdentityDecision[] = [];
    this.applyMatch(out, this.correlator.recordDeviceOnset(deviceId, at), "collections", at);
    this.applyMatch(out, this.unmuteCorrelator.recordDeviceOnset(deviceId, at), "unmute", at);
    return out;
  }

  /**
   * One roster observation: the named tiles a scan found, plus the device id
   * carrying the "(You)" marker when the scan could establish it beyond doubt
   * (findLocalDeviceId; undefined otherwise). Decides, in order:
   *
   *  - `local-resolved`, the first time a marker arrives. Latched rather than
   *    re-read because the answer cannot change within a call and re-reading
   *    could only ever lose it. The marker routinely resolves *after* that
   *    device's name was already decided into a delta, so its emitted record
   *    is dropped and the same decision's roster delta re-sends it, now
   *    carrying `isLocal` — without that the daemon never learns which roster
   *    row is the user and falls back to inferring it.
   *  - `no-self-marker`, at most once, when names exist but no marker has ever
   *    been seen (an empty roster early in a call is normal and decides
   *    nothing).
   *  - `roster`, when the observation added or changed any (id → name) pair.
   */
  rosterObserved(
    named: ReadonlyArray<{ deviceId: ParticipantId; displayName: string }>,
    localDeviceId: ParticipantId | undefined,
    at: number,
  ): MeetIdentityDecision[] {
    for (const { deviceId, displayName } of named) this.names.set(deviceId, displayName);
    const out: MeetIdentityDecision[] = [];
    if (this.localDeviceId === undefined) {
      if (localDeviceId !== undefined) {
        this.localDeviceId = localDeviceId;
        this.emittedNames.delete(localDeviceId);
        out.push({ kind: "local-resolved", t: at, deviceId: localDeviceId });
      } else if (!this.warnedNoSelfMarker && this.names.size > 0) {
        this.warnedNoSelfMarker = true;
        out.push({ kind: "no-self-marker", t: at, namedCount: this.names.size });
      }
    }
    const fresh = rosterDelta(this.names, this.emittedNames);
    if (fresh.length > 0) {
      for (const entry of fresh) {
        if (this.localDeviceId !== undefined && entry.participantId === this.localDeviceId) {
          entry.isLocal = true;
        }
      }
      out.push({ kind: "roster", t: at, entries: fresh });
    }
    return out;
  }

  /** A single tile correlation resolved a name outside a full roster scan
   * (identify()'s path). Recorded for displayName and for the next roster
   * observation's delta; decides nothing by itself, same as today. */
  nameObserved(deviceId: ParticipantId, displayName: string): void {
    this.names.set(deviceId, displayName);
  }

  /** Last-known display name for a device id, if any roster observation or
   * tile correlation has resolved one. */
  displayName(deviceId: ParticipantId): string | undefined {
    return this.names.get(deviceId);
  }

  private isLocalDevice(deviceId: ParticipantId): boolean {
    if (this.localDeviceId === undefined) return false;
    return this.localDeviceId === deviceId;
  }

  /** Judge a correlator result against the binding rules; a confirmed match
   * always yields exactly one decision (bound or refused), except the silent
   * already-bound-to-this-device repeat, which decides nothing new. */
  private applyMatch(
    out: MeetIdentityDecision[],
    match: CorrelatorMatch | null,
    correlator: CorrelatorId,
    at: number,
  ): void {
    if (!match || match.confirmations < CONFIRM_THRESHOLD) return;
    const base = {
      kind: "binding" as const,
      t: at,
      trackId: match.trackKey,
      deviceId: match.deviceId,
      correlator,
      confirmations: match.confirmations,
    };
    if (this.isLocalDevice(match.deviceId)) {
      // Belt and braces: the onset filters should mean this never fires, but a
      // pairing confirmed against onsets recorded before the marker was first
      // read can still arrive here.
      out.push({ ...base, outcome: "refused-local-device" });
      return;
    }
    const bound = this.upgradedTracks.get(match.trackKey);
    if (bound !== undefined) {
      if (bound !== match.deviceId) {
        out.push({ ...base, outcome: "refused-rebind", boundDeviceId: bound });
      }
      return; // already decided, or a rebind — either way, nothing new
    }
    const owner = this.deviceOwners.get(match.deviceId);
    if (owner !== undefined && owner !== match.trackKey && this.tracks.isTrackLive(owner)) {
      out.push({ ...base, outcome: "refused-device-claimed", owningTrackId: owner });
      return;
    }
    this.upgradedTracks.set(match.trackKey, match.deviceId);
    this.deviceOwners.set(match.deviceId, match.trackKey);
    if (!this.tracks.hasTrack(match.trackKey)) {
      // The correlation confirmed, but the shell holds no track to restart —
      // too late for onIdentify. The join lands as a rename instead: audio
      // already recorded under the fallback id keeps its source, and the
      // daemon attaches that source to the named attendee (the Etel case —
      // journal #45).
      out.push({ ...base, outcome: "bound-late-rename" });
      return;
    }
    out.push({ ...base, outcome: "bound" });
  }
}
