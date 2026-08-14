import { describe, expect, it } from "vitest";
import {
  decodeAttributionLine,
  encodeAttributionEvent,
  type AttributionEvent,
} from "../attribution-log";
import {
  MeetIdentityEngine,
  type MeetBindingDecision,
  type MeetIdentityDecision,
  type TrackPresence,
} from "./meet-identity-engine";

// The R2 replay test: a recorded attribution log (R1's event vocabulary,
// attribution.jsonl) drives the identity engine deterministically. This is the
// property the whole split exists for — the next Meet drift gets diagnosed by
// replaying the captured log against the engine, and its fix gets a
// failing-then-passing test from the same log, instead of another live call
// with real people (#158/#164/#172 all needed one).
//
// The fixture is synthetic (per the privacy rule real device ids and names
// never enter the repo): demo-shaped device paths, fixture names, and a
// timeline compressing the recurring live shapes into one call — a roster
// with the "(You)" marker, clean confirming turns, a local backchannel burst,
// a competing claim after binding, and a rejoin after the track ended.

/** TrackPresence derived from the log's own track-lifecycle events — the
 * replay-side stand-in for the shell's liveTracksById. */
class LogTrackPresence implements TrackPresence {
  private readonly known = new Set<string>();
  private readonly ended = new Set<string>();

  seen(trackId: string): void {
    this.known.add(trackId);
  }

  end(trackId: string): void {
    this.ended.add(trackId);
  }

  hasTrack(trackId: string): boolean {
    return this.known.has(trackId);
  }

  isTrackLive(trackId: string): boolean {
    return this.known.has(trackId) && !this.ended.has(trackId);
  }
}

/**
 * Feed one attribution.jsonl document to an engine, event by event, exactly
 * as the sensor shell would have: audio onsets and unmutes register the track
 * before observing it, dom bursts and collections edges pass straight
 * through, and a roster-delta event replays as one roster observation (its
 * isLocal row is the recorded "(You)" evidence). Non-attribution lines are
 * skipped, never guessed at — decodeAttributionLine's contract.
 */
function replay(
  jsonl: string,
  engine: MeetIdentityEngine,
  presence: LogTrackPresence,
): MeetIdentityDecision[] {
  const decisions: MeetIdentityDecision[] = [];
  for (const line of jsonl.split("\n")) {
    const event = decodeAttributionLine(line);
    if (!event) continue;
    switch (event.type) {
      case "track-appeared":
        presence.seen(event.trackId);
        break;
      case "track-ended":
        presence.end(event.trackId);
        break;
      case "audio-onset":
        presence.seen(event.trackId);
        decisions.push(...engine.trackSpeaking(event.trackId, event.state === "start", event.t));
        break;
      case "track-unmuted":
        presence.seen(event.trackId);
        decisions.push(...engine.trackUnmuted(event.trackId, event.t));
        break;
      case "dom-burst":
        decisions.push(...engine.deviceSpeaking(event.deviceId, event.t));
        break;
      case "collections-edge":
        decisions.push(...engine.collectionsEdge(event.deviceId, event.micOpen, event.t));
        break;
      case "roster-delta":
        decisions.push(
          ...engine.rosterObserved(
            event.entries.map((e) => ({ deviceId: e.participantId, displayName: e.displayName })),
            event.entries.find((e) => e.isLocal)?.participantId,
            event.t,
          ),
        );
        break;
      default:
        break; // admission/lifecycle events the engine doesn't consume
    }
  }
  return decisions;
}

const LOCAL = "spaces/demo/devices/1";
const ALICE = "spaces/demo/devices/2";
const BOB = "spaces/demo/devices/3";
const TRACK_1 = "fixture-track-1";
const TRACK_2 = "fixture-track-2";

const EVENTS: AttributionEvent[] = [
  // The call assembles: one remote track, and a roster whose "(You)" marker
  // resolves immediately.
  { type: "track-appeared", t: 1_000, trackId: TRACK_1, seam: "receiver-track", muted: false, origin: "remote" },
  {
    type: "roster-delta",
    t: 1_200,
    entries: [
      { participantId: LOCAL, displayName: "Demo You", isLocal: true },
      { participantId: ALICE, displayName: "Alice Fixture" },
      { participantId: BOB, displayName: "Bob Fixture" },
    ],
  },
  // Turn 1: Alice speaks — decoded-audio onset, then her ring burst 50ms later.
  { type: "audio-onset", t: 5_000, participantId: "speaker-1", trackId: TRACK_1, state: "start", framePeak: 0.31 },
  { type: "dom-burst", t: 5_050, deviceId: ALICE },
  { type: "audio-onset", t: 5_900, participantId: "speaker-1", trackId: TRACK_1, state: "stop", framePeak: 0.02 },
  // A mixed-evidence beat: the track's RTP unmute pairs with Alice's
  // collections mic-open edge (one confirmation in the unmute correlator —
  // below threshold, decides nothing on its own).
  { type: "track-unmuted", t: 8_000, trackId: TRACK_1 },
  { type: "collections-edge", t: 8_100, deviceId: ALICE, micOpen: true, rawB64: "Zml4dHVyZQ==" },
  // Turn 2 confirms the (track-1, Alice) pairing — the binding decision.
  { type: "audio-onset", t: 11_000, participantId: "speaker-1", trackId: TRACK_1, state: "start", framePeak: 0.4 },
  { type: "dom-burst", t: 11_050, deviceId: ALICE },
  // The local user backchannels: their ring burst is recorded as observed
  // (pre-filter, by design) and must be excluded on replay via the roster's
  // isLocal evidence — the journal-#158/#172 shape.
  { type: "dom-burst", t: 15_000, deviceId: LOCAL },
  // Bob's bursts land twice on the already-bound track (same-room audio, the
  // 86-rebind shape) — a competing claim, refused, never a rebind.
  { type: "audio-onset", t: 20_000, participantId: "speaker-1", trackId: TRACK_1, state: "start", framePeak: 0.35 },
  { type: "dom-burst", t: 20_050, deviceId: BOB },
  { type: "audio-onset", t: 26_000, participantId: "speaker-1", trackId: TRACK_1, state: "start", framePeak: 0.33 },
  { type: "dom-burst", t: 26_050, deviceId: BOB },
  // Alice's track dies (the AudioDecoder shape) and she rejoins on a fresh
  // one — the one legitimate second claim on her device.
  { type: "track-ended", t: 30_000, trackId: TRACK_1 },
  { type: "track-appeared", t: 33_000, trackId: TRACK_2, seam: "receiver-track", muted: false, origin: "remote" },
  { type: "audio-onset", t: 35_000, participantId: "speaker-2", trackId: TRACK_2, state: "start", framePeak: 0.28 },
  { type: "dom-burst", t: 35_050, deviceId: ALICE },
  { type: "audio-onset", t: 41_000, participantId: "speaker-2", trackId: TRACK_2, state: "start", framePeak: 0.3 },
  { type: "dom-burst", t: 41_050, deviceId: ALICE },
];

/** The log as it would sit on disk — encoded lines, with the foreign matter a
 * real file can contain (blank line, prose, an unknown future schema). */
const FIXTURE_JSONL = [
  ...EVENTS.slice(0, 4).map(encodeAttributionEvent),
  "",
  "not json at all",
  '{"schema":99,"type":"audio-onset","t":0,"trackId":"x"}',
  ...EVENTS.slice(4).map(encodeAttributionEvent),
].join("\n");

function runReplay(): { decisions: MeetIdentityDecision[]; engine: MeetIdentityEngine } {
  const presence = new LogTrackPresence();
  const engine = new MeetIdentityEngine(presence);
  const decisions = replay(FIXTURE_JSONL, engine, presence);
  return { decisions, engine };
}

describe("identity engine replay from a recorded attribution log", () => {
  it("re-derives the call's bindings from the log alone", () => {
    const { decisions, engine } = runReplay();

    const bindings = decisions.filter((d): d is MeetBindingDecision => d.kind === "binding");
    expect(bindings).toMatchObject([
      { outcome: "bound", trackId: TRACK_1, deviceId: ALICE, correlator: "dom", confirmations: 2, t: 11_050 },
      { outcome: "refused-rebind", trackId: TRACK_1, deviceId: BOB, boundDeviceId: ALICE, t: 26_050 },
      { outcome: "bound", trackId: TRACK_2, deviceId: ALICE, correlator: "dom", confirmations: 2, t: 41_050 },
    ]);
    expect(new Map(engine.bindings())).toEqual(
      new Map([
        [TRACK_1, ALICE],
        [TRACK_2, ALICE],
      ]),
    );
  });

  it("re-derives the local-device exclusion from the roster's isLocal evidence", () => {
    const { decisions, engine } = runReplay();

    expect(engine.localDevice).toBe(LOCAL);
    // The local user's backchannel burst at t=15000 decided nothing, and no
    // binding ever names the local device.
    expect(decisions.filter((d) => d.kind === "binding" && d.deviceId === LOCAL)).toEqual([]);
    expect(decisions.find((d) => d.kind === "local-resolved")).toMatchObject({ deviceId: LOCAL });
  });

  it("re-derives the roster, names included", () => {
    const { decisions, engine } = runReplay();

    expect(decisions.find((d) => d.kind === "roster")).toMatchObject({
      entries: [
        { participantId: LOCAL, displayName: "Demo You", isLocal: true },
        { participantId: ALICE, displayName: "Alice Fixture" },
        { participantId: BOB, displayName: "Bob Fixture" },
      ],
    });
    expect(engine.displayName(ALICE)).toBe("Alice Fixture");
  });

  it("is deterministic: the same log always yields the same decisions", () => {
    const first = runReplay().decisions;
    const second = runReplay().decisions;
    expect(second).toEqual(first);
  });
});
