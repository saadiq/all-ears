// Performance instrumentation shared by every extension context.
//
// Deliberately NOT routed through the console tap (debug-log.ts). That tap
// JSON-serializes every argument synchronously on the main thread — the very
// thread these metrics exist to measure — so logging perf through it would tax
// the thing under investigation. Perf records travel as structured objects on
// their own channel and land in their own IndexedDB ring (log-store.ts), so a
// busy call can't evict the console entries you want to correlate against.
//
// Hot-path rule: nothing here allocates per observation. Histograms are
// preallocated Float64Arrays and `observe()` is a bucket increment. Objects are
// built only at flush time, once per interval.
//
// Records join across processes on `t` (epoch ms, same clock as LogEntry.t and
// the daemon's ISO8601 `ts`) and on the `source` tag, which is the same
// `browser:<platform>:<participant>` label earsd puts on its own capture events.

/** One flushed metric group. `fields` is flat: numbers and short strings only. */
export interface PerfRecord {
  /** Epoch ms. */
  t: number;
  /** Origin realm: "hook" (MAIN world) | "relay" (isolated) | "bg". */
  ctx: string;
  /** Metric group, e.g. "capture", "video", "longtask". */
  metric: string;
  fields: Record<string, number | string>;
}

/** Anything a {@link MetricGroup} can flush. */
interface Drainable {
  /** Write this interval's fields into `out` under `prefix`; reset. Returns
   * false when there was nothing to report, so empty groups emit no record. */
  drainInto(out: Record<string, number | string>, prefix: string): boolean;
}

// Log2 buckets from 1/64 ms up. 32 buckets covers microseconds to minutes,
// which is far wider than anything on the audio path — the top bucket exists
// so a pathological stall lands somewhere rather than being clamped away.
const BUCKETS = 32;
const MIN_MS = 1 / 64;

function round(v: number, places = 3): number {
  const f = 10 ** places;
  return Math.round(v * f) / f;
}

/**
 * Fixed-bucket latency histogram. `observe()` is O(1) and allocation-free, so
 * it is safe to call from inside the per-audio-frame path.
 */
export class Histogram {
  private readonly counts = new Float64Array(BUCKETS);
  private n = 0;
  private sum = 0;
  private peak = 0;

  observe(ms: number): void {
    if (!(ms >= 0)) return; // also rejects NaN
    this.n += 1;
    this.sum += ms;
    if (ms > this.peak) this.peak = ms;
    let i = ms < MIN_MS ? 0 : Math.floor(Math.log2(ms / MIN_MS)) + 1;
    if (i >= BUCKETS) i = BUCKETS - 1;
    this.counts[i]! += 1;
  }

  get count(): number {
    return this.n;
  }

  /** Upper edge of the bucket holding the p-th percentile (conservative). */
  percentile(p: number): number {
    if (this.n === 0) return 0;
    const target = p * this.n;
    let cum = 0;
    for (let i = 0; i < BUCKETS; i++) {
      cum += this.counts[i]!;
      if (cum >= target) return i === 0 ? MIN_MS : MIN_MS * 2 ** i;
    }
    return this.peak;
  }

  reset(): void {
    this.counts.fill(0);
    this.n = 0;
    this.sum = 0;
    this.peak = 0;
  }

  drainInto(out: Record<string, number | string>, prefix: string): boolean {
    if (this.n === 0) return false;
    out[`${prefix}_n`] = this.n;
    out[`${prefix}_ms`] = round(this.sum);
    out[`${prefix}_p50`] = round(this.percentile(0.5));
    out[`${prefix}_p95`] = round(this.percentile(0.95));
    out[`${prefix}_max`] = round(this.peak);
    this.reset();
    return true;
  }
}

/** Monotonic count over an interval. */
export class Counter {
  private v = 0;

  add(n = 1): void {
    this.v += n;
  }

  get value(): number {
    return this.v;
  }

  drainInto(out: Record<string, number | string>, prefix: string): boolean {
    if (this.v === 0) return false;
    out[prefix] = round(this.v);
    this.v = 0;
    return true;
  }
}

/** Last-value-plus-peak sample, for levels rather than rates (queue depth,
 * buffered bytes, active track count). */
export class Gauge {
  private last = 0;
  private peak = 0;
  private seen = false;

  set(v: number): void {
    if (!(typeof v === "number") || Number.isNaN(v)) return;
    this.last = v;
    if (!this.seen || v > this.peak) this.peak = v;
    this.seen = true;
  }

  get value(): number {
    return this.last;
  }

  drainInto(out: Record<string, number | string>, prefix: string): boolean {
    if (!this.seen) return false;
    out[prefix] = round(this.last);
    out[`${prefix}_max`] = round(this.peak);
    this.peak = this.last;
    return true;
  }
}

/** A source of flushable fields, published under one `metric` name. */
export interface PerfSource {
  readonly metric: string;
  drain(out: Record<string, number | string>): boolean;
}

/**
 * A named bundle of instruments flushed together as one {@link PerfRecord}.
 * Callers hold direct references to the instruments they create (no per-
 * observation map lookup), which is what keeps the hot path free of overhead.
 */
export class MetricGroup implements PerfSource {
  private readonly items: Array<{ prefix: string; item: Drainable }> = [];

  constructor(readonly metric: string) {}

  histogram(prefix: string): Histogram {
    const h = new Histogram();
    this.items.push({ prefix, item: h });
    return h;
  }

  counter(prefix: string): Counter {
    const c = new Counter();
    this.items.push({ prefix, item: c });
    return c;
  }

  gauge(prefix: string): Gauge {
    const g = new Gauge();
    this.items.push({ prefix, item: g });
    return g;
  }

  drain(out: Record<string, number | string>): boolean {
    let any = false;
    for (const { prefix, item } of this.items) {
      if (item.drainInto(out, prefix)) any = true;
    }
    return any;
  }
}

/**
 * Owns the registered sources and the flush timer for one context.
 *
 * `sink` receives whole batches (one call per flush, not one per record) so a
 * context ships a single message per interval regardless of how many groups
 * reported.
 */
export class PerfCollector {
  private readonly sources: PerfSource[] = [];
  private readonly tags: Record<string, string | number> = {};
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor(
    readonly ctx: string,
    private readonly sink: (records: PerfRecord[]) => void,
    private readonly now: () => number = () => Date.now(),
  ) {}

  /** Register a source (usually a {@link MetricGroup}); returns it for chaining. */
  register<T extends PerfSource>(source: T): T {
    this.sources.push(source);
    return source;
  }

  group(metric: string): MetricGroup {
    return this.register(new MetricGroup(metric));
  }

  /**
   * Stamp a field onto every subsequent record — the earsd source label, the
   * meeting id. Passing `undefined` clears it. Tags are what make
   * two processes' records joinable, so set `source` as soon as it is known.
   */
  tag(key: string, value: string | number | undefined): void {
    if (value === undefined) delete this.tags[key];
    else this.tags[key] = value;
  }

  /** Ship one record immediately, outside the flush cycle (for events that are
   * inherently one-shot, like a single long task above a threshold). */
  emit(metric: string, fields: Record<string, number | string>): void {
    this.sink([{ t: this.now(), ctx: this.ctx, metric, fields: { ...this.tags, ...fields } }]);
  }

  /** Drain every source and ship whatever reported. */
  flush(): void {
    const t = this.now();
    const batch: PerfRecord[] = [];
    for (const source of this.sources) {
      const fields: Record<string, number | string> = { ...this.tags };
      if (source.drain(fields)) batch.push({ t, ctx: this.ctx, metric: source.metric, fields });
    }
    if (batch.length > 0) this.sink(batch);
  }

  start(intervalMs: number): void {
    this.stop();
    this.timer = setInterval(() => this.flush(), intervalMs);
  }

  stop(): void {
    if (this.timer !== undefined) {
      clearInterval(this.timer);
      this.timer = undefined;
    }
  }
}

/** Serialize records to newline-delimited JSON for file export. */
export function perfToJsonl(records: PerfRecord[]): string {
  if (records.length === 0) return "";
  return records.map((r) => JSON.stringify(r)).join("\n") + "\n";
}
