import EarsCore
import Foundation

/// Emits the `stage.start`/`stage.end` span pair `docs/logging.md` specifies
/// for bounded operations: both records share a `span_id`, and the end record
/// carries `duration_ms` plus, where the stage processes audio, `rtf`.
///
/// The schema has been documented since the logging spec was written — including
/// a worked example and a `jq` recipe for querying it — but nothing emitted it,
/// so every timing question about the pipeline had to be answered by pairing
/// `run.start`/`run.summary` timestamps by hand, which only yields whole-run
/// numbers and cannot attribute time to a stage.
///
/// Durations come from a monotonic clock, not from differencing wall-clock
/// timestamps: a wall clock can step (NTP, sleep/wake) and would otherwise
/// produce negative or wildly inflated stage times on exactly the long-running
/// process where that matters most. `ts` still comes from ``NowProviding`` so
/// records stay on the same timeline as everything else.
public struct StageSpans: Sendable {
  private let sink: any LogRecordSink
  private let clock: any NowProviding
  private let tool: String
  private let subsystem: String
  private let category: String
  private let pid: Int32
  private let nextSpanID: @Sendable () -> String

  /// - Parameter spanID: Injectable so tests can assert on stable ids. The
  ///   default is random per span, which is all a correlation key needs.
  public init(
    sink: any LogRecordSink,
    clock: any NowProviding,
    tool: String,
    subsystem: String,
    category: String,
    pid: Int32,
    spanID: @escaping @Sendable () -> String = {
      String(UInt32.random(in: 0..<0xFFFF_FFFF), radix: 36)
    }
  ) {
    self.sink = sink
    self.clock = clock
    self.tool = tool
    self.subsystem = subsystem
    self.category = category
    self.pid = pid
    self.nextSpanID = spanID
  }

  /// Run `body` as a measured stage.
  ///
  /// `stage.end` is emitted whether `body` returns or throws — a stage that
  /// blew up is exactly the one whose timing you want — with `status` naming
  /// which happened, at `error` level on the failure path so it surfaces
  /// alongside the error records that led to it.
  ///
  /// - Parameters:
  ///   - stage: Stage name, e.g. `asr`, `diarize`, `vad`, `model_load`.
  ///   - session: Session id, when the stage runs inside one.
  ///   - audioSeconds: Audio duration this stage processed. Supplying it adds
  ///     `rtf` (wall time ÷ audio time) to the end record — the number that
  ///     says whether the pipeline keeps up with realtime.
  ///   - fields: Extra context merged into both records.
  @discardableResult
  public func measure<T>(
    _ stage: String,
    session: String? = nil,
    audioSeconds: Double? = nil,
    fields: [LogField] = [],
    body: () async throws -> T
  ) async rethrows -> T {
    let spanID = nextSpanID()
    var context: [LogField] = [
      LogField("span_id", .string(spanID)), LogField("stage", .string(stage)),
    ]
    if let session { context.append(LogField("session", .string(session))) }
    context.append(contentsOf: fields)

    await emit(event: "stage.start", level: .debug, fields: context)
    let started = ContinuousClock.now
    do {
      let result = try await body()
      await emitEnd(
        context: context, elapsed: Self.seconds(since: started), audioSeconds: audioSeconds,
        status: "ok", error: nil)
      return result
    } catch {
      await emitEnd(
        context: context, elapsed: Self.seconds(since: started), audioSeconds: audioSeconds,
        status: "error", error: "\(error)")
      throw error
    }
  }

  /// Elapsed seconds, read once — sampling the clock twice (as an inline
  /// subtraction in two places would) yields two different durations.
  private static func seconds(since started: ContinuousClock.Instant) -> Double {
    let components = (ContinuousClock.now - started).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  private func emitEnd(
    context: [LogField],
    elapsed: Double,
    audioSeconds: Double?,
    status: String,
    error: String?
  ) async {
    var fields = context
    fields.append(LogField("duration_ms", .double((elapsed * 1000).rounded())))
    if let audioSeconds, audioSeconds > 0 {
      fields.append(LogField("rtf", .double((elapsed / audioSeconds * 10000).rounded() / 10000)))
      fields.append(LogField("audio_seconds", .double((audioSeconds * 1000).rounded() / 1000)))
    }
    fields.append(LogField("status", .string(status)))
    if let error { fields.append(LogField("error", .string(error))) }
    await emit(event: "stage.end", level: error == nil ? .info : .error, fields: fields)
  }

  private func emit(event: String, level: LogLevel, fields: [LogField]) async {
    let record = LogRecord(
      ts: clock.now(), level: level, tool: tool, subsystem: subsystem, category: category,
      pid: pid, event: event, fields: fields)
    // Instrumentation must never fail the work it measures.
    try? await sink.log(record)
  }
}
