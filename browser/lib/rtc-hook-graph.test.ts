import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  __resetMeetGraphProbe,
  hookDebugState,
  installHook,
  setMeetGraphSinks,
  stopMeetGraphProbe,
} from "./rtc-hook";

// The Meet audio-graph probe's DOM-facing half: the pass-through wraps on
// AudioNode.connect/disconnect and the AudioWorkletNode constructor, the
// analyser-based per-node energy sampler, and the (off-by-default) capture
// bridge. Constraint under test throughout: the native call ALWAYS runs and
// its result is returned untouched — probe state only ever observes.

interface Emitted {
  metric: string;
  fields: Record<string, number | string>;
}

function setUpGlobals(opts?: {
  debugAudio?: boolean;
  bridge?: boolean;
  /** Worklet `numberOfOutputs`; 0 models Meet's sink-shaped analyzer node. */
  workletOutputs?: number;
  /** Make the native connect throw for the PROBE's analyser branch only, so
   * Meet's own wiring still succeeds and the node still becomes a candidate. */
  connectThrows?: boolean;
}): {
  FakeAudioNode: new () => object;
  nativeConnect: ReturnType<typeof vi.fn>;
  nativeDisconnect: ReturnType<typeof vi.fn>;
} {
  const g = globalThis as unknown as Record<string, unknown>;
  delete g.__earsHookInstalled;
  delete g.__earsEpoch;
  delete g.__earsOnTrack;
  delete g.__earsLiveTracks;
  delete g.__earsEncodedAudioListeners;
  delete g.__earsLivePCs;
  delete g.__earsWebAudioTracks;
  delete g.__earsGraphSinks;
  g.window = globalThis;
  g.location = { host: "meet.google.com" };

  const store = new Map<string, string>();
  if (opts?.debugAudio !== false) store.set("__earsDebugAudio", "1");
  if (opts?.bridge) store.set("__earsGraphBridge", "1");
  g.localStorage = { getItem: (k: string) => store.get(k) ?? null };

  class FakeRTCPeerConnection {
    addEventListener(): void {}
  }
  g.RTCPeerConnection = FakeRTCPeerConnection;
  class FakeRTCRtpReceiver {}
  (FakeRTCRtpReceiver.prototype as Record<string, unknown>).createEncodedStreams = () => ({
    readable: new ReadableStream(),
    writable: new WritableStream(),
  });
  g.RTCRtpReceiver = FakeRTCRtpReceiver;

  const nativeConnect = vi.fn(function (this: unknown, target: unknown) {
    const isAnalyserBranch = typeof (target as { getFloatTimeDomainData?: unknown })
      ?.getFloatTimeDomainData === "function";
    if (opts?.connectThrows && isAnalyserBranch) {
      throw new Error("IndexSizeError: output index (0) exceeds number of outputs (0)");
    }
    return target; // the WebAudio contract: connect(node) returns the target
  });
  const nativeDisconnect = vi.fn();
  class FakeAudioNode {}
  (FakeAudioNode.prototype as Record<string, unknown>).connect = nativeConnect;
  (FakeAudioNode.prototype as Record<string, unknown>).disconnect = nativeDisconnect;
  g.AudioNode = FakeAudioNode;

  // AudioWorkletNode extends AudioNode in the DOM — so it inherits the wrapped
  // connect/disconnect, which the probe's release path relies on.
  class FakeAudioWorkletNode extends FakeAudioNode {
    context: unknown;
    numberOfOutputs = opts?.workletOutputs ?? 1;
    constructor(context: unknown, _processor: string) {
      super();
      this.context = context;
    }
  }
  g.AudioWorkletNode = FakeAudioWorkletNode;

  return { FakeAudioNode, nativeConnect, nativeDisconnect };
}

/** A worklet context whose analyser plays back a scripted per-tick peak. */
function fakeContext(peakForTick?: (tick: number) => number): {
  createAnalyser: () => object;
  createMediaStreamDestination?: () => { stream: object };
} {
  return {
    createAnalyser: () => {
      let tick = 0;
      return {
        fftSize: 2048,
        getFloatTimeDomainData(buf: Float32Array) {
          tick += 1;
          buf.fill(peakForTick ? peakForTick(tick) : 0);
        },
      };
    },
  };
}

/** One sampler period — the settle the probe waits out before it branches off
 * a node Meet has just wired up. */
const SETTLE_MS = 1_000;

/**
 * Model Meet wiring `nodes` into its own graph, by connecting each to a sink.
 * The probe refuses to branch off a worklet until this has happened AND a
 * sample tick has elapsed (see deferGraphNodeWork), so a test that wants a
 * monitored node must do both — that ordering is the crash fix, not incidental.
 * Returns the sink, which is itself a graph node.
 */
function wire(...nodes: unknown[]): object {
  const Node = (globalThis as Record<string, unknown>).AudioNode as new () => object;
  const sink = new Node();
  for (const n of nodes) (n as { connect(t: unknown): unknown }).connect(sink);
  return sink;
}

describe("Meet audio-graph probe (rtc-hook.ts)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.spyOn(console, "debug").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    __resetMeetGraphProbe();
  });

  afterEach(() => {
    __resetMeetGraphProbe();
    setMeetGraphSinks(null);
    vi.useRealTimers();
  });

  it("connect is pass-through — native runs, its result comes back — and the graph maps the edge", () => {
    const { FakeAudioNode, nativeConnect } = setUpGlobals();
    installHook();

    const a = new FakeAudioNode() as { connect(t: unknown): unknown; disconnect(t?: unknown): void };
    const b = new FakeAudioNode();
    const result = a.connect(b);

    expect(nativeConnect).toHaveBeenCalledTimes(1);
    expect(result).toBe(b);
    expect(hookDebugState().graph).toMatchObject({ nodes: 2, edges: 1 });

    a.disconnect(b);
    expect(hookDebugState().graph.edges).toBe(0);
  });

  it("does no graph bookkeeping when __earsDebugAudio is off — but native still runs", () => {
    const { FakeAudioNode, nativeConnect } = setUpGlobals({ debugAudio: false });
    installHook();

    const a = new FakeAudioNode() as { connect(t: unknown): unknown };
    const b = new FakeAudioNode();
    expect(a.connect(b)).toBe(b);
    expect(nativeConnect).toHaveBeenCalledTimes(1);
    expect(hookDebugState().graph.nodes).toBe(0);
  });

  it("registers worklet nodes, counts neteq-processor, and monitors them once Meet wires them up", () => {
    vi.useFakeTimers();
    setUpGlobals();
    installHook();

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    const a = new Ctor(fakeContext(), "neteq-processor");
    const b = new Ctor(fakeContext(), "neteq-processor");
    const c = new Ctor(fakeContext(), "audio-analyzer-processor");
    wire(a, b, c);
    vi.advanceTimersByTime(SETTLE_MS);

    const state = hookDebugState();
    expect(state.webaudio.netEqWorkletNodes).toBe(2);
    expect(state.webaudio.audioWorkletNodes).toBeGreaterThanOrEqual(3);
    expect(state.graph.monitoredNodes).toBe(3);
    expect(state.graph.pendingNodes).toBe(0);
    expect(state.graph.nodes).toBe(4); // three worklets + the sink they feed
  });

  it("never branches off a worklet at construction — only after Meet wires it up", () => {
    // The crash this guards (2026-07-29): attaching inside the AudioWorkletNode
    // constructor made Meet's neteq-processor a pulled node before its NetEq
    // SharedArrayBuffer arrived, so the render thread ran process() against
    // uninitialised WASM and trapped — SIGTRAP, whole renderer, ~1.6s in.
    // Nothing here can catch that: it happens on the audio thread.
    vi.useFakeTimers();
    const { nativeConnect } = setUpGlobals();
    installHook();
    const counting = countingContext();

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    const node = new Ctor(counting.ctx, "neteq-processor");

    // Construction alone: registered as a candidate, but nothing allocated and
    // — the part that matters — nothing connected to it.
    expect(counting.created()).toBe(0);
    expect(nativeConnect).not.toHaveBeenCalled();
    expect(hookDebugState().graph).toMatchObject({ monitoredNodes: 0, pendingNodes: 1 });

    // Time alone is not enough either: an unwired worklet is never touched.
    vi.advanceTimersByTime(10 * SETTLE_MS);
    expect(counting.created()).toBe(0);
    expect(hookDebugState().graph).toMatchObject({ monitoredNodes: 0, pendingNodes: 1 });

    // Meet wires it up: now it is live in Meet's own graph, so branching off it
    // no longer decides whether it processes.
    wire(node);
    vi.advanceTimersByTime(SETTLE_MS);
    expect(counting.created()).toBe(1);
    expect(hookDebugState().graph).toMatchObject({ monitoredNodes: 1, pendingNodes: 0 });
  });

  it("samples per-node energy into the perf ring and emits a turn-taking verdict of per-participant", () => {
    vi.useFakeTimers();
    setUpGlobals();
    installHook();
    const emitted: Emitted[] = [];
    setMeetGraphSinks({
      emitPerf: (metric, fields) => emitted.push({ metric, fields }),
      bridgeStream: () => {},
    });

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    // Turn-taking: node 1 speaks for the first 7 ticks, node 2 for the rest.
    const a = new Ctor(fakeContext((tick) => (tick <= 7 ? 0.5 : 0)), "neteq-processor");
    const b = new Ctor(fakeContext((tick) => (tick <= 7 ? 0 : 0.5)), "neteq-processor");
    wire(a, b);

    // Tick 1 attaches both and samples them, so analyser ticks track sampler
    // ticks one-for-one from here.
    vi.advanceTimersByTime(15_000); // 15 sampling ticks → summary tick included

    const energy = emitted.filter((e) => e.metric === "meet_graph_energy");
    expect(energy.length).toBeGreaterThan(0);
    const first = energy[0]!.fields;
    expect(first.n1_rms).toBeCloseTo(0.5);
    expect(first.n2_rms).toBeCloseTo(0);

    // Both nodes crossed silence → loud exactly once each.
    const onsets = emitted.filter((e) => e.metric === "meet_graph_onset");
    expect(onsets.map((o) => o.fields.node).sort()).toEqual(["n1", "n2"]);

    const summaries = emitted.filter((e) => e.metric === "meet_graph_summary");
    expect(summaries).toHaveLength(1);
    expect(summaries[0]!.fields).toMatchObject({
      verdict: "per-participant",
      active: 2,
      neteq_nodes: 2,
    });
  });

  it("emits a lockstep verdict of correlated-mix when every node carries the same envelope", () => {
    vi.useFakeTimers();
    setUpGlobals();
    installHook();
    const emitted: Emitted[] = [];
    setMeetGraphSinks({
      emitPerf: (metric, fields) => emitted.push({ metric, fields }),
      bridgeStream: () => {},
    });

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    const sameMix = (tick: number): number => 0.2 + 0.15 * (tick % 4);
    wire(
      new Ctor(fakeContext(sameMix), "neteq-processor"),
      new Ctor(fakeContext(sameMix), "neteq-processor"),
    );

    vi.advanceTimersByTime(15_000);

    const summary = emitted.find((e) => e.metric === "meet_graph_summary");
    expect(summary?.fields.verdict).toBe("correlated-mix");
  });

  it("bridges a neteq node into the capture pipeline only when __earsGraphBridge is set", () => {
    vi.useFakeTimers();
    setUpGlobals({ bridge: true });
    installHook();
    const bridged: Array<{ stream: unknown; id: string }> = [];
    const emitted: Emitted[] = [];
    setMeetGraphSinks({
      emitPerf: (metric, fields) => emitted.push({ metric, fields }),
      bridgeStream: (stream, id) => bridged.push({ stream, id }),
    });

    const destStream = { fake: "stream" };
    const ctx = fakeContext();
    ctx.createMediaStreamDestination = () => ({ stream: destStream });
    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    // The bridge branches off the node's output too, so it waits out the same
    // gate the meter does — never at construction.
    wire(new Ctor(ctx, "neteq-processor"), new Ctor(ctx, "audio-analyzer-processor"));
    expect(bridged).toHaveLength(0);
    vi.advanceTimersByTime(SETTLE_MS);

    expect(bridged).toEqual([{ stream: destStream, id: "graphtap-1" }]);
    expect(emitted.some((e) => e.metric === "meet_graph_bridge")).toBe(true);
    expect(hookDebugState().graph.bridgedNodes).toBe(1);
  });

  it("does not bridge by default (flag off), even with the probe active", () => {
    vi.useFakeTimers();
    setUpGlobals();
    installHook();
    const bridged: unknown[] = [];
    setMeetGraphSinks({
      emitPerf: () => {},
      bridgeStream: (stream) => bridged.push(stream),
    });

    const ctx = fakeContext();
    ctx.createMediaStreamDestination = () => ({ stream: {} });
    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    wire(new Ctor(ctx, "neteq-processor"));
    vi.advanceTimersByTime(SETTLE_MS);

    expect(bridged).toHaveLength(0);
    expect(hookDebugState().graph.bridgedNodes).toBe(0);
  });

  /** A context whose createAnalyser is counted, and whose analysers count
   * their own disconnects — the two numbers that say whether a failed attach
   * left an orphan behind in Meet's graph. */
  function countingContext(): {
    ctx: { createAnalyser: () => object };
    created: () => number;
    disconnected: () => number;
  } {
    let created = 0;
    let disconnected = 0;
    return {
      ctx: {
        createAnalyser: () => {
          created += 1;
          return {
            fftSize: 2048,
            getFloatTimeDomainData: (buf: Float32Array) => buf.fill(0),
            disconnect: () => {
              disconnected += 1;
            },
          };
        },
      },
      created: () => created,
      disconnected: () => disconnected,
    };
  }

  it("skips zero-output worklets without allocating an analyser, and without burning the cap", () => {
    // Meet's audio-analyzer-processor is sink-shaped: connecting it throws
    // IndexSizeError. The probe must not build an analyser it cannot attach.
    setUpGlobals({ workletOutputs: 0 });
    installHook();
    const counting = countingContext();

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    for (let i = 0; i < 50; i++) new Ctor(counting.ctx, "audio-analyzer-processor");

    expect(counting.created()).toBe(0);
    const state = hookDebugState().graph;
    expect(state.monitoredNodes).toBe(0);
    // Cheap rejections must not consume the cap — a real node arriving later
    // still gets monitored.
    expect(state.attachFailures).toBe(0);
  });

  it("bounds analyser leakage when the connect itself throws", () => {
    vi.useFakeTimers();
    setUpGlobals({ connectThrows: true });
    installHook();
    const counting = countingContext();

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    const nodes: object[] = [];
    for (let i = 0; i < 200; i++) nodes.push(new Ctor(counting.ctx, "neteq-processor"));
    wire(...nodes);
    vi.advanceTimersByTime(SETTLE_MS);

    // Capped at GRAPH_ENERGY_MAX_NODES, not one orphan per construction — and
    // every analyser that was allocated got released rather than left behind.
    expect(counting.created()).toBe(16);
    expect(counting.disconnected()).toBe(16);
    expect(hookDebugState().graph.attachFailures).toBe(16);
    expect(hookDebugState().graph.monitoredNodes).toBe(0);
  });

  it("evicts a monitored node once its context closes, severing the probe's branch", () => {
    vi.useFakeTimers();
    const { nativeDisconnect } = setUpGlobals();
    installHook();

    const ctx = fakeContext(() => 0) as { createAnalyser: () => object; state?: string };
    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    wire(new Ctor(ctx, "neteq-processor"));
    vi.advanceTimersByTime(SETTLE_MS);
    expect(hookDebugState().graph.monitoredNodes).toBe(1);

    vi.advanceTimersByTime(2_000);
    expect(hookDebugState().graph.monitoredNodes).toBe(1); // still live

    ctx.state = "closed"; // Meet tore the context down
    vi.advanceTimersByTime(1_000);

    const state = hookDebugState().graph;
    expect(state.monitoredNodes).toBe(0);
    expect(state.evictedNodes).toBe(1);
    // The branch that kept the worklet actively processing is gone.
    expect(nativeDisconnect).toHaveBeenCalled();
  });

  it("releases the monitor when Meet's own bare disconnect() severs the branch", () => {
    vi.useFakeTimers();
    setUpGlobals();
    installHook();

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    const node = new Ctor(fakeContext(), "neteq-processor") as {
      disconnect: (t?: unknown) => void;
    };
    wire(node);
    vi.advanceTimersByTime(SETTLE_MS);
    expect(hookDebugState().graph.monitoredNodes).toBe(1);

    node.disconnect(); // drops every out-edge, ours included

    expect(hookDebugState().graph.monitoredNodes).toBe(0);
    expect(hookDebugState().graph.evictedNodes).toBe(1);
  });

  it("stopMeetGraphProbe releases every branch and stops the sampler", () => {
    vi.useFakeTimers();
    setUpGlobals();
    installHook();
    const emitted: Emitted[] = [];
    setMeetGraphSinks({
      emitPerf: (metric, fields) => emitted.push({ metric, fields }),
      bridgeStream: () => {},
    });

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    wire(
      new Ctor(fakeContext(() => 0.5), "neteq-processor"),
      new Ctor(fakeContext(() => 0.5), "neteq-processor"),
    );
    vi.advanceTimersByTime(SETTLE_MS);
    expect(hookDebugState().graph.monitoredNodes).toBe(2);

    stopMeetGraphProbe();
    expect(hookDebugState().graph.monitoredNodes).toBe(0);

    const before = emitted.length;
    vi.advanceTimersByTime(30_000);
    expect(emitted.length).toBe(before); // sampler really stopped
  });

  it("sub-gates each graph-touching probe independently, so a crash can be bisected", () => {
    // __earsProbeNodeEnergy=0 must stop the analyser attach without touching
    // the pure-JS graph bookkeeping (which cannot crash a renderer).
    const g = globalThis as unknown as Record<string, unknown>;
    setUpGlobals();
    const store = new Map<string, string>([
      ["__earsDebugAudio", "1"],
      ["__earsProbeNodeEnergy", "0"],
    ]);
    g.localStorage = { getItem: (k: string) => store.get(k) ?? null };
    installHook();

    const counting = countingContext();
    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    new Ctor(counting.ctx, "neteq-processor");

    expect(counting.created()).toBe(0); // no analyser, nothing attached
    expect(hookDebugState().graph.monitoredNodes).toBe(0);
    // Bookkeeping still ran — the node is in the topology.
    expect(hookDebugState().graph.nodes).toBe(1);
    expect(hookDebugState().webaudio.netEqWorkletNodes).toBe(1);
  });

  it("survives a broken analyser: the worklet node still constructs and audio is untouched", () => {
    vi.useFakeTimers();
    setUpGlobals();
    installHook();
    const brokenCtx = {
      createAnalyser: () => {
        throw new Error("no analyser for you");
      },
    };
    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    const node = new Ctor(brokenCtx, "neteq-processor");
    expect(node).toBeTruthy();
    wire(node);
    vi.advanceTimersByTime(SETTLE_MS);
    expect(hookDebugState().graph.monitoredNodes).toBe(0);
    expect(hookDebugState().webaudio.netEqWorkletNodes).toBe(1);
  });
});
