import { describe, expect, it, vi } from "vitest";
import {
  Counter,
  Gauge,
  Histogram,
  MetricGroup,
  PerfCollector,
  perfToJsonl,
  type PerfRecord,
} from "./perf";

describe("Histogram", () => {
  it("reports nothing until it has an observation", () => {
    const h = new Histogram();
    const out: Record<string, number | string> = {};
    expect(h.drainInto(out, "stage")).toBe(false);
    expect(out).toEqual({});
  });

  it("summarizes count, total, percentiles and peak", () => {
    const h = new Histogram();
    for (const ms of [1, 1, 1, 1, 1, 1, 1, 1, 1, 40]) h.observe(ms);
    const out: Record<string, number | string> = {};
    expect(h.drainInto(out, "stage")).toBe(true);
    expect(out.stage_n).toBe(10);
    expect(out.stage_ms).toBe(49);
    expect(out.stage_max).toBe(40);
    // Buckets are log2, so a percentile lands on its bucket's upper edge.
    expect(Number(out.stage_p50)).toBeGreaterThanOrEqual(1);
    expect(Number(out.stage_p50)).toBeLessThan(4);
    expect(Number(out.stage_p95)).toBeGreaterThanOrEqual(40);
  });

  it("resets after draining, so each interval stands alone", () => {
    const h = new Histogram();
    h.observe(5);
    h.drainInto({}, "s");
    expect(h.count).toBe(0);
    expect(h.drainInto({}, "s")).toBe(false);
  });

  it("ignores NaN and negative observations rather than corrupting the bucket index", () => {
    const h = new Histogram();
    h.observe(Number.NaN);
    h.observe(-1);
    expect(h.count).toBe(0);
  });

  it("clamps observations past the top bucket instead of writing out of bounds", () => {
    const h = new Histogram();
    h.observe(1e12);
    const out: Record<string, number | string> = {};
    h.drainInto(out, "s");
    expect(out.s_n).toBe(1);
    expect(out.s_max).toBe(1e12);
  });

  it("treats sub-resolution values as the first bucket", () => {
    const h = new Histogram();
    h.observe(0);
    h.observe(0.0001);
    const out: Record<string, number | string> = {};
    h.drainInto(out, "s");
    expect(out.s_n).toBe(2);
  });
});

describe("Counter", () => {
  it("accumulates and resets on drain", () => {
    const c = new Counter();
    c.add();
    c.add(4);
    const out: Record<string, number | string> = {};
    expect(c.drainInto(out, "frames")).toBe(true);
    expect(out.frames).toBe(5);
    expect(c.drainInto({}, "frames")).toBe(false);
  });
});

describe("Gauge", () => {
  it("reports the last value and the interval peak", () => {
    const g = new Gauge();
    g.set(10);
    g.set(50);
    g.set(20);
    const out: Record<string, number | string> = {};
    expect(g.drainInto(out, "buffered")).toBe(true);
    expect(out.buffered).toBe(20);
    expect(out.buffered_max).toBe(50);
  });

  it("carries the last value into the next interval's peak", () => {
    // Otherwise a gauge that stops being written would report a peak of 0
    // while still sitting at a high level.
    const g = new Gauge();
    g.set(100);
    g.drainInto({}, "b");
    const out: Record<string, number | string> = {};
    g.drainInto(out, "b");
    expect(out.b_max).toBe(100);
  });

  it("reports nothing before its first sample", () => {
    expect(new Gauge().drainInto({}, "b")).toBe(false);
  });
});

describe("MetricGroup", () => {
  it("reports false when no instrument has data, so empty records are never emitted", () => {
    const g = new MetricGroup("capture");
    g.histogram("frame");
    g.counter("frames");
    expect(g.drain({})).toBe(false);
  });

  it("merges every instrument's fields into one record body", () => {
    const g = new MetricGroup("capture");
    g.histogram("frame").observe(2);
    g.counter("frames").add(3);
    g.gauge("tracks").set(4);
    const out: Record<string, number | string> = {};
    expect(g.drain(out)).toBe(true);
    expect(out.frame_n).toBe(1);
    expect(out.frames).toBe(3);
    expect(out.tracks).toBe(4);
  });
});

describe("PerfCollector", () => {
  function collect(): { records: PerfRecord[]; perf: PerfCollector } {
    const records: PerfRecord[] = [];
    const perf = new PerfCollector("hook", (batch) => records.push(...batch), () => 1000);
    return { records, perf };
  }

  it("ships one batch per flush, with a record per reporting group", () => {
    const { records, perf } = collect();
    const sink = vi.fn();
    const batched = new PerfCollector("hook", sink, () => 1000);
    batched.group("a").counter("x").add(1);
    batched.group("b").counter("y").add(1);
    batched.flush();
    expect(sink).toHaveBeenCalledTimes(1);
    expect(sink.mock.calls[0]![0]).toHaveLength(2);
    expect(records).toEqual([]);
    void perf;
  });

  it("omits groups with nothing to report", () => {
    const { records, perf } = collect();
    perf.group("quiet").counter("x");
    perf.group("busy").counter("y").add(1);
    perf.flush();
    expect(records.map((r) => r.metric)).toEqual(["busy"]);
  });

  it("emits no batch at all when every group is quiet", () => {
    const sink = vi.fn();
    const perf = new PerfCollector("hook", sink, () => 1000);
    perf.group("quiet").counter("x");
    perf.flush();
    expect(sink).not.toHaveBeenCalled();
  });

  it("stamps tags onto every record so records join across processes", () => {
    const { records, perf } = collect();
    perf.tag("source", "browser:meet:abc");
    perf.tag("arm", "off");
    perf.group("video").counter("frames_dropped").add(2);
    perf.flush();
    expect(records[0]!.fields.source).toBe("browser:meet:abc");
    expect(records[0]!.fields.arm).toBe("off");
    expect(records[0]!.ctx).toBe("hook");
    expect(records[0]!.t).toBe(1000);
  });

  it("clears a tag when set to undefined", () => {
    const { records, perf } = collect();
    perf.tag("arm", "off");
    perf.tag("arm", undefined);
    perf.group("video").counter("x").add(1);
    perf.flush();
    expect(records[0]!.fields.arm).toBeUndefined();
  });

  it("emits one-shot records immediately, tags included", () => {
    const { records, perf } = collect();
    perf.tag("meeting", "abc");
    perf.emit("longtask", { duration_ms: 120 });
    expect(records).toEqual([
      { t: 1000, ctx: "hook", metric: "longtask", fields: { meeting: "abc", duration_ms: 120 } },
    ]);
  });

  it("flushes on its interval while started, and stops cleanly", () => {
    vi.useFakeTimers();
    try {
      const { records, perf } = collect();
      const counter = perf.group("capture").counter("frames");
      perf.start(1000);
      counter.add(1);
      vi.advanceTimersByTime(1000);
      expect(records).toHaveLength(1);
      perf.stop();
      counter.add(1);
      vi.advanceTimersByTime(5000);
      expect(records).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("perfToJsonl", () => {
  it("renders one record per line with a trailing newline", () => {
    const records: PerfRecord[] = [
      { t: 1, ctx: "bg", metric: "transport", fields: { frames_sent: 2 } },
      { t: 2, ctx: "bg", metric: "transport", fields: { frames_sent: 3 } },
    ];
    expect(perfToJsonl(records).split("\n")).toHaveLength(3);
    expect(perfToJsonl([])).toBe("");
  });
});
