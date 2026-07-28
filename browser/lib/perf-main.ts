// The MAIN world's perf collector: one per realm, created on first use and
// never torn down, so audio-tap.ts can hold stable instrument references on its
// hot path instead of re-resolving them per frame.
//
// Enabling and disabling starts and stops the flush timer and the observers,
// not the collector itself. While disabled nothing feeds the instruments (the
// long-task observer is disconnected, the pollers are cleared, and the capture
// path checks `perfDetailEnabled()` before timing anything), so "off" really is
// idle rather than "collecting into a bin nobody empties".
//
// Records leave this realm the same way tapped console entries do — over
// postMessage to the isolated relay — because the MAIN world has no extension
// APIs. They ride their own message kind so they never pass through the console
// tap; see perf.ts for why that matters.

import { PerfCollector } from "./perf";
import { postToIsolated } from "./protocol";
import { installLongTaskObserver, startHeapSampler, startVideoStatsPoller } from "./perf-sources";

/** Flush period. One message per second per context, aggregating however many
 * observations landed in between. */
export const PERF_FLUSH_INTERVAL_MS = 1_000;

let collector: PerfCollector | null = null;
let enabled = false;
let detail = false;
let stopObservers: Array<() => void> = [];

/** The realm's collector, created on first call. Always non-null; callers still
 * gate their hot-path work on {@link perfEnabled} / {@link perfDetailEnabled}. */
export function mainPerf(): PerfCollector {
  if (!collector) {
    collector = new PerfCollector("hook", (records) => postToIsolated({ kind: "perf", records }));
  }
  return collector;
}

/** Tier 1 collection is running. */
export function perfEnabled(): boolean {
  return enabled;
}

/**
 * Detail tier is running. Checked per audio frame, so it must stay a plain
 * boolean read — no storage access, no function indirection beyond this.
 */
export function perfDetailEnabled(): boolean {
  return enabled && detail;
}

/** Stamp a field onto every subsequent record from this realm. */
export function perfTag(key: string, value: string | number | undefined): void {
  mainPerf().tag(key, value);
}

/**
 * Apply the flags mirrored from storage by the isolated relay. Idempotent:
 * re-applying the same state is a no-op, so the repeated `capture-state`-style
 * republishing content.ts does costs nothing.
 */
export function setPerfState(nextEnabled: boolean, nextDetail: boolean): void {
  const perf = mainPerf();
  // Captured before the tier-1 branch mutates `enabled`: the heap decision
  // below compares the OLD combined state against the new one, and reading
  // `enabled` after the mutation would report "already running" for a sampler
  // that had never started.
  const hadHeap = enabled && detail;
  if (nextEnabled !== enabled) {
    enabled = nextEnabled;
    if (enabled) {
      const longTasks = installLongTaskObserver(perf);
      if (longTasks) stopObservers.push(longTasks);
      stopObservers.push(startVideoStatsPoller(perf));
      perf.start(PERF_FLUSH_INTERVAL_MS);
      console.debug(
        "[ears][perf] collection on" + (longTasks ? "" : " (long-task observer unavailable)"),
      );
    } else {
      perf.stop();
      perf.flush(); // ship whatever the last partial interval gathered
      for (const stop of stopObservers) stop();
      stopObservers = [];
      console.debug("[ears][perf] collection off");
    }
  }

  // The heap sampler belongs to the detail tier, so it toggles independently of
  // the tier-1 observers above — but only ever runs while tier 1 is on.
  const wantHeap = enabled && nextDetail;
  detail = nextDetail;
  if (wantHeap && !hadHeap) {
    const stop = startHeapSampler(perf);
    if (stop) stopObservers.push(stop);
    console.debug("[ears][perf] detail tier on (per-frame stage timing, heap sampling)");
  } else if (!wantHeap && hadHeap) {
    console.debug("[ears][perf] detail tier off");
  }
}

/** Test seam: drop all state so each test starts from a clean realm. */
export function __resetPerfMain(): void {
  collector?.stop();
  for (const stop of stopObservers) stop();
  stopObservers = [];
  collector = null;
  enabled = false;
  detail = false;
}
