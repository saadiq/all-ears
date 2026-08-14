import { describe, expect, it } from "vitest";
import type { LogEntry } from "./debug-log";
import type { PerfRecord } from "./perf";
import { syntheticParticipant, type MainMessage, type Platform, type PortMessage } from "./protocol";
import { emptyRelayState, reduceRelay, type RelayEffect, type RelayState } from "./relay-core";

// Tier-0 tests for the relay's pure core (attribution refactor R8): the
// content-script message switch as a reducer over RelayState. Each test
// asserts the full effect plan for a message — what gets posted on the pcm
// port, what gets counted, what the durable relay state remembers for the
// worker-respawn replay.

const joined = (id: string, platform: Platform = "meet", generation = 1): MainMessage => ({
  kind: "participant-joined",
  platform,
  participant: syntheticParticipant(id),
  generation,
});

const pcm = (
  participantId: string,
  seq = 0,
  samples = new Int16Array([1, -2, 3]),
  sentAt = 1000,
): MainMessage => ({ kind: "pcm", participantId, generation: 1, samples, seq, sentAt });

/** Fold a message sequence over a fresh state, collecting every effect. */
function reduceAll(
  msgs: MainMessage[],
  opts?: Parameters<typeof reduceRelay>[2],
): { state: RelayState; effects: RelayEffect[] } {
  let state = emptyRelayState();
  const effects: RelayEffect[] = [];
  for (const msg of msgs) {
    const r = reduceRelay(state, msg, opts);
    state = r.state;
    effects.push(...r.effects);
  }
  return { state, effects };
}

function posts(effects: RelayEffect[]): PortMessage[] {
  return effects.filter((e) => e.kind === "post").map((e) => (e as { msg: PortMessage }).msg);
}

describe("participant lifecycle", () => {
  it("joined forwards the declaration and learns the platform", () => {
    const { state, effects } = reduceAll([joined("t1", "zoom")]);
    expect(posts(effects)).toEqual([
      { type: "joined", participant: { kind: "synthetic", id: "t1" }, platform: "zoom" },
    ]);
    expect(effects.some((e) => e.kind === "tag-platform" && e.platform === "zoom")).toBe(true);
    expect(state.participants.get("t1")).toEqual({ platform: "zoom", kind: "synthetic" });
  });

  it("never mutates the state it was handed", () => {
    const before = emptyRelayState();
    reduceRelay(before, joined("t1"));
    expect(before.participants.size).toBe(0);
    const r = reduceRelay(before, {
      kind: "meeting-started",
      platform: "meet",
      externalMeetingId: "abc",
    });
    expect(before.liveMeeting).toBeNull();
    expect(r.state.liveMeeting).toEqual({ platform: "meet", externalMeetingId: "abc" });
  });

  it("left forwards and forgets the participant", () => {
    const { state, effects } = reduceAll([
      joined("t1"),
      { kind: "participant-left", participantId: "t1", generation: 1 },
    ]);
    expect(posts(effects)[1]).toEqual({ type: "left", participantId: "t1" });
    expect(state.participants.size).toBe(0);
  });
});

describe("pcm", () => {
  it("drops frames from a participant with no join, counting them", () => {
    const state = emptyRelayState();
    const r = reduceRelay(state, pcm("ghost"));
    expect(posts(r.effects)).toEqual([]);
    expect(r.effects).toContainEqual({ kind: "count-dropped-no-identity" });
    // Nothing changed: the same state object comes back (hot-path cheap).
    expect(r.state).toBe(state);
  });

  it("encodes frames to base64 and stamps platform, seq and sentAt", () => {
    const samples = new Int16Array([258, -2]);
    const { effects } = reduceAll([joined("t1", "meet"), pcm("t1", 7, samples, 123.5)]);
    const sent = posts(effects)[1];
    expect(sent).toMatchObject({ type: "pcm", participantId: "t1", platform: "meet", seq: 7, sentAt: 123.5 });
    const b64 = (sent as { b64: string }).b64;
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    expect([...bytes]).toEqual([...new Uint8Array(samples.buffer)]);
    // The port drop counter belongs to pcm posts only.
    const post = effects.find((e) => e.kind === "post" && e.msg.type === "pcm");
    expect(post).toMatchObject({ countDrop: true });
    expect(effects).toContainEqual({ kind: "count-frame", bytes: samples.byteLength });
  });

  it("preserves arrival order across participants", () => {
    const { effects } = reduceAll([
      joined("t1"),
      joined("t2"),
      pcm("t1", 0),
      pcm("t2", 0),
      pcm("t1", 1),
    ]);
    const frames = posts(effects)
      .filter((m) => m.type === "pcm")
      .map((m) => `${(m as { participantId: string }).participantId}#${(m as { seq: number }).seq}`);
    expect(frames).toEqual(["t1#0", "t2#0", "t1#1"]);
  });

  it("times the encode only when detail is on", () => {
    let t = 0;
    const now = () => (t += 2.5);
    const detailed = reduceAll([joined("t1"), pcm("t1")], { detail: true, now });
    const frame = detailed.effects.find((e) => e.kind === "count-frame");
    expect(frame).toMatchObject({ encodeMs: 2.5 });
    const plain = reduceAll([joined("t1"), pcm("t1")], { detail: false, now });
    const plainFrame = plain.effects.find((e) => e.kind === "count-frame");
    expect(plainFrame).not.toHaveProperty("encodeMs");
  });

  it("drops frames again after the participant left", () => {
    const { effects } = reduceAll([
      joined("t1"),
      { kind: "participant-left", participantId: "t1", generation: 1 },
      pcm("t1"),
    ]);
    expect(posts(effects).filter((m) => m.type === "pcm")).toEqual([]);
  });
});

describe("roster", () => {
  const roster = (entries: MainMessage extends never ? never : { participantId: string; displayName: string; isLocal?: boolean }[]): MainMessage => ({
    kind: "participant-roster",
    platform: "meet",
    entries,
  });

  it("forwards new names and accumulates them", () => {
    const { state, effects } = reduceAll([roster([{ participantId: "p1", displayName: "Ada" }])]);
    expect(posts(effects)).toEqual([
      { type: "roster", platform: "meet", entries: [{ participantId: "p1", displayName: "Ada" }] },
    ]);
    expect(state.roster.get("p1")).toMatchObject({ platform: "meet", displayName: "Ada" });
  });

  it("stays silent on a repeat of a known name", () => {
    const { effects } = reduceAll([
      roster([{ participantId: "p1", displayName: "Ada" }]),
      roster([{ participantId: "p1", displayName: "Ada" }]),
    ]);
    expect(posts(effects)).toHaveLength(1);
  });

  it("treats a changed name as news", () => {
    const { effects } = reduceAll([
      roster([{ participantId: "p1", displayName: "Ada" }]),
      roster([{ participantId: "p1", displayName: "Ada L." }]),
    ]);
    expect(posts(effects)).toHaveLength(2);
  });

  it("treats a late isLocal marker as news and keeps it sticky", () => {
    const { state, effects } = reduceAll([
      roster([{ participantId: "p1", displayName: "Ada" }]),
      roster([{ participantId: "p1", displayName: "Ada", isLocal: true }]),
      roster([{ participantId: "p1", displayName: "Ada" }]),
    ]);
    expect(posts(effects)).toHaveLength(2); // name, then the isLocal upgrade — third is a repeat
    expect(state.roster.get("p1")?.isLocal).toBe(true); // an entry without the flag never clears it
  });
});

describe("identity links", () => {
  it("forwards a link and keys it on the capture id", () => {
    const { state, effects } = reduceAll([
      {
        kind: "participant-identified",
        platform: "meet",
        participantId: "spaces/x/devices/1",
        captureId: "t1",
        displayName: "Ada",
      },
    ]);
    expect(posts(effects)).toEqual([
      {
        type: "identified",
        platform: "meet",
        participantId: "spaces/x/devices/1",
        captureId: "t1",
        displayName: "Ada",
      },
    ]);
    expect(state.identities.get("t1")).toEqual({
      platform: "meet",
      participantId: "spaces/x/devices/1",
      displayName: "Ada",
    });
  });

  it("overwrites on a repeat confirmation for the same capture id", () => {
    const { state } = reduceAll([
      { kind: "participant-identified", platform: "meet", participantId: "dev-1", captureId: "t1" },
      { kind: "participant-identified", platform: "meet", participantId: "dev-2", captureId: "t1" },
    ]);
    expect(state.identities.size).toBe(1);
    expect(state.identities.get("t1")?.participantId).toBe("dev-2");
  });

  it("omits displayName when the link has none", () => {
    const { effects } = reduceAll([
      { kind: "participant-identified", platform: "meet", participantId: "dev-1", captureId: "t1" },
    ]);
    expect(posts(effects)[0]).not.toHaveProperty("displayName");
  });
});

describe("meeting lifecycle", () => {
  it("started records the live meeting and forwards it", () => {
    const { state, effects } = reduceAll([
      { kind: "meeting-started", platform: "meet", externalMeetingId: "abc", title: "Standup" },
    ]);
    expect(posts(effects)).toEqual([
      { type: "meeting-started", platform: "meet", externalMeetingId: "abc", title: "Standup" },
    ]);
    expect(state.liveMeeting).toEqual({ platform: "meet", externalMeetingId: "abc", title: "Standup" });
  });

  it("started without a title carries none", () => {
    const { effects } = reduceAll([
      { kind: "meeting-started", platform: "meet", externalMeetingId: "abc" },
    ]);
    expect(posts(effects)[0]).not.toHaveProperty("title");
  });

  it("renamed folds the title into the live meeting when the id matches", () => {
    const { state, effects } = reduceAll([
      { kind: "meeting-started", platform: "meet", externalMeetingId: "abc" },
      { kind: "meeting-renamed", platform: "meet", externalMeetingId: "abc", title: "Standup" },
    ]);
    expect(state.liveMeeting?.title).toBe("Standup");
    expect(posts(effects)[1]).toEqual({
      type: "meeting-renamed",
      platform: "meet",
      externalMeetingId: "abc",
      title: "Standup",
    });
  });

  it("renamed for a different meeting still forwards but folds nothing", () => {
    const { state } = reduceAll([
      { kind: "meeting-started", platform: "meet", externalMeetingId: "abc" },
      { kind: "meeting-renamed", platform: "meet", externalMeetingId: "other", title: "Standup" },
    ]);
    expect(state.liveMeeting?.title).toBeUndefined();
  });

  it("ended clears the live meeting and forwards", () => {
    const { state, effects } = reduceAll([
      { kind: "meeting-started", platform: "meet", externalMeetingId: "abc" },
      { kind: "meeting-ended", platform: "meet", externalMeetingId: "abc" },
    ]);
    expect(state.liveMeeting).toBeNull();
    expect(posts(effects)[1]).toEqual({ type: "meeting-ended", platform: "meet", externalMeetingId: "abc" });
  });
});

describe("pass-throughs", () => {
  it("attribution batches pass through without touching state", () => {
    const state = emptyRelayState();
    const r = reduceRelay(state, { kind: "attribution", platform: "meet", events: ['{"k":1}', '{"k":2}'] });
    expect(posts(r.effects)).toEqual([
      { type: "attribution", platform: "meet", events: ['{"k":1}', '{"k":2}'] },
    ]);
    expect(r.state).toBe(state);
  });

  it("an empty attribution batch posts nothing", () => {
    const r = reduceRelay(emptyRelayState(), { kind: "attribution", platform: "meet", events: [] });
    expect(r.effects).toEqual([]);
  });

  it("log batches forward to the background store", () => {
    const entries: LogEntry[] = [{ t: 1, ctx: "hook", level: "debug", msg: "x" }];
    const r = reduceRelay(emptyRelayState(), { kind: "log", entries });
    expect(r.effects).toEqual([{ kind: "forward-log", entries }]);
    expect(reduceRelay(emptyRelayState(), { kind: "log", entries: [] }).effects).toEqual([]);
  });

  it("perf batches forward to the background store", () => {
    const records: PerfRecord[] = [{ t: 1, ctx: "hook", metric: "capture", fields: { n: 1 } }];
    const r = reduceRelay(emptyRelayState(), { kind: "perf", records });
    expect(r.effects).toEqual([{ kind: "forward-perf", records }]);
    expect(reduceRelay(emptyRelayState(), { kind: "perf", records: [] }).effects).toEqual([]);
  });

  it("status logs and forwards nothing", () => {
    const r = reduceRelay(emptyRelayState(), { kind: "status", text: "hi" });
    expect(posts(r.effects)).toEqual([]);
    expect(r.effects.some((e) => e.kind === "console")).toBe(true);
  });
});

describe("capture-failed", () => {
  it("forwards with the platform learned at join, keeping the roster", () => {
    const { state, effects } = reduceAll([
      joined("t1", "teams"),
      { kind: "capture-failed", participantId: "t1", generation: 1, reason: "decoder gave up" },
    ]);
    expect(posts(effects)[1]).toEqual({
      type: "capture-failed",
      participantId: "t1",
      platform: "teams",
      reason: "decoder gave up",
    });
    // Not a participant-left: the participant stays known.
    expect(state.participants.has("t1")).toBe(true);
  });

  it("warns but forwards nothing when no join was ever seen", () => {
    const r = reduceRelay(emptyRelayState(), {
      kind: "capture-failed",
      participantId: "ghost",
      generation: 1,
      reason: "x",
    });
    expect(posts(r.effects)).toEqual([]);
    expect(r.effects.some((e) => e.kind === "console" && e.level === "warn")).toBe(true);
  });
});
