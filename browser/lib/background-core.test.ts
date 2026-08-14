import { describe, expect, it } from "vitest";
import {
  composeBadgeState,
  emptyBackgroundPortState,
  reducePortDisconnect,
  reducePortMessage,
  reduceStreamOpened,
  runBackgroundEffects,
  type BackgroundEffect,
  type BackgroundPortState,
  type BackgroundSinks,
} from "./background-core";
import { syntheticParticipant, type PortMessage } from "./protocol";
import { SessionTracker, type SessionControl } from "./session-tracker";
import type { AttendeeUpsert, SessionWire } from "./protocol";

// Tier-0 tests for the background's pure wiring core (attribution refactor
// R8): the pcm-port message switch as a reducer over the background's port
// state, with every collaborator call (SessionTracker, KeepaliveTracker,
// EarsSocket) expressed as an effect a thin chrome shell executes.

const b64 = (bytes: number[]): string => btoa(String.fromCharCode(...bytes));

const pcmMsg = (participantId: string, seq = 0, bytes = [1, 2, 3]): PortMessage => ({
  type: "pcm",
  participantId,
  platform: "meet",
  b64: b64(bytes),
  seq,
  sentAt: 1000 + seq,
});

/** Fold messages on one port, collecting every effect. */
function reduceAll(
  msgs: PortMessage[],
  portId = "pcm-0",
  state: BackgroundPortState = emptyBackgroundPortState(),
): { state: BackgroundPortState; effects: BackgroundEffect[] } {
  const effects: BackgroundEffect[] = [];
  for (const msg of msgs) {
    const r = reducePortMessage(state, portId, msg);
    state = r.state;
    effects.push(...r.effects);
  }
  return { state, effects };
}

describe("reducePortMessage", () => {
  it("routes a joined declaration to the session layer", () => {
    const { effects } = reduceAll([
      { type: "joined", participant: syntheticParticipant("t1"), platform: "meet" },
    ]);
    expect(effects).toEqual([
      {
        kind: "sessions.participantJoined",
        portId: "pcm-0",
        platform: "meet",
        participant: { kind: "synthetic", id: "t1" },
      },
    ]);
  });

  it("routes roster names to the session layer", () => {
    const entries = [{ participantId: "dev-1", displayName: "Ada", isLocal: true }];
    const { effects } = reduceAll([{ type: "roster", platform: "meet", entries }]);
    expect(effects).toEqual([
      { kind: "sessions.rosterUpdate", portId: "pcm-0", platform: "meet", entries },
    ]);
  });

  it("routes an identity link, omitting displayName when absent", () => {
    const { effects } = reduceAll([
      { type: "identified", platform: "meet", participantId: "dev-1", captureId: "t1", displayName: "Ada" },
      { type: "identified", platform: "meet", participantId: "dev-2", captureId: "t2" },
    ]);
    expect(effects[0]).toEqual({
      kind: "sessions.participantIdentified",
      portId: "pcm-0",
      platform: "meet",
      participantId: "dev-1",
      captureId: "t1",
      displayName: "Ada",
    });
    expect(effects[1]).not.toHaveProperty("displayName");
  });

  it("left releases the keepalive, closes the stream, stamps the roster, and forgets the port", () => {
    const seeded = reduceAll([pcmMsg("t1")]);
    const r = reducePortMessage(seeded.state, "pcm-0", { type: "left", participantId: "t1" });
    expect(r.effects).toEqual([
      { kind: "keepalive.participantLeft", portId: "pcm-0", participantId: "t1" },
      { kind: "ingest.closeStream", participantId: "t1" },
      { kind: "sessions.participantLeft", portId: "pcm-0", participantId: "t1" },
    ]);
    expect(r.state.participantPorts.has("t1")).toBe(false);
  });

  it("capture-failed logs loudly and reports to the daemon, but closes nothing", () => {
    const seeded = reduceAll([pcmMsg("t1")]);
    const r = reducePortMessage(seeded.state, "pcm-0", {
      type: "capture-failed",
      participantId: "t1",
      platform: "meet",
      reason: "decoder gave up",
    });
    expect(r.effects).toEqual([
      {
        kind: "console",
        level: "error",
        text: "[ears][bg] capture failed for t1 (meet): decoder gave up",
      },
      {
        kind: "ingest.sendCaptureFailed",
        portId: "pcm-0",
        participantId: "t1",
        platform: "meet",
        reason: "decoder gave up",
      },
    ]);
    // The participant stays (no stream close) — a later renegotiated track
    // re-adopts and resumes capture on its own.
    expect(r.state.participantPorts.get("t1")).toBe("pcm-0");
  });

  it("routes the meeting lifecycle to the session layer", () => {
    const { effects } = reduceAll([
      { type: "meeting-started", platform: "meet", externalMeetingId: "abc", title: "Standup" },
      { type: "meeting-renamed", platform: "meet", externalMeetingId: "abc", title: "Retro" },
      { type: "meeting-ended", platform: "meet", externalMeetingId: "abc" },
    ]);
    expect(effects).toEqual([
      {
        kind: "sessions.meetingStarted",
        portId: "pcm-0",
        platform: "meet",
        externalMeetingId: "abc",
        title: "Standup",
      },
      { kind: "sessions.meetingRenamed", externalMeetingId: "abc", title: "Retro" },
      { kind: "sessions.meetingEnded", externalMeetingId: "abc" },
    ]);
  });

  it("ships attribution batches with the port that carried them", () => {
    const { effects } = reduceAll([
      { type: "attribution", platform: "meet", events: ['{"ev":1}'] },
    ]);
    expect(effects).toEqual([
      { kind: "ingest.sendAttribution", portId: "pcm-0", platform: "meet", events: ['{"ev":1}'] },
    ]);
  });

  it("pcm arms the keepalive, decodes the frame, and learns the participant's port", () => {
    const { state, effects } = reduceAll([pcmMsg("t1", 7, [0, 255, 128])]);
    expect(effects[0]).toEqual({
      kind: "keepalive.participantActive",
      portId: "pcm-0",
      participantId: "t1",
      platform: "meet",
    });
    expect(effects[1]).toMatchObject({
      kind: "ingest.sendPcm",
      portId: "pcm-0",
      participantId: "t1",
      platform: "meet",
      seq: 7,
      sentAt: 1007,
    });
    const sent = effects[1] as { pcm: Uint8Array };
    expect([...sent.pcm]).toEqual([0, 255, 128]);
    expect(state.participantPorts.get("t1")).toBe("pcm-0");
    expect(state.frameCounts.get("t1")).toBe(1);
  });

  it("logs a cadence line every 50th forwarded frame", () => {
    const frames = Array.from({ length: 50 }, (_, i) => pcmMsg("t1", i));
    const { effects } = reduceAll(frames);
    const logs = effects.filter((e) => e.kind === "console");
    expect(logs).toEqual([
      { kind: "console", level: "debug", text: "[ears][bg] forwarded 50 frames for t1" },
    ]);
  });

  it("never mutates the state it was handed", () => {
    const before = emptyBackgroundPortState();
    reducePortMessage(before, "pcm-0", pcmMsg("t1"));
    expect(before.participantPorts.size).toBe(0);
    expect(before.frameCounts.size).toBe(0);
  });
});

describe("reducePortDisconnect", () => {
  it("closes orphaned streams, ends the port's sessions, and logs the toll", () => {
    const seeded = reduceAll([pcmMsg("t1"), pcmMsg("t2")]);
    const r = reducePortDisconnect(seeded.state, "pcm-0", ["t1", "t2"]);
    expect(r.effects).toEqual([
      { kind: "ingest.closeStream", participantId: "t1" },
      { kind: "ingest.closeStream", participantId: "t2" },
      { kind: "sessions.portDisconnected", portId: "pcm-0" },
      {
        kind: "console",
        level: "debug",
        text: "[ears][bg] pcm port disconnected (pcm-0) — closed 2 orphaned stream(s)",
      },
    ]);
    expect(r.state.participantPorts.size).toBe(0);
  });

  it("with nothing orphaned it only ends the sessions", () => {
    const r = reducePortDisconnect(emptyBackgroundPortState(), "pcm-3", []);
    expect(r.effects).toEqual([
      { kind: "sessions.portDisconnected", portId: "pcm-3" },
      { kind: "console", level: "debug", text: "[ears][bg] pcm port disconnected (pcm-3)" },
    ]);
  });
});

describe("reduceStreamOpened", () => {
  it("routes a stream-open confirmation to the tab the PCM arrived on", () => {
    const seeded = reduceAll([pcmMsg("t1")], "pcm-4");
    expect(reduceStreamOpened(seeded.state, "t1", "meet")).toEqual([
      { kind: "sessions.streamOpened", portId: "pcm-4", platform: "meet", participantId: "t1" },
    ]);
  });

  it("drops the confirmation when no port ever carried this participant", () => {
    expect(reduceStreamOpened(emptyBackgroundPortState(), "ghost", "meet")).toEqual([]);
  });

  it("follows the participant to the latest port", () => {
    let state = reduceAll([pcmMsg("t1")], "pcm-0").state;
    state = reduceAll([pcmMsg("t1")], "pcm-1", state).state;
    expect(reduceStreamOpened(state, "t1", "meet")[0]).toMatchObject({ portId: "pcm-1" });
  });
});

describe("composeBadgeState", () => {
  it("lets a transport problem win outright", () => {
    expect(composeBadgeState("disconnected", "recording")).toBe("disconnected");
    expect(composeBadgeState("connecting", "paused")).toBe("connecting");
  });

  it("shows plain connected while no session is live", () => {
    expect(composeBadgeState("connected", "idle")).toBe("connected");
  });

  it("passes the session state through otherwise", () => {
    expect(composeBadgeState("connected", "recording")).toBe("recording");
    expect(composeBadgeState("connected", "paused")).toBe("paused");
    expect(composeBadgeState("connected", "transcribing")).toBe("transcribing");
  });
});

// ── Effect execution ─────────────────────────────────────────────────────────

type Call = { fn: string; args: unknown[] };

function recordingSinks(externalId?: string): { calls: Call[]; sinks: BackgroundSinks } {
  const calls: Call[] = [];
  const rec =
    (fn: string) =>
    (...args: unknown[]): void => {
      calls.push({ fn, args });
    };
  const sinks: BackgroundSinks = {
    sessions: {
      participantJoined: rec("sessions.participantJoined"),
      rosterUpdate: rec("sessions.rosterUpdate"),
      participantIdentified: rec("sessions.participantIdentified"),
      participantLeft: rec("sessions.participantLeft"),
      meetingStarted: rec("sessions.meetingStarted"),
      meetingRenamed: rec("sessions.meetingRenamed"),
      meetingEnded: rec("sessions.meetingEnded"),
      streamOpened: rec("sessions.streamOpened"),
      portDisconnected: rec("sessions.portDisconnected"),
      externalIdFor: (portId, platform) => {
        calls.push({ fn: "sessions.externalIdFor", args: [portId, platform] });
        return externalId;
      },
    },
    keepalive: {
      participantActive: rec("keepalive.participantActive"),
      participantLeft: rec("keepalive.participantLeft"),
    },
    ingest: {
      closeStream: rec("ingest.closeStream"),
      sendPcm: rec("ingest.sendPcm"),
      sendAttribution: rec("ingest.sendAttribution"),
      sendCaptureFailed: rec("ingest.sendCaptureFailed"),
    },
  };
  return { calls, sinks };
}

describe("runBackgroundEffects", () => {
  it("resolves the session tag at send time for pcm and attribution", () => {
    const { calls, sinks } = recordingSinks("abc-defg-hij");
    const seeded = reduceAll([
      pcmMsg("t1", 0, [9]),
      { type: "attribution", platform: "meet", events: ["{}"] },
    ]);
    runBackgroundEffects(seeded.effects, sinks);
    const sendPcm = calls.find((c) => c.fn === "ingest.sendPcm");
    expect(sendPcm?.args[0]).toBe("t1");
    expect(sendPcm?.args[3]).toBe("abc-defg-hij"); // externalIdFor(portId, platform)
    expect(sendPcm?.args[4]).toEqual({ seq: 0, sentAt: 1000 });
    const sendAttr = calls.find((c) => c.fn === "ingest.sendAttribution");
    expect(sendAttr?.args).toEqual([["{}"], "meet", "abc-defg-hij"]);
  });

  it("resolves the session tag at send time for a capture-failed report", () => {
    const { calls, sinks } = recordingSinks("abc-defg-hij");
    const seeded = reduceAll([
      pcmMsg("t1"),
      { type: "capture-failed", participantId: "t1", platform: "meet", reason: "decoder gave up" },
    ]);
    runBackgroundEffects(seeded.effects, sinks);
    const report = calls.find((c) => c.fn === "ingest.sendCaptureFailed");
    expect(report?.args).toEqual(["t1", "meet", "decoder gave up", "abc-defg-hij"]);
  });

  it("dispatches each effect to its collaborator once, in order", () => {
    const { calls, sinks } = recordingSinks();
    const seeded = reduceAll([
      { type: "joined", participant: syntheticParticipant("t1"), platform: "meet" },
      { type: "left", participantId: "t1" },
    ]);
    runBackgroundEffects(seeded.effects, sinks);
    expect(calls.map((c) => c.fn)).toEqual([
      "sessions.participantJoined",
      "keepalive.participantLeft",
      "ingest.closeStream",
      "sessions.participantLeft",
    ]);
  });
});

// ── Session state transitions through the real SessionTracker ────────────────

function sessionWire(overrides: Partial<SessionWire> = {}): SessionWire {
  return {
    id: "s-1",
    identity: { platform: "meet", external_id: "abc" },
    title: "meet abc",
    state: "active",
    started: "2026-08-13T10:00:00.000Z",
    intervals: [{ start: "2026-08-13T10:00:00.000Z", end: null }],
    attendees: [],
    sources: [],
    trigger: "browser-extension",
    rev: 1,
    ...overrides,
  };
}

class FakeControl implements SessionControl {
  calls: Array<{ verb: string; [k: string]: unknown }> = [];
  sessionStart(platform: string, externalMeetingId: string, title?: string): Promise<SessionWire> {
    this.calls.push({ verb: "start", platform, externalMeetingId, ...(title ? { title } : {}) });
    return Promise.resolve(sessionWire());
  }
  sessionEnd(session: string): Promise<SessionWire> {
    this.calls.push({ verb: "end", session });
    return Promise.resolve(sessionWire({ state: "ended" }));
  }
  sessionRename(session: string, title: string): Promise<SessionWire> {
    this.calls.push({ verb: "rename", session, title });
    return Promise.resolve(sessionWire({ title }));
  }
  sessionPause(session: string): Promise<SessionWire> {
    this.calls.push({ verb: "pause", session });
    return Promise.resolve(sessionWire({ state: "paused" }));
  }
  sessionResume(session: string): Promise<SessionWire> {
    this.calls.push({ verb: "resume", session });
    return Promise.resolve(sessionWire());
  }
  sessionAttendee(session: string, attendee: AttendeeUpsert): Promise<SessionWire> {
    this.calls.push({ verb: "attendee", session, attendee });
    return Promise.resolve(sessionWire());
  }
}

const flush = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

describe("session transitions driven through the reducer", () => {
  it("declares, populates, and ends a session from port traffic alone", async () => {
    const control = new FakeControl();
    const sessions = new SessionTracker(control, () => {}, () => "2026-08-13T10:05:00.000Z");
    const { sinks } = recordingSinks();
    const wired: BackgroundSinks = { ...sinks, sessions };
    let state = emptyBackgroundPortState();
    const feed = (msg: PortMessage): void => {
      const r = reducePortMessage(state, "pcm-0", msg);
      state = r.state;
      runBackgroundEffects(r.effects, wired);
    };

    feed({ type: "meeting-started", platform: "meet", externalMeetingId: "abc" });
    await flush();
    feed({ type: "joined", participant: syntheticParticipant("t1"), platform: "meet" });
    feed({ type: "left", participantId: "t1" });
    await flush();

    const disconnect = reducePortDisconnect(state, "pcm-0", []);
    runBackgroundEffects(disconnect.effects, wired);
    await flush();

    expect(control.calls).toEqual([
      { verb: "start", platform: "meet", externalMeetingId: "abc" },
      { verb: "attendee", session: "s-1", attendee: { id: "t1", origin: "synthetic" } },
      { verb: "attendee", session: "s-1", attendee: { id: "t1", left: "2026-08-13T10:05:00.000Z" } },
      { verb: "end", session: "s-1" },
    ]);
  });
});
