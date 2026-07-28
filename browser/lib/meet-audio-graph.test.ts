import { describe, expect, it } from "vitest";
import {
  AudioGraphRegistry,
  EnergyEnvelope,
  GRAPH_MAX_NODES,
  GRAPH_MAX_EDGES_PER_NODE,
  energyVerdict,
  isOnset,
  pearson,
} from "./meet-audio-graph";

// Pure-logic half of the Meet audio-graph probe (rtc-hook.ts feeds it from the
// pass-through wraps). The verdict math is what a live call's records get read
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

describe("EnergyEnvelope", () => {
  it("is bounded and reports the newest samples oldest-first", () => {
    const e = new EnergyEnvelope(3);
    for (let i = 1; i <= 5; i++) e.push({ t: i, rms: i / 10, peak: i / 10 });
    expect(e.length).toBe(3);
    expect(e.recentRms(3)).toEqual([0.3, 0.4, 0.5]);
  });

  it("flags a rising onset edge exactly once per rise", () => {
    const e = new EnergyEnvelope();
    expect(e.push({ t: 1, rms: 0, peak: 0 })).toBe(false);
    expect(e.push({ t: 2, rms: 0.1, peak: 0.3 })).toBe(true); // silent → loud
    expect(e.push({ t: 3, rms: 0.1, peak: 0.4 })).toBe(false); // still loud
    expect(e.push({ t: 4, rms: 0, peak: 0 })).toBe(false); // falling edge is not an onset
    expect(e.push({ t: 5, rms: 0.1, peak: 0.3 })).toBe(true); // second rise
  });

  it("is inactive until any sample clears the silence floor", () => {
    const e = new EnergyEnvelope();
    e.push({ t: 1, rms: 0.0001, peak: 0.0005 });
    expect(e.active()).toBe(false);
    e.push({ t: 2, rms: 0.01, peak: 0.02 });
    expect(e.active()).toBe(true);
  });
});

describe("isOnset", () => {
  it("requires crossing the threshold from below", () => {
    expect(isOnset(0, 0.05)).toBe(true);
    expect(isOnset(0.05, 0.5)).toBe(false); // already over
    expect(isOnset(0, 0.01)).toBe(false); // never reaches it
  });
});

describe("pearson", () => {
  it("is 1 for identical movement and -1 for opposite movement", () => {
    const up = [1, 2, 3, 4, 5, 6];
    const down = [6, 5, 4, 3, 2, 1];
    expect(pearson(up, up)).toBeCloseTo(1);
    expect(pearson(up, down)).toBeCloseTo(-1);
  });

  it("returns null for short or variance-free series rather than guessing", () => {
    expect(pearson([1, 2], [1, 2])).toBeNull();
    expect(pearson([1, 1, 1, 1, 1, 1], [1, 2, 3, 4, 5, 6])).toBeNull();
  });
});

describe("energyVerdict", () => {
  const envelope = (values: number[]): EnergyEnvelope => {
    const e = new EnergyEnvelope();
    values.forEach((v, i) => e.push({ t: i, rms: v, peak: v }));
    return e;
  };

  it("two active nodes with divergent envelopes ⇒ per-participant", () => {
    // Turn-taking: node A speaks first, node B answers.
    const a = envelope([0.3, 0.3, 0.3, 0.3, 0, 0, 0, 0]);
    const b = envelope([0, 0, 0, 0, 0.3, 0.3, 0.3, 0.3]);
    const v = energyVerdict(new Map([["n1", a], ["n2", b]]));
    expect(v.verdict).toBe("per-participant");
    expect(v.active).toBe(2);
    expect(v.minCorr).toBeLessThan(0);
  });

  it("two active nodes moving in lockstep ⇒ correlated-mix", () => {
    const series = [0.1, 0.4, 0.2, 0.5, 0.1, 0.3, 0.2, 0.4];
    const v = energyVerdict(new Map([["n1", envelope(series)], ["n2", envelope(series)]]));
    expect(v.verdict).toBe("correlated-mix");
    expect(v.maxCorr).toBeCloseTo(1);
  });

  it("one active node ⇒ single-active-node (mixed if several people spoke)", () => {
    const v = energyVerdict(
      new Map([
        ["n1", envelope([0.2, 0.4, 0.3, 0.2, 0.5, 0.1])],
        ["n2", envelope([0, 0, 0, 0, 0, 0])],
      ]),
    );
    expect(v.verdict).toBe("single-active-node");
    expect(v.active).toBe(1);
  });

  it("nothing active, or series too short to correlate ⇒ insufficient-data", () => {
    expect(energyVerdict(new Map()).verdict).toBe("insufficient-data");
    const short = new Map([
      ["n1", envelope([0.3, 0.2])],
      ["n2", envelope([0.1, 0.4])],
    ]);
    expect(energyVerdict(short).verdict).toBe("insufficient-data");
  });
});
