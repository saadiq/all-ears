import { mainPerf } from "./perf-main";
import type { Counter, Gauge, Histogram } from "./perf";

// Shared capture-path instrumentation: the perf metric group every pipeline
// reports into, and the `__earsDebugAudio` debug surfaces (flag reads and the
// in-page `__earsAudioLog` ring). Split out of audio-tap.ts (refactor R7) so
// the frame pipeline, the Meet decoder, and the orchestration layer can share
// them without sharing anything else.

// ── Capture-path instrumentation ─────────────────────────────────────────────
//
// One group shared by every pipeline, not one per participant: the question is
// what the capture path costs this thread in total, and per-participant series
// would multiply the record count by the tile count for no extra insight.
//
// Stage boundaries mirror consume()'s structure exactly, so a hot stage names
// the code to look at. Everything here is resolved once and cached — the hot
// path does two boolean reads and, when the detail tier is off, nothing else.

export interface CaptureMetrics {
  frame: Histogram;
  downmix: Histogram;
  speaking: Histogram;
  debugLog: Histogram;
  resample: Histogram;
  accumulate: Histogram;
  post: Histogram;
  frames: Counter;
  samples: Counter;
  posted: Counter;
  tracks: Gauge;
  decodeQueue: Gauge;
}

let metricsCache: CaptureMetrics | null = null;

export function captureMetrics(): CaptureMetrics {
  if (!metricsCache) {
    const g = mainPerf().group("capture");
    metricsCache = {
      frame: g.histogram("frame"),
      downmix: g.histogram("downmix"),
      speaking: g.histogram("speaking"),
      debugLog: g.histogram("debuglog"),
      resample: g.histogram("resample"),
      accumulate: g.histogram("accumulate"),
      post: g.histogram("post"),
      frames: g.counter("frames"),
      samples: g.counter("samples"),
      posted: g.counter("posted"),
      tracks: g.gauge("tracks"),
      decodeQueue: g.gauge("decode_queue"),
    };
  }
  return metricsCache;
}

// Debug instrumentation for live-call verification — off by default, no
// rebuild needed to use. Enable per-tab from the page's DevTools console:
//   localStorage.setItem("__earsDebugAudio", "1")   // then reload the tab
//   localStorage.removeItem("__earsDebugAudio")     // to turn back off
// Adds a throttled peak/RMS log per participant (proves PCM is non-silent,
// not just flowing) and dumps recent frame sizes/timestamps if AudioDecoder
// errors (WebCodecs gives no other way to correlate an error to a frame).
function debugAudioEnabled(): boolean {
  try {
    return localStorage.getItem("__earsDebugAudio") === "1";
  } catch {
    return false;
  }
}
// Read fresh each call (not cached at module load) — a stale cached value was
// a plausible reason debug logging silently stayed off across an epoch handoff
// or re-injection even with the localStorage flag set to "1".
export function DEBUG_AUDIO_NOW(): boolean {
  return debugAudioEnabled();
}

// Phase 4 investigation instrumentation (meet-speaking-indicator-correlation
// prompt): edge-triggered speaking-start/stop events per track, in the same
// shape/timestamp-precision as the DOM MutationObserver log used to watch
// Meet's tile speaking indicator, so the two can be diffed directly. Gated by
// the same __earsDebugAudio flag — no behavior change when off.
export const SPEAK_THRESHOLD = 0.005; // matches the existing periodic AUDIO/silent cutoff

export interface AudioLogEntry {
  t: number;
  iso: string;
  participantId: string;
  trackId: string;
  state: "start" | "stop";
  framePeak: number;
}
interface AudioLogWindow extends Window {
  __earsAudioLog?: AudioLogEntry[];
}
export function audioLog(): AudioLogEntry[] {
  const g = window as unknown as AudioLogWindow;
  if (!g.__earsAudioLog) g.__earsAudioLog = [];
  return g.__earsAudioLog;
}
