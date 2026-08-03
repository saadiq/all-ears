import { describe, expect, it } from "vitest";
import {
  AudioGraphRegistry,
  GRAPH_MAX_NODES,
  GRAPH_MAX_EDGES_PER_NODE,
} from "./meet-audio-graph";

// Pure-logic half of the Meet audio-graph probe (rtc-hook.ts feeds it from the
// pass-through wraps). The topology map is what a live call's records get read
// through, so it is pinned here rather than eyeballed from a console.

describe("AudioGraphRegistry", () => {
  it("assigns stable ids and records typed nodes", () => {
    const g = new AudioGraphRegistry();
    class GainNode {}
    const a = new GainNode();
    expect(g.ensure(a)).toBe("n1");
    expect(g.ensure(a)).toBe("n1"); // same object, same id
    expect(g.idOf(a)).toBe("n1");
    expect(g.snapshot()[0]).toMatchObject({ id: "n1", type: "GainNode" });
  });

  it("maps connect/disconnect into edges with fan-in, ignoring duplicate edges", () => {
    const g = new AudioGraphRegistry();
    const a = {};
    const b = {};
    g.noteConnect(a, b);
    g.noteConnect(a, b); // reconnect of an existing edge — not a second edge
    expect(g.counts()).toMatchObject({ nodes: 2, edges: 1 });
    const [snapA, snapB] = g.snapshot();
    expect(snapA!.outs).toEqual([snapB!.id]);
    expect(snapB!.fanIn).toBe(1);

    g.noteDisconnect(a, b);
    expect(g.counts().edges).toBe(0);
    expect(g.snapshot()[1]!.fanIn).toBe(0);
  });

  it("a bare disconnect drops every out-edge", () => {
    const g = new AudioGraphRegistry();
    const a = {};
    g.noteConnect(a, {});
    g.noteConnect(a, {});
    expect(g.counts().edges).toBe(2);
    g.noteDisconnect(a);
    expect(g.counts().edges).toBe(0);
  });

  it("caps tracked nodes and counts the overflow instead of growing", () => {
    const g = new AudioGraphRegistry();
    for (let i = 0; i < GRAPH_MAX_NODES + 5; i++) g.ensure({});
    expect(g.counts().nodes).toBe(GRAPH_MAX_NODES);
    expect(g.counts().overflow).toBe(5);
  });

  it("caps per-node fan-out", () => {
    const g = new AudioGraphRegistry();
    const hub = {};
    for (let i = 0; i < GRAPH_MAX_EDGES_PER_NODE + 3; i++) g.noteConnect(hub, {});
    expect(g.counts().edges).toBe(GRAPH_MAX_EDGES_PER_NODE);
  });

  it("counts worklet nodes by processor name", () => {
    const g = new AudioGraphRegistry();
    g.noteWorklet({}, "neteq-processor");
    g.noteWorklet({}, "neteq-processor");
    g.noteWorklet({}, "audio-analyzer-processor");
    expect(g.workletCount("neteq-processor")).toBe(2);
  });

  it("renders flat topology fields with processor and track-id labels — ids only, no names", () => {
    const g = new AudioGraphRegistry();
    const worklet = {};
    const source = {};
    g.noteWorklet(worklet, "neteq-processor");
    g.noteSource(source, ["track-a", "track-b"]);
    g.noteConnect(source, worklet);
    const fields = g.topologyFields();
    expect(fields.n1).toBe("AudioWorkletNode(neteq-processor) in:1");
    expect(fields.n2).toBe("MediaStreamAudioSourceNode(tracks=track-a|track-b) ->n1 in:0");
  });

  it("truncates topology fields past the limit and says by how much", () => {
    const g = new AudioGraphRegistry();
    for (let i = 0; i < 45; i++) g.ensure({});
    const fields = g.topologyFields(40);
    expect(Object.keys(fields)).toHaveLength(41); // 40 nodes + the truncation marker
    expect(fields.topology_truncated).toBe("5");
  });
});

