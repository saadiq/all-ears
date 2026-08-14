import { beforeEach, describe, expect, it } from "vitest";
import {
  CONFIRM_THRESHOLD,
  MeetIdentityEngine,
  rosterDelta,
  type MeetBindingDecision,
  type MeetIdentityDecision,
  type TrackPresence,
} from "./meet-identity-engine";

// The engine is the pure decision half of Meet identity: no DOM, no window, no
// clocks — observations in (each with a caller timestamp), typed decisions
// out. These are the adapter binding tests from meet.test.ts rewritten at the
// engine boundary (per docs/plans/attribution-refactor.md R2), with the
// decisions themselves — previously observable only as console lines and
// flight-recorder events — now asserted directly.

/** Stand-in for the shell's liveTracksById: which track ids the shell holds a
 * MediaStreamTrack object for, and whether each is still live. */
class FakePresence implements TrackPresence {
  private readonly state = new Map<string, "live" | "ended">();

  seen(trackId: string): void {
    if (!this.state.has(trackId)) this.state.set(trackId, "live");
  }

  end(trackId: string): void {
    this.state.set(trackId, "ended");
  }

  hasTrack(trackId: string): boolean {
    return this.state.has(trackId);
  }

  isTrackLive(trackId: string): boolean {
    return this.state.get(trackId) === "live";
  }
}

describe("MeetIdentityEngine track ↔ device binding (journal #158)", () => {
  let clock: number;
  let presence: FakePresence;
  let engine: MeetIdentityEngine;
  let decisions: MeetIdentityDecision[];

  beforeEach(() => {
    clock = 100_000;
    presence = new FakePresence();
    engine = new MeetIdentityEngine(presence);
    decisions = [];
  });

  /** One clean turn: the track's audio onset, then that device's ring burst
   * 50ms later. Turns are 5s apart — clear of the 1s onset debounce and of the
   * 3s history that holds consumed pairings. */
  function turn(trackId: string, deviceId: string): void {
    clock += 5000;
    presence.seen(trackId); // the shell registers every track it hears
    decisions.push(...engine.trackSpeaking(trackId, true, clock));
    decisions.push(...engine.deviceSpeaking(deviceId, clock + 50));
  }

  function confirm(trackId: string, deviceId: string): void {
    for (let i = 0; i < CONFIRM_THRESHOLD; i++) turn(trackId, deviceId);
  }

  function bindings(): Array<[string, string]> {
    return decisions
      .filter((d): d is MeetBindingDecision => d.kind === "binding" && d.outcome === "bound")
      .map((d) => [d.trackId, d.deviceId]);
  }

  function refusals(): MeetBindingDecision[] {
    return decisions.filter(
      (d): d is MeetBindingDecision => d.kind === "binding" && d.outcome.startsWith("refused"),
    );
  }

  it("requires CONFIRM_THRESHOLD ≥ 2 corroborating turns (2026-08-05: a 1-turn join misattributed under same-room audio)", () => {
    expect(CONFIRM_THRESHOLD).toBeGreaterThanOrEqual(2);
  });

  it("decides nothing below the confirmation threshold", () => {
    turn("track-a", "devices/160"); // one coincidence is cheap
    expect(decisions).toEqual([]);
  });

  it("refuses to rebind a track that already carries a device (the 86-generation flip-flop)", () => {
    confirm("track-remote", "devices/160");
    // The local participant's device then confirms against the same remote
    // track — the live failure, once its ring bursts stopped colliding.
    confirm("track-remote", "devices/159");

    expect(bindings()).toEqual([["track-remote", "devices/160"]]);
    expect(refusals()).toMatchObject([
      {
        outcome: "refused-rebind",
        trackId: "track-remote",
        deviceId: "devices/159",
        boundDeviceId: "devices/160",
        correlator: "dom",
      },
    ]);
  });

  it("decides nothing on a repeat match for the binding it already made", () => {
    confirm("track-remote", "devices/160");
    const before = decisions.length;
    confirm("track-remote", "devices/160");
    expect(decisions.length).toBe(before); // already decided — not even a re-record
  });

  it("refuses a second live track's claim on a device another live track already carries", () => {
    confirm("track-a", "devices/160");
    confirm("track-b", "devices/160");

    expect(bindings()).toEqual([["track-a", "devices/160"]]);
    expect(refusals()).toMatchObject([
      { outcome: "refused-device-claimed", trackId: "track-b", owningTrackId: "track-a" },
    ]);
  });

  it("lets a fresh track claim a device whose previous track has ended (a rejoin)", () => {
    confirm("track-a", "devices/160");
    presence.end("track-a");
    confirm("track-a2", "devices/160");

    expect(bindings()).toEqual([
      ["track-a", "devices/160"],
      ["track-a2", "devices/160"],
    ]);
  });

  it("still upgrades an unbound track to an unclaimed device", () => {
    confirm("track-a", "devices/160");
    confirm("track-b", "devices/161");

    expect(bindings()).toEqual([
      ["track-a", "devices/160"],
      ["track-b", "devices/161"],
    ]);
  });

  it("binds as a late rename when the shell holds no track object for the id", () => {
    // The Etel case (journal #45): the correlation confirms after the track is
    // gone — the engine still records the binding, but as a rename decision.
    clock += 5000;
    decisions.push(...engine.trackSpeaking("track-gone", true, clock));
    decisions.push(...engine.deviceSpeaking("devices/160", clock + 50));
    clock += 5000;
    decisions.push(...engine.trackSpeaking("track-gone", true, clock));
    decisions.push(...engine.deviceSpeaking("devices/160", clock + 50));

    expect(decisions).toMatchObject([
      { kind: "binding", outcome: "bound-late-rename", trackId: "track-gone", deviceId: "devices/160" },
    ]);
    expect(engine.bindings().get("track-gone")).toBe("devices/160");
  });

  it("exposes the bindings it has decided", () => {
    confirm("track-a", "devices/160");
    expect([...engine.bindings()]).toEqual([["track-a", "devices/160"]]);
  });
});

// ── Local-participant exclusion (journal #158/#164/#172) ────────────────────

describe("MeetIdentityEngine local-participant exclusion", () => {
  let clock: number;
  let presence: FakePresence;
  let engine: MeetIdentityEngine;
  let decisions: MeetIdentityDecision[];

  beforeEach(() => {
    clock = 100_000;
    presence = new FakePresence();
    engine = new MeetIdentityEngine(presence);
    decisions = [];
  });

  function turn(trackId: string, deviceId: string): void {
    clock += 5000;
    presence.seen(trackId);
    decisions.push(...engine.trackSpeaking(trackId, true, clock));
    decisions.push(...engine.deviceSpeaking(deviceId, clock + 50));
  }

  it("latches the local device once and reports it", () => {
    expect(engine.localDevice).toBeUndefined();
    decisions.push(...engine.rosterObserved([], "devices/107", clock));
    expect(engine.localDevice).toBe("devices/107");
    expect(decisions).toEqual([{ kind: "local-resolved", t: clock, deviceId: "devices/107" }]);
    // Latched — a repeat observation (even of a different id) decides nothing.
    expect(engine.rosterObserved([], "devices/107", clock + 1)).toEqual([]);
    expect(engine.rosterObserved([], "devices/999", clock + 2)).toEqual([]);
    expect(engine.localDevice).toBe("devices/107");
  });

  it("never binds a remote track to the local device, however many turns confirm", () => {
    // The journal #172 failure: the user backchannels over the remote's turn,
    // their ring burst lands in the remote track's window, and the pairing
    // confirms — titling the remote's whole call with the local user's name.
    engine.rosterObserved([], "devices/107", clock);

    for (let i = 0; i < 6; i++) turn("track-remote", "devices/107");

    expect(decisions).toEqual([]);
  });

  it("still binds the REMOTE device on the same track", () => {
    engine.rosterObserved([], "devices/107", clock);

    for (let i = 0; i < CONFIRM_THRESHOLD; i++) turn("track-remote", "devices/108");

    expect(decisions).toMatchObject([
      { kind: "binding", outcome: "bound", trackId: "track-remote", deviceId: "devices/108" },
    ]);
  });

  it("excludes nobody while the local device is unestablished — degrades to pre-fix behaviour, not to silence", () => {
    // A non-English UI never resolves the "(You)" marker. Identity must still
    // work; it is only the self-exclusion guarantee that is lost.
    for (let i = 0; i < CONFIRM_THRESHOLD; i++) turn("track-remote", "devices/108");

    expect(decisions).toMatchObject([
      { kind: "binding", outcome: "bound", trackId: "track-remote", deviceId: "devices/108" },
    ]);
  });

  it("ignores the local device's collections mic-open edge too", () => {
    engine.rosterObserved([], "devices/107", clock);

    for (let i = 0; i < 6; i++) {
      clock += 5000;
      presence.seen("track-remote");
      decisions.push(...engine.trackUnmuted("track-remote", clock));
      decisions.push(...engine.collectionsEdge("devices/107", true, clock));
    }

    expect(decisions).toEqual([]);
  });

  it("ignores mic-closed collections edges entirely", () => {
    for (let i = 0; i < 6; i++) {
      clock += 5000;
      presence.seen("track-remote");
      decisions.push(...engine.trackUnmuted("track-remote", clock));
      decisions.push(...engine.collectionsEdge("devices/108", false, clock));
    }
    expect(decisions).toEqual([]);
  });

  it("refuses at the threshold a pairing whose device onsets predate the local-device latch (belt and braces)", () => {
    // The onset filters drop the local device's evidence at the door, but a
    // pairing can confirm against device onsets recorded BEFORE the "(You)"
    // marker was first read. The final check refuses it with its own outcome.
    presence.seen("track-remote");
    // Turn 1, pre-latch, device onset first so it pairs when the audio lands.
    clock += 5000;
    decisions.push(...engine.deviceSpeaking("devices/107", clock));
    decisions.push(...engine.trackSpeaking("track-remote", true, clock + 50));
    // Turn 2's device onset also lands pre-latch and sits pending…
    clock += 5000;
    decisions.push(...engine.deviceSpeaking("devices/107", clock));
    // …then the marker resolves…
    decisions.push(...engine.rosterObserved([], "devices/107", clock + 10));
    // …and the audio onset completes the second confirming pair.
    decisions.push(...engine.trackSpeaking("track-remote", true, clock + 50));

    expect(decisions).toMatchObject([
      { kind: "local-resolved", deviceId: "devices/107" },
      { kind: "binding", outcome: "refused-local-device", trackId: "track-remote", deviceId: "devices/107" },
    ]);
    expect(engine.bindings().size).toBe(0);
  });
});

// ── Roster observations (issue #23) ─────────────────────────────────────────

describe("rosterDelta", () => {
  it("emits every (id → name) pair on first sight and records them as emitted", () => {
    const names = new Map([
      ["spaces/s/devices/445", "Tom Elliot"],
      ["spaces/s/devices/446", "Tom E"],
    ]);
    const emitted = new Map<string, string>();

    const fresh = rosterDelta(names, emitted);

    expect(fresh).toEqual([
      { participantId: "spaces/s/devices/445", displayName: "Tom Elliot" },
      { participantId: "spaces/s/devices/446", displayName: "Tom E" },
    ]);
    // Recorded, so a second identical scan is a no-op.
    expect(rosterDelta(names, emitted)).toEqual([]);
  });

  it("re-emits only when a name changes (Meet swaps a placeholder for the real one)", () => {
    const emitted = new Map<string, string>();
    rosterDelta(new Map([["spaces/s/devices/445", "Guest"]]), emitted);

    const fresh = rosterDelta(new Map([["spaces/s/devices/445", "Tom Elliot"]]), emitted);

    expect(fresh).toEqual([{ participantId: "spaces/s/devices/445", displayName: "Tom Elliot" }]);
    expect(emitted.get("spaces/s/devices/445")).toBe("Tom Elliot");
  });
});

describe("MeetIdentityEngine.rosterObserved", () => {
  let engine: MeetIdentityEngine;

  beforeEach(() => {
    engine = new MeetIdentityEngine({ hasTrack: () => true, isTrackLive: () => true });
  });

  it("decides a roster delta on first sight, and nothing on an identical re-scan", () => {
    const named = [
      { deviceId: "spaces/s/devices/445", displayName: "Priya Raman" },
      { deviceId: "spaces/s/devices/446", displayName: "Marcus Webb" },
    ];

    expect(engine.rosterObserved(named, undefined, 1000)).toMatchObject([
      { kind: "no-self-marker", namedCount: 2 },
      {
        kind: "roster",
        t: 1000,
        entries: [
          { participantId: "spaces/s/devices/445", displayName: "Priya Raman" },
          { participantId: "spaces/s/devices/446", displayName: "Marcus Webb" },
        ],
      },
    ]);
    // A second identical scan decides nothing (and never re-warns).
    expect(engine.rosterObserved(named, undefined, 4000)).toEqual([]);
  });

  it("marks the local participant's row when the marker resolved first", () => {
    engine.rosterObserved([], "spaces/s/devices/107", 1000);

    const decisions = engine.rosterObserved(
      [
        { deviceId: "spaces/s/devices/107", displayName: "Tom Elliot" },
        { deviceId: "spaces/s/devices/108", displayName: "Priya Raman" },
      ],
      undefined,
      4000,
    );

    expect(decisions).toEqual([
      {
        kind: "roster",
        t: 4000,
        entries: [
          { participantId: "spaces/s/devices/107", displayName: "Tom Elliot", isLocal: true },
          { participantId: "spaces/s/devices/108", displayName: "Priya Raman" },
        ],
      },
    ]);
  });

  it("re-sends the local device's row when the marker resolves after its name already went out", () => {
    engine.rosterObserved([{ deviceId: "spaces/s/devices/107", displayName: "Tom Elliot" }], undefined, 1000);

    const decisions = engine.rosterObserved([], "spaces/s/devices/107", 4000);

    // Without the re-send the daemon never learns which roster row is the user.
    expect(decisions).toEqual([
      { kind: "local-resolved", t: 4000, deviceId: "spaces/s/devices/107" },
      {
        kind: "roster",
        t: 4000,
        entries: [{ participantId: "spaces/s/devices/107", displayName: "Tom Elliot", isLocal: true }],
      },
    ]);
  });

  it("stays silent about a missing marker while the roster is still empty", () => {
    // An empty tile set early in a call is normal and means nothing.
    expect(engine.rosterObserved([], undefined, 1000)).toEqual([]);
  });

  it("records names from single-tile correlations for later deltas and displayName", () => {
    engine.nameObserved("spaces/s/devices/445", "Priya Raman");
    expect(engine.displayName("spaces/s/devices/445")).toBe("Priya Raman");
    // The next roster observation carries it out, even when the scan itself
    // resolved nothing new.
    expect(engine.rosterObserved([], "spaces/s/devices/107", 4000)).toMatchObject([
      { kind: "local-resolved" },
      { kind: "roster", entries: [{ participantId: "spaces/s/devices/445", displayName: "Priya Raman" }] },
    ]);
  });
});
