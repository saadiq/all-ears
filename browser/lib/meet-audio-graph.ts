// Meet WebAudio graph mapping + per-node energy correlation (journal #75,
// dev/captures/2026-07-24-meet-collections-drift.md "Result 3").
//
// Meet decodes participant Opus inside WASM (NetEQ over SharedArrayBuffer) and
// plays out through `AudioWorkletNode(processor="neteq-processor")`, so encoded
// frames never enter JS and the createEncodedStreams tee reads nothing. The one
// question that decides whether per-participant capture is recoverable at all:
// does the WebAudio graph downstream of that WASM carry audio PER PARTICIPANT
// (N tappable nodes), or is it ALREADY MIXED before anything tappable (one node
// carrying everyone)?
//
// This module is the pure half of the answer: a bounded registry of the page's
// audio graph (fed by rtc-hook.ts's pass-through connect/worklet wraps) and the
// envelope/correlation math over per-node energy samples. Everything
// DOM-touching (the wraps, the analysers, the sampling timer) stays in
// rtc-hook.ts so this logic is unit-testable in node.
//
// Verdict logic: two nodes whose energy envelopes are UNCORRELATED over a call
// with turn-taking are carrying different participants; nodes that move in
// lockstep are copies of the same mix; one active node is a mix by definition
// once more than one person has spoken.

/** Hard cap on tracked graph nodes: a tile-heavy call must not build unbounded
 * bookkeeping. Nodes past the cap are counted (`overflow`) but not stored. */
export const GRAPH_MAX_NODES = 128;

/** Per-node out-edge cap — fan-out past this is counted, not stored. */
export const GRAPH_MAX_EDGES_PER_NODE = 32;

/** A node's energy sample, produced by the shared sampling timer. */
export interface EnergySample {
  /** Epoch ms. */
  t: number;
  rms: number;
  peak: number;
}

/** Peak level treated as "this node is carrying signal". Matches the existing
 * track energy probe's silence floor (rtc-hook.ts monitorTrackEnergy). */
export const ENERGY_ACTIVE_PEAK = 0.001;

/** Rising-edge threshold for onset detection (speech start, used to correlate
 * a node against collections unmute edges offline). */
export const ONSET_PEAK = 0.02;

/** True when this sample is a rising edge over the onset threshold. */
export function isOnset(previousPeak: number, peak: number): boolean {
  return previousPeak < ONSET_PEAK && peak >= ONSET_PEAK;
}

interface GraphNodeInfo {
  id: string;
  type: string;
  /** AudioWorkletNode processor name, when known. */
  processor?: string;
  /** MediaStreamAudioSourceNode input track ids, when known. */
  trackIds?: string[];
  outs: Set<string>;
  fanIn: number;
  createdAt: number;
}

/** One graph node, serializable for debug reports and perf records. */
export interface GraphNodeSnapshot {
  id: string;
  type: string;
  processor?: string;
  trackIds?: string[];
  outs: string[];
  fanIn: number;
}

/**
 * Bounded, id-assigning registry of the live audio graph. Keys are the real
 * node objects (WeakMap — the registry never keeps a node alive); values are
 * small structural records. All methods are total: unknown objects register on
 * first sight, and over-cap nodes degrade to a counter rather than growing.
 */
export class AudioGraphRegistry {
  private readonly ids = new WeakMap<object, string>();
  private readonly info = new Map<string, GraphNodeInfo>();
  private seq = 0;
  private overflowCount = 0;
  private edgeCount = 0;

  private register(node: object, type?: string): string | null {
    const existing = this.ids.get(node);
    if (existing) return existing;
    if (this.info.size >= GRAPH_MAX_NODES) {
      this.overflowCount += 1;
      return null;
    }
    this.seq += 1;
    const id = `n${this.seq}`;
    this.ids.set(node, id);
    this.info.set(id, {
      id,
      type: type ?? constructorName(node),
      outs: new Set(),
      fanIn: 0,
      createdAt: Date.now(),
    });
    return id;
  }

  /** Register (or look up) a node; returns its id, or null once over cap. */
  ensure(node: object, type?: string): string | null {
    return this.register(node, type);
  }

  idOf(node: object): string | null {
    return this.ids.get(node) ?? null;
  }

  /** Register an AudioWorkletNode with its processor name. */
  noteWorklet(node: object, processor: string): string | null {
    const id = this.register(node, "AudioWorkletNode");
    if (id) this.info.get(id)!.processor = processor;
    return id;
  }

  /** Register a MediaStreamAudioSourceNode with the track ids feeding it. */
  noteSource(node: object, trackIds: string[]): string | null {
    const id = this.register(node, "MediaStreamAudioSourceNode");
    if (id) this.info.get(id)!.trackIds = trackIds;
    return id;
  }

  /** Record `from.connect(to)`. Either end registers on first sight. `to` may
   * be an AudioParam or anything else — it still gets a typed node entry, so
   * fan-out to params is visible in the topology. */
  noteConnect(from: object, to: unknown): void {
    const fromId = this.register(from);
    if (!fromId) return;
    if (typeof to !== "object" || to === null) return;
    const toId = this.register(to);
    if (!toId) return;
    const fromInfo = this.info.get(fromId)!;
    if (fromInfo.outs.has(toId)) return; // reconnect of an existing edge
    if (fromInfo.outs.size >= GRAPH_MAX_EDGES_PER_NODE) return;
    fromInfo.outs.add(toId);
    this.edgeCount += 1;
    this.info.get(toId)!.fanIn += 1;
  }

  /** Record `from.disconnect(to?)`. A bare disconnect drops every out-edge. */
  noteDisconnect(from: object, to?: unknown): void {
    const fromId = this.ids.get(from);
    if (!fromId) return;
    const fromInfo = this.info.get(fromId);
    if (!fromInfo) return;
    const drop = (toId: string): void => {
      if (!fromInfo.outs.delete(toId)) return;
      this.edgeCount -= 1;
      const toInfo = this.info.get(toId);
      if (toInfo) toInfo.fanIn = Math.max(0, toInfo.fanIn - 1);
    };
    if (to !== undefined && typeof to === "object" && to !== null) {
      const toId = this.ids.get(to);
      if (toId) drop(toId);
      return;
    }
    for (const toId of [...fromInfo.outs]) drop(toId);
  }

  counts(): { nodes: number; edges: number; overflow: number } {
    return { nodes: this.info.size, edges: this.edgeCount, overflow: this.overflowCount };
  }

  /** How many registered AudioWorkletNodes carry this processor name. */
  workletCount(processor: string): number {
    let n = 0;
    for (const node of this.info.values()) if (node.processor === processor) n += 1;
    return n;
  }

  snapshot(limit = 40): GraphNodeSnapshot[] {
    const out: GraphNodeSnapshot[] = [];
    for (const node of this.info.values()) {
      if (out.length >= limit) break;
      out.push({
        id: node.id,
        type: node.type,
        ...(node.processor !== undefined ? { processor: node.processor } : {}),
        ...(node.trackIds !== undefined ? { trackIds: node.trackIds } : {}),
        outs: [...node.outs],
        fanIn: node.fanIn,
      });
    }
    return out;
  }

  /**
   * The graph as flat perf-record fields (`n3: "AudioWorkletNode(neteq-processor) ->n5 in:2"`),
   * so the topology survives Meet's post-call console wipe inside the perf
   * ring. Track ids and counts only — never participant names.
   */
  topologyFields(limit = 40): Record<string, string> {
    const fields: Record<string, string> = {};
    let n = 0;
    for (const node of this.info.values()) {
      if (n >= limit) {
        fields.topology_truncated = String(this.info.size - limit);
        break;
      }
      n += 1;
      const label = node.processor
        ? `${node.type}(${node.processor})`
        : node.trackIds
          ? `${node.type}(tracks=${node.trackIds.join("|")})`
          : node.type;
      const outs = node.outs.size > 0 ? ` ->${[...node.outs].join(",")}` : "";
      fields[node.id] = `${label}${outs} in:${node.fanIn}`;
    }
    return fields;
  }
}

function constructorName(value: object): string {
  const name = (value as { constructor?: { name?: string } }).constructor?.name;
  return typeof name === "string" && name.length > 0 ? name : "unknown";
}

/** Bounded per-node energy history. One shared sampling timer pushes to every
 * envelope each tick, so samples align by index from the tail. */
export class EnergyEnvelope {
  private ring: EnergySample[] = [];
  private previousPeak = 0;

  constructor(private readonly capacity = 60) {}

  /** Push a sample; returns true when it is a rising onset edge. */
  push(sample: EnergySample): boolean {
    const onset = isOnset(this.previousPeak, sample.peak);
    this.previousPeak = sample.peak;
    if (this.ring.length >= this.capacity) this.ring.shift();
    this.ring.push(sample);
    return onset;
  }

  get length(): number {
    return this.ring.length;
  }

  last(): EnergySample | null {
    return this.ring.length > 0 ? this.ring[this.ring.length - 1]! : null;
  }

  /** The newest `n` rms values, oldest first. */
  recentRms(n: number): number[] {
    return this.ring.slice(-n).map((s) => s.rms);
  }

  /** True when any sample in the window shows signal above the silence floor. */
  active(threshold = ENERGY_ACTIVE_PEAK): boolean {
    return this.ring.some((s) => s.peak >= threshold);
  }
}

/** Pearson correlation of two equal-length series; null when either series is
 * too short (<5 points) or has no variance (a constant tells you nothing). */
export function pearson(a: number[], b: number[]): number | null {
  const n = Math.min(a.length, b.length);
  if (n < 5) return null;
  const xs = a.slice(-n);
  const ys = b.slice(-n);
  const meanX = xs.reduce((s, v) => s + v, 0) / n;
  const meanY = ys.reduce((s, v) => s + v, 0) / n;
  let cov = 0;
  let varX = 0;
  let varY = 0;
  for (let i = 0; i < n; i++) {
    const dx = xs[i]! - meanX;
    const dy = ys[i]! - meanY;
    cov += dx * dy;
    varX += dx * dx;
    varY += dy * dy;
  }
  if (varX === 0 || varY === 0) return null;
  return cov / Math.sqrt(varX * varY);
}

/** Above this every active pair moves in lockstep — copies of one mix. */
export const CORRELATED_MIX_THRESHOLD = 0.85;
/** Below this two active nodes are carrying different audio. */
export const DISTINCT_SOURCES_THRESHOLD = 0.5;

export interface EnergyPair {
  a: string;
  b: string;
  corr: number;
}

export interface EnergyVerdict {
  monitored: number;
  active: number;
  pairs: EnergyPair[];
  maxCorr: number | null;
  minCorr: number | null;
  /**
   * - `per-participant`: ≥2 active nodes whose envelopes diverge — separate
   *   audio per node, per-participant capture is recoverable.
   * - `correlated-mix`: ≥2 active nodes but every pair moves in lockstep —
   *   copies of one mix.
   * - `single-active-node`: exactly one node ever carries signal. Mixed, IF
   *   more than one participant spoke during the window.
   * - `ambiguous`: correlations in between — needs more turn-taking.
   * - `insufficient-data`: nothing active yet, or series too short.
   */
  verdict:
    | "per-participant"
    | "correlated-mix"
    | "single-active-node"
    | "ambiguous"
    | "insufficient-data";
}

/**
 * Summarize the monitored envelopes into the per-participant-vs-mixed verdict.
 * `window` is how many trailing samples to correlate over (samples align by
 * index because one timer feeds every envelope).
 */
export function energyVerdict(
  envelopes: Map<string, EnergyEnvelope>,
  window = 30,
): EnergyVerdict {
  const activeIds = [...envelopes.entries()].filter(([, e]) => e.active()).map(([id]) => id);
  const pairs: EnergyPair[] = [];
  for (let i = 0; i < activeIds.length; i++) {
    for (let j = i + 1; j < activeIds.length; j++) {
      const corr = pearson(
        envelopes.get(activeIds[i]!)!.recentRms(window),
        envelopes.get(activeIds[j]!)!.recentRms(window),
      );
      if (corr !== null) {
        pairs.push({ a: activeIds[i]!, b: activeIds[j]!, corr: Math.round(corr * 1000) / 1000 });
      }
    }
  }
  const corrs = pairs.map((p) => p.corr);
  const maxCorr = corrs.length > 0 ? Math.max(...corrs) : null;
  const minCorr = corrs.length > 0 ? Math.min(...corrs) : null;

  let verdict: EnergyVerdict["verdict"];
  if (activeIds.length === 0) verdict = "insufficient-data";
  else if (activeIds.length === 1) verdict = "single-active-node";
  else if (corrs.length === 0) verdict = "insufficient-data";
  else if (minCorr !== null && minCorr < DISTINCT_SOURCES_THRESHOLD) verdict = "per-participant";
  else if (minCorr !== null && minCorr >= CORRELATED_MIX_THRESHOLD) verdict = "correlated-mix";
  else verdict = "ambiguous";

  return { monitored: envelopes.size, active: activeIds.length, pairs, maxCorr, minCorr, verdict };
}
