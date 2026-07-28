import { describe, expect, it, vi } from "vitest";
import { AbExperiment, type Arm } from "./perf-ab";

function driver(minutes = 5): { arms: Arm[]; ab: AbExperiment } {
  const arms: Arm[] = [];
  const ab = new AbExperiment(minutes, (arm) => arms.push(arm));
  return { arms, ab };
}

describe("AbExperiment", () => {
  it("starts on the capturing arm, so an aborted run has still recorded", () => {
    vi.useFakeTimers();
    try {
      const { arms, ab } = driver();
      ab.start();
      expect(arms).toEqual([{ name: "on", suspended: false, cycle: 1 }]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("alternates arms on its period", () => {
    vi.useFakeTimers();
    try {
      const { arms, ab } = driver(5);
      ab.start();
      vi.advanceTimersByTime(5 * 60_000);
      vi.advanceTimersByTime(5 * 60_000);
      vi.advanceTimersByTime(5 * 60_000);
      expect(arms.map((a) => a.name)).toEqual(["on", "off", "on", "off"]);
      expect(arms.map((a) => a.cycle)).toEqual([1, 2, 3, 4]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("does not switch before the period elapses", () => {
    vi.useFakeTimers();
    try {
      const { arms, ab } = driver(5);
      ab.start();
      vi.advanceTimersByTime(5 * 60_000 - 1);
      expect(arms).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("restores the capturing arm on stop, even mid-off-arm", () => {
    // The failure this guards against is silent and expensive: clearing the
    // experiment while suspended would leave the rest of the call unrecorded.
    vi.useFakeTimers();
    try {
      const { arms, ab } = driver(5);
      ab.start();
      vi.advanceTimersByTime(5 * 60_000);
      expect(arms.at(-1)!.suspended).toBe(true);
      ab.stop();
      expect(arms.at(-1)).toEqual({ name: "on", suspended: false, cycle: 2 });
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops firing after stop()", () => {
    vi.useFakeTimers();
    try {
      const { arms, ab } = driver(5);
      ab.start();
      ab.stop();
      const after = arms.length;
      vi.advanceTimersByTime(60 * 60_000);
      expect(arms).toHaveLength(after);
      expect(ab.running).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it("is idempotent on repeated start", () => {
    vi.useFakeTimers();
    try {
      const { arms, ab } = driver(5);
      ab.start();
      ab.start();
      expect(arms).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("stop() before start() does nothing", () => {
    const { arms, ab } = driver();
    ab.stop();
    expect(arms).toEqual([]);
  });
});
