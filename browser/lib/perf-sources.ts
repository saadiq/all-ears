// MAIN-world perf observers: the three signals that answer "is all-ears making
// the call choppy, and by what mechanism".
//
//   perf.video    — what the user actually sees. WebRTC inbound video receive
//                   stats, so a freeze can be attributed to the renderer rather
//                   than the network (frames dropped WITHOUT packets lost is
//                   the local-cost signature).
//   perf.longtask — the mechanism. Main-thread tasks over 50ms, which is what
//                   a dropped video frame looks like from the JS side.
//   perf.heap     — the hypothesis under test. The capture path allocates
//                   several typed arrays per audio frame; if that is the cause,
//                   heap sawtooth and long-task spikes move together.
//
// All three live in the MAIN world because that is where Meet renders video and
// where audio-tap.ts runs. Measuring from the isolated world would miss the
// contention entirely — same thread, but the timing hooks are per-realm.

import type { PerfCollector } from "./perf";
import { livePeerConnections } from "./rtc-hook";

/** How often video receive stats are sampled. `getStats()` is not free — it
 * walks every transport and codec — so this stays well above the flush period. */
export const VIDEO_STATS_INTERVAL_MS = 5_000;

/** How often the JS heap is sampled (detail tier only). */
export const HEAP_INTERVAL_MS = 5_000;

/** The long-task threshold the spec itself uses; blocking time is measured as
 * the excess over this, matching how Total Blocking Time is defined. */
const LONG_TASK_MS = 50;

// ── Long tasks ───────────────────────────────────────────────────────────────

/**
 * Observe main-thread long tasks. Returns a disconnect function, or null where
 * the entry type is unsupported (Firefox has no longtask observer today, so
 * this degrades to "no long-task data" rather than throwing).
 */
export function installLongTaskObserver(collector: PerfCollector): (() => void) | null {
  const Ctor = (globalThis as { PerformanceObserver?: typeof PerformanceObserver })
    .PerformanceObserver;
  const supported = Ctor?.supportedEntryTypes;
  if (!Ctor || (Array.isArray(supported) && !supported.includes("longtask"))) return null;

  const group = collector.group("longtask");
  const duration = group.histogram("task");
  const blocking = group.counter("blocking_ms");
  const worst = group.gauge("worst_ms");

  let observer: PerformanceObserver;
  try {
    observer = new Ctor((list) => {
      for (const entry of list.getEntries()) {
        duration.observe(entry.duration);
        blocking.add(Math.max(0, entry.duration - LONG_TASK_MS));
        worst.set(entry.duration);
      }
    });
    observer.observe({ entryTypes: ["longtask"] });
  } catch {
    return null; // observation unsupported at runtime despite the capability check
  }
  return () => observer.disconnect();
}

// ── Inbound video receive quality ────────────────────────────────────────────

/** The subset of RTCInboundRtpStreamStats this reads. Declared structurally
 * because the built-in DOM types mark most of these optional per-browser. */
interface InboundVideoStats {
  type: string;
  kind?: string;
  mediaType?: string;
  ssrc?: number;
  framesDecoded?: number;
  framesDropped?: number;
  framesReceived?: number;
  framesPerSecond?: number;
  freezeCount?: number;
  totalFreezesDuration?: number;
  pauseCount?: number;
  totalPausesDuration?: number;
  packetsLost?: number;
  packetsReceived?: number;
  jitterBufferDelay?: number;
  jitterBufferEmittedCount?: number;
}

/** Cumulative counters carried between polls so we can report per-interval
 * deltas; WebRTC reports monotonic totals for all of these. */
interface PrevSample {
  framesDecoded: number;
  framesDropped: number;
  framesReceived: number;
  freezeCount: number;
  totalFreezesDuration: number;
  pauseCount: number;
  totalPausesDuration: number;
  packetsLost: number;
  packetsReceived: number;
  jitterBufferDelay: number;
  jitterBufferEmittedCount: number;
}

const PREV_FIELDS: Array<keyof PrevSample> = [
  "framesDecoded",
  "framesDropped",
  "framesReceived",
  "freezeCount",
  "totalFreezesDuration",
  "pauseCount",
  "totalPausesDuration",
  "packetsLost",
  "packetsReceived",
  "jitterBufferDelay",
  "jitterBufferEmittedCount",
];

function sampleOf(s: InboundVideoStats): PrevSample {
  const out = {} as PrevSample;
  for (const f of PREV_FIELDS) out[f] = Number(s[f] ?? 0);
  return out;
}

function isInboundVideo(s: InboundVideoStats): boolean {
  return s.type === "inbound-rtp" && (s.kind ?? s.mediaType) === "video";
}

/**
 * Poll every live peer connection for inbound video stats and publish the
 * per-interval deltas, summed across streams.
 *
 * Aggregating rather than reporting per-SSRC is deliberate: the question is
 * whether the call as a whole stutters, and a tile-heavy Meet call would
 * otherwise emit dozens of near-identical records a second.
 */
export function startVideoStatsPoller(
  collector: PerfCollector,
  intervalMs = VIDEO_STATS_INTERVAL_MS,
): () => void {
  const group = collector.group("video");
  const streams = group.gauge("streams");
  const decoded = group.counter("frames_decoded");
  const dropped = group.counter("frames_dropped");
  const received = group.counter("frames_received");
  const fps = group.gauge("fps");
  const freezes = group.counter("freeze_count");
  const freezeMs = group.counter("freeze_ms");
  const pauses = group.counter("pause_count");
  const pauseMs = group.counter("pause_ms");
  const packetsLost = group.counter("packets_lost");
  const packetsReceived = group.counter("packets_received");
  const jitterMs = group.gauge("jitter_buffer_ms");

  const prev = new Map<number, PrevSample>();
  let stopped = false;

  const poll = async (): Promise<void> => {
    const connections = livePeerConnections();
    if (connections.size === 0) return;
    let live = 0;
    let fpsSum = 0;
    let jitterDelayDelta = 0;
    let jitterCountDelta = 0;

    for (const pc of connections) {
      let report: RTCStatsReport;
      try {
        report = await pc.getStats();
      } catch {
        continue; // connection closed between enumeration and the call
      }
      if (stopped) return;
      report.forEach((raw) => {
        const s = raw as unknown as InboundVideoStats;
        if (!isInboundVideo(s)) return;
        live += 1;
        fpsSum += Number(s.framesPerSecond ?? 0);

        const key = Number(s.ssrc ?? -1);
        const now = sampleOf(s);
        const before = prev.get(key);
        prev.set(key, now);
        // First sight of a stream establishes the baseline only: reporting its
        // absolute totals as a delta would show a call's entire history as one
        // interval's worth of drops.
        if (!before) return;

        const delta = (f: keyof PrevSample): number => Math.max(0, now[f] - before[f]);
        decoded.add(delta("framesDecoded"));
        dropped.add(delta("framesDropped"));
        received.add(delta("framesReceived"));
        freezes.add(delta("freezeCount"));
        freezeMs.add(delta("totalFreezesDuration") * 1000);
        pauses.add(delta("pauseCount"));
        pauseMs.add(delta("totalPausesDuration") * 1000);
        packetsLost.add(delta("packetsLost"));
        packetsReceived.add(delta("packetsReceived"));
        jitterDelayDelta += delta("jitterBufferDelay");
        jitterCountDelta += delta("jitterBufferEmittedCount");
      });
    }

    streams.set(live);
    if (live > 0) fps.set(fpsSum / live);
    // jitterBufferDelay is cumulative seconds over emitted frames; the ratio of
    // the two deltas is this interval's mean buffering delay.
    if (jitterCountDelta > 0) jitterMs.set((jitterDelayDelta / jitterCountDelta) * 1000);

    // Drop stats for SSRCs that vanished, so a long call doesn't retain a
    // baseline per renegotiated stream.
    if (prev.size > 64) {
      for (const key of prev.keys()) {
        if (prev.size <= 64) break;
        prev.delete(key);
      }
    }
  };

  const timer = setInterval(() => void poll(), intervalMs);
  void poll(); // establish baselines immediately rather than one interval late
  return () => {
    stopped = true;
    clearInterval(timer);
  };
}

// ── JS heap ──────────────────────────────────────────────────────────────────

interface MemoryInfo {
  usedJSHeapSize: number;
  totalJSHeapSize: number;
}

/**
 * Sample the JS heap to test the allocation hypothesis directly.
 *
 * `performance.memory` is non-standard and Chromium-only; where it is missing
 * this returns null and the heap group simply never reports. Reclaimed bytes
 * and collection count are inferred from downward steps between samples, which
 * is a coarse but honest GC proxy — there is no GC event available to content
 * script contexts.
 */
export function startHeapSampler(
  collector: PerfCollector,
  intervalMs = HEAP_INTERVAL_MS,
): (() => void) | null {
  const memory = (performance as unknown as { memory?: MemoryInfo }).memory;
  if (!memory || typeof memory.usedJSHeapSize !== "number") return null;

  const group = collector.group("heap");
  const used = group.gauge("used_bytes");
  const allocated = group.counter("allocated_bytes");
  const reclaimed = group.counter("reclaimed_bytes");
  const collections = group.counter("collections");

  let last = memory.usedJSHeapSize;
  const timer = setInterval(() => {
    const now = memory.usedJSHeapSize;
    used.set(now);
    const delta = now - last;
    if (delta >= 0) {
      allocated.add(delta);
    } else {
      // Heap shrank: a collection ran somewhere in the last interval.
      reclaimed.add(-delta);
      collections.add(1);
    }
    last = now;
  }, intervalMs);

  return () => clearInterval(timer);
}
