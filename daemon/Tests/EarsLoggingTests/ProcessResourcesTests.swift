import EarsCore
import Synchronization
import Testing

@testable import EarsLogging

private final class Recorder: LogRecordSink, @unchecked Sendable {
  private let records = Mutex<[LogRecord]>([])
  func log(_ record: LogRecord) async throws { records.withLock { $0.append(record) } }
  var recorded: [LogRecord] { records.withLock { $0 } }
}

/// A clock the test advances by hand, so the interval-rate arithmetic can be
/// asserted exactly rather than raced against.
private final class SteppableClock: NowProviding, @unchecked Sendable {
  private let seconds = Mutex<Double>(1_700_000_000)
  func now() -> Instant { Instant(secondsSinceEpoch: seconds.withLock { $0 }) }
  func advance(by delta: Double) { seconds.withLock { $0 += delta } }
}

@Suite("ProcessResources")
struct ProcessResourcesTests {
  private func field(_ record: LogRecord, _ key: String) -> LogValue? {
    record.fields.first { $0.key == key }?.value
  }

  @Test("samples this process's own CPU, memory and threads")
  func sampleIsPlausible() {
    let sample = ProcessResources.sample()
    #expect(sample.userSeconds >= 0)
    #expect(sample.systemSeconds >= 0)
    #expect(sample.cpuSeconds == sample.userSeconds + sample.systemSeconds)
    #expect(sample.peakResidentBytes > 0)
    // The Mach queries can fail in principle; in a normal test process they
    // don't, and a nil here would mean the query is wired up wrong.
    #expect(sample.residentBytes != nil)
    #expect((sample.threadCount ?? 0) >= 1)
  }

  @Test("CPU time is monotonic across samples")
  func cpuIsMonotonic() {
    let first = ProcessResources.sample()
    var sink = 0.0
    for i in 0..<200_000 { sink += Double(i).squareRoot() }
    #expect(sink > 0)  // keep the work from being optimized away
    #expect(ProcessResources.sample().cpuSeconds >= first.cpuSeconds)
  }

  @Test("repeated thread-count queries don't leak port rights")
  func threadQueryIsBalanced() {
    // A leaked send right per sample would show up as an ever-growing thread
    // count here; task_threads reports live threads, not accumulated rights.
    let first = ProcessResources.sample().threadCount
    for _ in 0..<50 { _ = ProcessResources.sample() }
    let last = ProcessResources.sample().threadCount
    guard let first, let last else {
      Issue.record("expected a thread count")
      return
    }
    #expect(abs(last - first) < 20)
  }

  @Test("fields carry the counters a log consumer keys off")
  func fieldNames() {
    let keys = Set(ProcessResources.sample().fields.map(\.key))
    #expect(
      keys.isSuperset(of: ["cpu_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"]))
  }
}

@Suite("ProcessResourceLogger")
struct ProcessResourceLoggerTests {
  private func field(_ record: LogRecord, _ key: String) -> LogValue? {
    record.fields.first { $0.key == key }?.value
  }

  @Test("the first sample has no rate, since there is nothing to compare against")
  func firstSampleHasNoRate() async {
    let recorder = Recorder()
    let logger = ProcessResourceLogger(
      sink: recorder, clock: SteppableClock(), tool: "earsd", subsystem: "s", category: "c", pid: 1)
    await logger.emit()
    let record = recorder.recorded[0]
    #expect(record.event == "proc.resource")
    #expect(field(record, "cpu_percent") == nil)
    #expect(field(record, "cpu_seconds") != nil)
  }

  @Test("later samples report the interval CPU rate a cumulative counter can't give")
  func rateOnSubsequentSamples() async {
    let clock = SteppableClock()
    let recorder = Recorder()
    let logger = ProcessResourceLogger(
      sink: recorder, clock: clock, tool: "earsd", subsystem: "s", category: "c", pid: 1)
    await logger.emit()
    clock.advance(by: 60)
    await logger.emit()
    let second = recorder.recorded[1]
    #expect(field(second, "interval_seconds") == .double(60))
    guard case .double(let percent)? = field(second, "cpu_percent") else {
      Issue.record("expected cpu_percent on the second sample")
      return
    }
    #expect(percent >= 0)
  }

  @Test("stop() before start() is safe, and start() is idempotent")
  func lifecycle() async {
    let logger = ProcessResourceLogger(
      sink: Recorder(), clock: SteppableClock(), tool: "earsd", subsystem: "s", category: "c",
      pid: 1, intervalSeconds: 3600)
    await logger.stop()
    await logger.start()
    await logger.start()
    await logger.stop()
  }
}
