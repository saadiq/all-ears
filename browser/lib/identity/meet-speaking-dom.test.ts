import { describe, expect, it } from "vitest";
import {
  BURST_MIN_MUTATIONS,
  BURST_QUIET_MS,
  BURST_WINDOW_MS,
  DEVICE_ID_RE,
  SpeakingBurstDetector,
} from "./meet-speaking-dom";

// Timestamps are hand-fed (the detector is pure); cadences mirror the
// 2026-08-05 live probes — ring class churn at ~100ms while speaking, bursts
// separated by 3–30s quiet gaps.

const DEV = "spaces/s/devices/288";

/** Feed `n` mutations at `cadenceMs` starting at `t0`; return onsets seen. */
function feed(d: SpeakingBurstDetector, id: string, t0: number, n: number, cadenceMs: number): number[] {
  const onsets: number[] = [];
  for (let i = 0; i < n; i++) {
    const r = d.note(id, t0 + i * cadenceMs);
    if (r !== null) onsets.push(r);
  }
  return onsets;
}

describe("SpeakingBurstDetector", () => {
  it("emits one onset when the mutation cluster crosses the threshold", () => {
    const d = new SpeakingBurstDetector();
    const onsets = feed(d, DEV, 1000, 10, 100); // live ring cadence
    expect(onsets).toEqual([1000 + (BURST_MIN_MUTATIONS - 1) * 100]);
  });

  it("stays quiet below the threshold", () => {
    const d = new SpeakingBurstDetector();
    expect(feed(d, DEV, 1000, BURST_MIN_MUTATIONS - 1, 100)).toEqual([]);
  });

  it("ignores sparse mutations (one-off restyles never cluster)", () => {
    const d = new SpeakingBurstDetector();
    // Each mutation ages out of the start window before the next arrives.
    expect(feed(d, DEV, 1000, 10, BURST_WINDOW_MS + 100)).toEqual([]);
  });

  it("emits again only after a quiet gap ends the burst", () => {
    const d = new SpeakingBurstDetector();
    expect(feed(d, DEV, 1000, 10, 100)).toHaveLength(1);
    // Second turn after a 3s gap (well past BURST_QUIET_MS).
    const t2 = 1000 + 900 + 3000;
    const second = feed(d, DEV, t2, 10, 100);
    expect(second).toEqual([t2 + (BURST_MIN_MUTATIONS - 1) * 100]);
  });

  it("keeps one burst alive across pauses shorter than the quiet gap", () => {
    const d = new SpeakingBurstDetector();
    expect(feed(d, DEV, 1000, 5, 100)).toHaveLength(1);
    // Mutations resume 800ms later (< BURST_QUIET_MS): same burst, no onset —
    // even though they'd re-cross the threshold on their own.
    expect(feed(d, DEV, 1400 + 800, 5, 100)).toEqual([]);
  });

  it("needs a full new cluster after the gap — the first stray mutation isn't an onset", () => {
    const d = new SpeakingBurstDetector();
    expect(feed(d, DEV, 1000, 5, 100)).toHaveLength(1);
    const t2 = 1400 + BURST_QUIET_MS + 1;
    expect(d.note(DEV, t2)).toBeNull(); // closes the old burst, starts a window
    expect(d.note(DEV, t2 + 100)).toBeNull();
    expect(d.note(DEV, t2 + 200)).toBe(t2 + 200); // threshold crossed → new onset
  });

  it("tracks devices independently", () => {
    const d = new SpeakingBurstDetector();
    const a = "spaces/s/devices/1";
    const b = "spaces/s/devices/2";
    // Interleaved at the same instants: each device needs its own cluster.
    for (let i = 0; i < 2; i++) {
      expect(d.note(a, 1000 + i * 100)).toBeNull();
      expect(d.note(b, 1000 + i * 100)).toBeNull();
    }
    expect(d.note(a, 1200)).toBe(1200);
    expect(d.note(b, 1200)).toBe(1200);
  });

  it("evicts the stalest device at the cap instead of growing unbounded", () => {
    const d = new SpeakingBurstDetector(BURST_MIN_MUTATIONS, BURST_WINDOW_MS, BURST_QUIET_MS, 2);
    feed(d, "spaces/s/devices/1", 1000, 3, 100); // stalest
    feed(d, "spaces/s/devices/2", 2000, 3, 100);
    feed(d, "spaces/s/devices/3", 3000, 3, 100); // evicts device 1
    // Device 1's state is gone: its next mutations start from scratch mid-"burst".
    expect(d.note("spaces/s/devices/1", 3500)).toBeNull();
  });
});

describe("DEVICE_ID_RE", () => {
  it("accepts real device ids and rejects everything else", () => {
    expect(DEVICE_ID_RE.test("spaces/nWhYwwBZETYB/devices/288")).toBe(true);
    expect(DEVICE_ID_RE.test("speaker-1")).toBe(false);
    expect(DEVICE_ID_RE.test("spaces/x/devices/")).toBe(false);
    expect(DEVICE_ID_RE.test("spaces/x/devices/12/extra")).toBe(false);
  });
});
