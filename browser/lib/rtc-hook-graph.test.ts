import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  __resetMeetGraphProbe,
  hookDebugState,
  installHook,
  setMeetGraphSinks,
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

function setUpGlobals(opts?: { debugAudio?: boolean; bridge?: boolean }): {
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
    return target; // the WebAudio contract: connect(node) returns the target
  });
  const nativeDisconnect = vi.fn();
  class FakeAudioNode {}
  (FakeAudioNode.prototype as Record<string, unknown>).connect = nativeConnect;
  (FakeAudioNode.prototype as Record<string, unknown>).disconnect = nativeDisconnect;
  g.AudioNode = FakeAudioNode;

  class FakeAudioWorkletNode {
    context: unknown;
    constructor(context: unknown, _processor: string) {
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

  it("registers worklet nodes, counts neteq-processor, and starts monitoring", () => {
    setUpGlobals();
    installHook();

    const Ctor = (globalThis as Record<string, unknown>).AudioWorkletNode as new (
      c: unknown,
      p: string,
    ) => object;
    new Ctor(fakeContext(), "neteq-processor");
    new Ctor(fakeContext(), "neteq-processor");
    new Ctor(fakeContext(), "audio-analyzer-processor");

    const state = hookDebugState();
    expect(state.webaudio.netEqWorkletNodes).toBe(2);
    expect(state.webaudio.audioWorkletNodes).toBeGreaterThanOrEqual(3);
    expect(state.graph.monitoredNodes).toBe(3);
    expect(state.graph.nodes).toBe(3);
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
    new Ctor(fakeContext((tick) => (tick <= 7 ? 0.5 : 0)), "neteq-processor");
    new Ctor(fakeContext((tick) => (tick <= 7 ? 0 : 0.5)), "neteq-processor");

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
    new Ctor(fakeContext(sameMix), "neteq-processor");
    new Ctor(fakeContext(sameMix), "neteq-processor");

    vi.advanceTimersByTime(15_000);

    const summary = emitted.find((e) => e.metric === "meet_graph_summary");
    expect(summary?.fields.verdict).toBe("correlated-mix");
  });

  it("bridges a neteq node into the capture pipeline only when __earsGraphBridge is set", () => {
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
    new Ctor(ctx, "neteq-processor");
    new Ctor(ctx, "audio-analyzer-processor"); // not a playout node — never bridged

    expect(bridged).toEqual([{ stream: destStream, id: "graphtap-1" }]);
    expect(emitted.some((e) => e.metric === "meet_graph_bridge")).toBe(true);
    expect(hookDebugState().graph.bridgedNodes).toBe(1);
  });

  it("does not bridge by default (flag off), even with the probe active", () => {
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
    new Ctor(ctx, "neteq-processor");

    expect(bridged).toHaveLength(0);
    expect(hookDebugState().graph.bridgedNodes).toBe(0);
  });

  it("survives a broken analyser: the worklet node still constructs and audio is untouched", () => {
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
    expect(hookDebugState().graph.monitoredNodes).toBe(0);
    expect(hookDebugState().webaudio.netEqWorkletNodes).toBe(1);
  });
});
