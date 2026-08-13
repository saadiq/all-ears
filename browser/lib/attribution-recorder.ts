// The effectful half of the attribution flight recorder: a per-call ring of
// encoded events, shared across epochs, exportable on demand.
//
// State lives on `window` (same pattern as rtc-hook.ts's `__earsLiveTracks`
// and audio-tap.ts's `__earsAudioLog`): a re-injected epoch loads a fresh
// module instance, but the hook functions installed by the first injection
// keep closing over the first bundle's modules — a window-global is the one
// place both write to. Everything here is best-effort by contract: recording
// evidence must never throw into the capture or identity paths.

import { AttributionRing, encodeAttributionEvent, type AttributionEvent } from "./attribution-log";

interface RecorderWindow extends Window {
  __earsAttributionExport?: AttributionRing;
}

/** node-test fallback (vitest runs without a `window`): a module-level ring so
 * the recorder stays inert but callable. */
const fallbackExport = new AttributionRing();

function rw(): RecorderWindow | null {
  return typeof window === "undefined" ? null : (window as unknown as RecorderWindow);
}

function exportRing(): AttributionRing {
  const g = rw();
  if (!g) return fallbackExport;
  if (!g.__earsAttributionExport) g.__earsAttributionExport = new AttributionRing();
  return g.__earsAttributionExport;
}

/**
 * Record one event: encode once and keep it in the per-call ring. Never
 * throws — evidence is subordinate to capture.
 */
export function recordAttribution(event: AttributionEvent): void {
  try {
    exportRing().push(encodeAttributionEvent(event));
  } catch {
    // best-effort — the flight recorder must never affect what it records
  }
}

/** The whole per-call log as JSONL — the on-demand export surface
 * (`window.__earsExportAttribution()`, installed by hook.content.ts). */
export function exportAttributionLog(): string {
  return exportRing().snapshot().join("\n");
}

/** Ring counts for the popup's debug-state snapshot. */
export function attributionDebugState(): { events: number; dropped: number } {
  return { events: exportRing().size, dropped: exportRing().dropped };
}
