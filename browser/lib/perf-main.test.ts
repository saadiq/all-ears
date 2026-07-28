import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetPerfMain, perfDetailEnabled, perfEnabled, setPerfState } from "./perf-main";
import type { PerfRecord } from "./perf";

// setPerfState's tier lifecycle. The regression pinned here: the heap sampler
// (detail tier) must STOP when detail turns off while tier 1 stays on — its
// stop function used to sit in the tier-1 observer list, which only drains on
// tier-1 disable, so heap sampling kept running against an off flag.

interface HeapStub {
  usedJSHeapSize: number;
  totalJSHeapSize: number;
}

function capturedPerfRecords(postMessage: ReturnType<typeof vi.fn>): PerfRecord[] {
  return postMessage.mock.calls
    .map((c) => c[0] as { __ears?: boolean; msg?: { kind?: string; records?: PerfRecord[] } })
    .filter((env) => env?.__ears && env.msg?.kind === "perf")
    .flatMap((env) => env.msg!.records ?? []);
}

describe("perf-main setPerfState", () => {
  let postMessage: ReturnType<typeof vi.fn>;
  let heap: HeapStub;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.spyOn(console, "debug").mockImplementation(() => {});
    const g = globalThis as unknown as Record<string, unknown>;
    g.window = globalThis;
    postMessage = vi.fn();
    g.postMessage = postMessage;
    // Chromium-only heap surface, stubbed so the sampler starts. The sampler
    // caches the memory OBJECT, so growth lives on the property read: every
    // usedJSHeapSize access is bigger, making `allocated_bytes` report each
    // interval the sampler is actually alive.
    let used = 1_000_000;
    heap = {
      get usedJSHeapSize() {
        used += 10_000;
        return used;
      },
      totalJSHeapSize: 2_000_000,
    } as HeapStub;
    Object.defineProperty(performance, "memory", {
      configurable: true,
      get: () => heap,
    });
    __resetPerfMain();
  });

  afterEach(() => {
    __resetPerfMain();
    delete (performance as unknown as Record<string, unknown>).memory;
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("tracks the two tiers as separate booleans", () => {
    expect(perfEnabled()).toBe(false);
    setPerfState(true, false);
    expect(perfEnabled()).toBe(true);
    expect(perfDetailEnabled()).toBe(false);
    setPerfState(true, true);
    expect(perfDetailEnabled()).toBe(true);
    setPerfState(false, true); // detail without tier 1 is never on
    expect(perfDetailEnabled()).toBe(false);
  });

  it("samples the heap while the detail tier is on", () => {
    setPerfState(true, true);
    vi.advanceTimersByTime(6_000); // one 5s heap sample + a 1s flush after it
    const heapRecords = capturedPerfRecords(postMessage).filter((r) => r.metric === "heap");
    expect(heapRecords.length).toBeGreaterThan(0);
    expect(heapRecords[0]!.fields.allocated_bytes).toBeGreaterThan(0);
  });

  it("stops the heap sampler when detail turns off while tier 1 stays on", () => {
    setPerfState(true, true);
    vi.advanceTimersByTime(6_000);
    setPerfState(true, false); // detail off, tier 1 still running
    postMessage.mockClear();

    vi.advanceTimersByTime(20_000);
    const heapRecords = capturedPerfRecords(postMessage).filter((r) => r.metric === "heap");
    // A latched gauge may re-report its last level, but the sampler itself must
    // be dead: no interval can show fresh allocation activity.
    expect(heapRecords.every((r) => r.fields.allocated_bytes === undefined)).toBe(true);
  });

  it("re-applying the same state is a no-op", () => {
    setPerfState(true, false);
    const callsAfterEnable = postMessage.mock.calls.length;
    setPerfState(true, false);
    setPerfState(true, false);
    expect(postMessage.mock.calls.length).toBe(callsAfterEnable);
  });
});
