import { PARTICIPANT_ID_ATTRIBUTES, extractParticipantId, type ElementLike } from "./meet";

// Meet speaking-ring DOM watcher: per-device speaking-turn onsets read from
// the tile UI, feeding the same SpeakingCorrelator path as the collections
// mute edge (meet.ts `onDeviceSpeaking`).
//
// Why this signal exists and is trustworthy (live-verified 2026-08-05, two
// instrumented calls): Meet drives each tile's speaking indicator from its own
// `audio-analyzer-processor` AudioWorklet fed by per-participant tracks, and
// renders it as class-token churn on elements inside the tile subtree —
// observed at ~100ms cadence for the whole audible burst, bursting only while
// that participant speaks (3–30s quiet gaps between turns, no mute toggles in
// between). The collections channel carries NO per-turn events on current
// builds (triple-verified; see meet-collections.ts), so this is the only
// per-turn, per-device signal available.
//
// Detection keys on burst SHAPE, never on class values: Meet's class tokens
// are obfuscated and rotate per build (`gjg47c` one build, something else the
// next), but "a cluster of class mutations inside a [data-participant-id]
// subtree" is the stable contract — the indicator cannot animate without
// mutating classes, and nothing else in a tile churns classes at that cadence
// for seconds at a time.
//
// Split per the house tier rules: SpeakingBurstDetector is pure (timestamps
// passed in, no DOM, no clock); startMeetSpeakingWatch owns the
// MutationObserver and the wall clock. The observer is passive (observe-only)
// and its callback must never throw into the page.

/** Class-attribute mutations within this window count toward one burst start. */
export const BURST_WINDOW_MS = 500;
/** Mutations inside the window needed to call it a burst (ring cadence is
 * ~100ms, so real speech crosses this in ~300ms; one-off restyles don't). */
export const BURST_MIN_MUTATIONS = 3;
/** Quiet gap that ends a burst; the next cluster is a new turn. Matches the
 * 1.2s clustering the live probes used to segment turns. */
export const BURST_QUIET_MS = 1_200;
/** Per-device state cap — far above any real call's tile count. */
export const MAX_TRACKED_DEVICES = 64;

interface DeviceBurstState {
  /** Mutation timestamps inside the current start-window (empty mid-burst). */
  recent: number[];
  inBurst: boolean;
  lastAt: number;
}

/**
 * Pure burst-clustering state machine. `note()` one class-mutation timestamp
 * per call; it returns the onset timestamp when that mutation starts a new
 * burst, else null. Mid-burst mutations only refresh the quiet-gap clock; a
 * mutation after `quietMs` of silence closes the old burst and starts
 * accumulating toward the next one.
 */
export class SpeakingBurstDetector {
  private readonly devices = new Map<string, DeviceBurstState>();

  constructor(
    private readonly minMutations: number = BURST_MIN_MUTATIONS,
    private readonly windowMs: number = BURST_WINDOW_MS,
    private readonly quietMs: number = BURST_QUIET_MS,
    private readonly maxDevices: number = MAX_TRACKED_DEVICES,
  ) {}

  note(deviceId: string, at: number): number | null {
    let s = this.devices.get(deviceId);
    if (!s) {
      if (this.devices.size >= this.maxDevices) this.evictStalest();
      s = { recent: [], inBurst: false, lastAt: at };
      this.devices.set(deviceId, s);
    }

    if (s.inBurst) {
      if (at - s.lastAt < this.quietMs) {
        s.lastAt = at; // still the same burst — refresh the quiet clock
        return null;
      }
      s.inBurst = false; // burst ended in the gap; this mutation opens a new window
    }

    const cutoff = at - this.windowMs;
    s.recent = s.recent.filter((t) => t > cutoff);
    s.recent.push(at);
    s.lastAt = at;
    if (s.recent.length < this.minMutations) return null;

    s.inBurst = true;
    s.recent = [];
    return at;
  }

  private evictStalest(): void {
    let stalest: string | null = null;
    let oldest = Infinity;
    for (const [id, s] of this.devices) {
      if (s.lastAt < oldest) {
        oldest = s.lastAt;
        stalest = id;
      }
    }
    if (stalest !== null) this.devices.delete(stalest);
  }
}

/** Only real device ids feed the correlator — placeholder/aggregate tiles
 * (no id, or non-device-shaped values) are ignored. */
export const DEVICE_ID_RE = /^spaces\/[^/]+\/devices\/\d+$/;

const TILE_SELECTOR = PARTICIPANT_ID_ATTRIBUTES.map((a) => `[${a}]`).join(",");

/** How long to keep retrying when document.body doesn't exist yet (the watch
 * starts on the capture-state message, which can beat body at document_start). */
const BODY_POLL_MS = 1_000;

type ClosestElement = Element & { closest?: (selectors: string) => Element | null };

/**
 * Observe the page for speaking-ring bursts and report one onset per
 * (device, turn). Returns a stop function; safe to call in any environment
 * (no-ops without a DOM). Observe-only — never mutates the page.
 */
export function startMeetSpeakingWatch(
  onOnset: (deviceId: string, at: number) => void,
): () => void {
  if (typeof document === "undefined" || typeof MutationObserver === "undefined") return () => {};

  const detector = new SpeakingBurstDetector();
  const observer = new MutationObserver((records) => {
    try {
      for (const record of records) {
        if (record.type !== "attributes") continue;
        const target = record.target as ClosestElement;
        const tile = target.closest?.(TILE_SELECTOR);
        if (!tile) continue;
        const id = extractParticipantId(tile as unknown as ElementLike);
        if (!id || !DEVICE_ID_RE.test(id)) continue;
        const onset = detector.note(id, Date.now());
        if (onset === null) continue;
        console.debug(`[ears][identity] Meet speaking-ring burst → ${id}`);
        onOnset(id, onset);
      }
    } catch {
      // observe-only diagnostics — a DOM-shape surprise must never reach the page
    }
  });

  let stopped = false;
  let retryTimer: ReturnType<typeof setTimeout> | null = null;
  const tryObserve = (): void => {
    if (stopped) return;
    const root = document.body ?? document.documentElement;
    if (!root) {
      retryTimer = setTimeout(tryObserve, BODY_POLL_MS);
      return;
    }
    // The ring animates via class churn only; filtering to `class` keeps the
    // callback off every other attribute Meet touches.
    observer.observe(root, { subtree: true, attributes: true, attributeFilter: ["class"] });
  };
  tryObserve();

  return () => {
    stopped = true;
    if (retryTimer !== null) clearTimeout(retryTimer);
    observer.disconnect();
  };
}
