import { describe, expect, it } from "vitest";
import { ReconnectingPort, type PortLike } from "./pcm-port";
import { syntheticParticipant, type MainMessage, type PortMessage } from "./protocol";
import {
  emptyRelayState,
  reduceRelay,
  respawnReplay,
  runRelayEffects,
  type RelaySinks,
  type RelayState,
} from "./relay-core";

// The worker-respawn replay (attribution refactor R8) — the guard against the
// stranded-session bug class (extension.md §Messaging): Chrome can evict the
// MV3 service worker mid-call, and the respawned worker holds none of the
// lifecycle facts it needs to attribute PCM or end the session when the tab
// goes away. The relay's durable RelayState is the copy those facts replay
// from; these tests pin exactly what a fresh port is taught, and in what
// order, before the message that triggered the reconnect.

function reduce(state: RelayState, ...msgs: MainMessage[]): RelayState {
  for (const msg of msgs) state = reduceRelay(state, msg).state;
  return state;
}

const midCallState = () =>
  reduce(
    emptyRelayState(),
    { kind: "meeting-started", platform: "meet", externalMeetingId: "abc-defg-hij" },
    { kind: "meeting-renamed", platform: "meet", externalMeetingId: "abc-defg-hij", title: "Standup" },
    { kind: "participant-joined", platform: "meet", participant: syntheticParticipant("t1"), generation: 1 },
    { kind: "participant-joined", platform: "meet", participant: syntheticParticipant("t2"), generation: 1 },
    {
      kind: "participant-roster",
      platform: "meet",
      entries: [
        { participantId: "dev-1", displayName: "Ada", isLocal: true },
        { participantId: "dev-2", displayName: "Grace" },
      ],
    },
    { kind: "participant-identified", platform: "meet", participantId: "dev-2", captureId: "t2", displayName: "Grace" },
  );

describe("respawnReplay", () => {
  it("replays meeting, joins, roster, then identity links, in that order", () => {
    const { messages, log } = respawnReplay(midCallState());
    expect(messages).toEqual([
      { type: "meeting-started", platform: "meet", externalMeetingId: "abc-defg-hij", title: "Standup" },
      { type: "joined", participant: { kind: "synthetic", id: "t1" }, platform: "meet" },
      { type: "joined", participant: { kind: "synthetic", id: "t2" }, platform: "meet" },
      {
        type: "roster",
        platform: "meet",
        entries: [
          { participantId: "dev-1", displayName: "Ada", isLocal: true },
          { participantId: "dev-2", displayName: "Grace" },
        ],
      },
      { type: "identified", platform: "meet", participantId: "dev-2", captureId: "t2", displayName: "Grace" },
    ]);
    expect(log).toBe(
      "[ears][relay] replayed to respawned worker: meeting=abc-defg-hij, " +
        "2 participant(s), 2 roster name(s), 1 identity link(s)",
    );
  });

  it("replays nothing for a tab that never saw a call", () => {
    const { messages, log } = respawnReplay(emptyRelayState());
    expect(messages).toEqual([]);
    expect(log).toContain("meeting=none");
  });

  it("does not resurrect an ended meeting or departed participants", () => {
    const state = reduce(
      midCallState(),
      { kind: "participant-left", participantId: "t1", generation: 1 },
      { kind: "meeting-ended", platform: "meet", externalMeetingId: "abc-defg-hij" },
    );
    const { messages } = respawnReplay(state);
    expect(messages.some((m) => m.type === "meeting-started")).toBe(false);
    const joins = messages.filter((m) => m.type === "joined");
    expect(joins).toEqual([{ type: "joined", participant: { kind: "synthetic", id: "t2" }, platform: "meet" }]);
  });

  it("never replays attribution batches — the in-page ring is the durable copy", () => {
    const state = reduce(midCallState(), {
      kind: "attribution",
      platform: "meet",
      events: ['{"ev":"admit"}'],
    });
    expect(respawnReplay(state).messages.some((m) => m.type === "attribution")).toBe(false);
  });

  it("replays the latest identity binding per capture id", () => {
    const state = reduce(
      midCallState(),
      { kind: "participant-identified", platform: "meet", participantId: "dev-1", captureId: "t2" },
    );
    const links = respawnReplay(state).messages.filter((m) => m.type === "identified");
    expect(links).toEqual([
      { type: "identified", platform: "meet", participantId: "dev-1", captureId: "t2" },
    ]);
  });
});

// ── Integration with ReconnectingPort: the stranded-session scenario ─────────

class FakePort implements PortLike {
  sent: PortMessage[] = [];
  private severed = false;
  private listeners: Array<() => void> = [];

  postMessage(msg: unknown): void {
    if (this.severed) throw new Error("port severed");
    this.sent.push(msg as PortMessage);
  }

  onDisconnect = {
    addListener: (cb: () => void): void => {
      this.listeners.push(cb);
    },
  };

  /** The worker died: posts start throwing (onDisconnect may lag behind). */
  sever(): void {
    this.severed = true;
  }
}

/** content.ts's wiring, minus the browser: reducer + effects + ReconnectingPort. */
function harness() {
  const ports: FakePort[] = [];
  let connectFails = false;
  let state = emptyRelayState();
  const port = new ReconnectingPort(
    () => {
      if (connectFails) throw new Error("extension context gone");
      const p = new FakePort();
      ports.push(p);
      return p;
    },
    (post) => {
      const { messages } = respawnReplay(state);
      for (const msg of messages) post(msg);
    },
  );
  const noop = { add: () => {}, observe: () => {} };
  const sinks: RelaySinks = {
    post: (msg) => port.post(msg),
    sendRuntimeMessage: () => {},
    tagPlatform: () => {},
    metrics: { encode: noop, frames: noop, bytes: noop, dropped: noop, unknownParticipant: noop },
  };
  const deliver = (msg: MainMessage): void => {
    const r = reduceRelay(state, msg);
    state = r.state;
    runRelayEffects(r.effects, sinks);
  };
  return {
    ports,
    deliver,
    killWorker: () => ports[ports.length - 1]!.sever(),
    killExtension: () => {
      ports[ports.length - 1]!.sever();
      connectFails = true;
    },
  };
}

const pcm = (participantId: string, seq: number): MainMessage => ({
  kind: "pcm",
  participantId,
  generation: 1,
  samples: new Int16Array([1]),
  seq,
  sentAt: 1000 + seq,
});

describe("worker respawn through ReconnectingPort", () => {
  it("teaches a respawned worker the call before forwarding the triggering frame", () => {
    const h = harness();
    h.deliver({ kind: "meeting-started", platform: "meet", externalMeetingId: "abc" });
    h.deliver({ kind: "participant-joined", platform: "meet", participant: syntheticParticipant("t1"), generation: 1 });
    h.deliver({
      kind: "participant-identified", platform: "meet", participantId: "dev-1", captureId: "t1", displayName: "Ada",
    });
    h.deliver(pcm("t1", 0));
    expect(h.ports).toHaveLength(1);

    h.killWorker();
    h.deliver(pcm("t1", 1)); // the post that notices the death and reconnects

    expect(h.ports).toHaveLength(2);
    const replayed = h.ports[1]!.sent.map((m) => m.type);
    // Replay lands ahead of the frame that triggered the reconnect — without
    // this the respawned worker forwards PCM it cannot attribute and has no
    // session to end (the stranded-active-session bug).
    expect(replayed).toEqual(["meeting-started", "joined", "identified", "pcm"]);
    expect(h.ports[1]!.sent[3]).toMatchObject({ type: "pcm", seq: 1 });
  });

  it("replays state as of the respawn, including facts learned after first connect", () => {
    const h = harness();
    h.deliver({ kind: "meeting-started", platform: "meet", externalMeetingId: "abc" });
    h.deliver({ kind: "participant-joined", platform: "meet", participant: syntheticParticipant("t1"), generation: 1 });
    h.deliver(pcm("t1", 0));
    // Mid-call: a second participant and a rename arrive, then the worker dies.
    h.deliver({ kind: "participant-joined", platform: "meet", participant: syntheticParticipant("t2"), generation: 1 });
    h.deliver({ kind: "meeting-renamed", platform: "meet", externalMeetingId: "abc", title: "Retro" });
    h.killWorker();
    h.deliver(pcm("t2", 5));
    const fresh = h.ports[1]!.sent;
    expect(fresh[0]).toEqual({ type: "meeting-started", platform: "meet", externalMeetingId: "abc", title: "Retro" });
    expect(fresh.filter((m) => m.type === "joined")).toHaveLength(2);
  });

  it("stays silent once the extension context itself is gone", () => {
    const h = harness();
    h.deliver({ kind: "meeting-started", platform: "meet", externalMeetingId: "abc" });
    h.deliver({ kind: "participant-joined", platform: "meet", participant: syntheticParticipant("t1"), generation: 1 });
    h.deliver(pcm("t1", 0));
    h.killExtension();
    h.deliver(pcm("t1", 1));
    h.deliver(pcm("t1", 2));
    expect(h.ports).toHaveLength(1); // no new port was ever built
  });
});
