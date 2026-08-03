import EarsCore
import Synchronization
import Testing

@testable import EarsLogging

private final class Recorder: LogRecordSink, @unchecked Sendable {
  private let records = Mutex<[LogRecord]>([])
  func log(_ record: LogRecord) async throws { records.withLock { $0.append(record) } }
  var recorded: [LogRecord] { records.withLock { $0 } }
}

private struct FixedClock: NowProviding {
  let instant: Instant
  func now() -> Instant { instant }
}

private struct Boom: Error {}

@Suite("StageSpans")
struct StageSpanTests {
  private func spans(_ recorder: Recorder, id: String = "a1") -> StageSpans {
    StageSpans(
      sink: recorder,
      clock: FixedClock(instant: Instant(secondsSinceEpoch: 1_700_000_000)),
      tool: "transcribe",
      subsystem: "net.tomelliot.ears",
      category: "transcribe",
      pid: 5330,
      spanID: { id })
  }

  private func field(_ record: LogRecord, _ key: String) -> LogValue? {
    record.fields.first { $0.key == key }?.value
  }

  @Test("emits a start/end pair sharing one span_id")
  func pairsShareASpanID() async {
    let recorder = Recorder()
    await spans(recorder).measure("asr") {}
    let records = recorder.recorded
    #expect(records.map(\.event) == ["stage.start", "stage.end"])
    #expect(field(records[0], "span_id") == .string("a1"))
    #expect(field(records[1], "span_id") == .string("a1"))
    #expect(field(records[0], "stage") == .string("asr"))
  }

  @Test("the end record carries duration_ms")
  func durationOnEnd() async {
    let recorder = Recorder()
    await spans(recorder).measure("asr") {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let end = recorder.recorded[1]
    guard case .double(let ms)? = field(end, "duration_ms") else {
      Issue.record("expected a numeric duration_ms")
      return
    }
    // Real elapsed time, not a wall-clock difference — the injected clock is
    // frozen, so a wall-clock implementation would report exactly 0 here.
    #expect(ms >= 10)
  }

  @Test("supplying audio duration adds rtf, the number that says whether it keeps up")
  func realTimeFactor() async {
    let recorder = Recorder()
    await spans(recorder).measure("asr", audioSeconds: 1000) {}
    let end = recorder.recorded[1]
    guard case .double(let rtf)? = field(end, "rtf") else {
      Issue.record("expected rtf")
      return
    }
    #expect(rtf >= 0)
    #expect(rtf < 0.1)  // a no-op body against 1000s of audio
    #expect(field(end, "audio_seconds") == .double(1000))
  }

  @Test("omits rtf when there is no audio duration to divide by")
  func noRTFWithoutAudio() async {
    let recorder = Recorder()
    await spans(recorder).measure("model_load") {}
    #expect(field(recorder.recorded[1], "rtf") == nil)
  }

  @Test("omits rtf for a zero-length range rather than dividing by zero")
  func zeroAudioSeconds() async {
    let recorder = Recorder()
    await spans(recorder).measure("asr", audioSeconds: 0) {}
    #expect(field(recorder.recorded[1], "rtf") == nil)
  }

  @Test("a throwing stage still reports its timing, at error level, and rethrows")
  func failureStillEnds() async {
    let recorder = Recorder()
    await #expect(throws: Boom.self) {
      try await spans(recorder).measure("asr") { throw Boom() }
    }
    let end = recorder.recorded[1]
    #expect(end.event == "stage.end")
    #expect(end.level == .error)
    #expect(field(end, "status") == .string("error"))
    #expect(field(end, "duration_ms") != nil)
    guard case .string(let message)? = field(end, "error") else {
      Issue.record("expected the failure to be named")
      return
    }
    #expect(message.contains("Boom"))
  }

  @Test("a successful stage ends at info with status ok")
  func successLevel() async {
    let recorder = Recorder()
    await spans(recorder).measure("asr") {}
    #expect(recorder.recorded[1].level == .info)
    #expect(field(recorder.recorded[1], "status") == .string("ok"))
  }

  @Test("session and extra fields ride on both records")
  func contextPropagates() async {
    let recorder = Recorder()
    await spans(recorder).measure(
      "asr", session: "2026-07-27-standup", fields: [LogField("source", .string("mic"))]
    ) {}
    for record in recorder.recorded {
      #expect(field(record, "session") == .string("2026-07-27-standup"))
      #expect(field(record, "source") == .string("mic"))
    }
  }

  @Test("returns the body's value through unchanged")
  func passesValueThrough() async {
    let recorder = Recorder()
    let result = await spans(recorder).measure("asr") { 42 }
    #expect(result == 42)
  }

  @Test("records carry the tool identity the sink was built with")
  func identity() async {
    let recorder = Recorder()
    await spans(recorder).measure("asr") {}
    let end = recorder.recorded[1]
    #expect(end.tool == "transcribe")
    #expect(end.category == "transcribe")
    #expect(end.pid == 5330)
    #expect(end.ts == Instant(secondsSinceEpoch: 1_700_000_000))
  }

  @Test("distinct spans get distinct ids by default")
  func defaultIDsDiffer() async {
    let recorder = Recorder()
    let spans = StageSpans(
      sink: recorder, clock: FixedClock(instant: Instant(secondsSinceEpoch: 0)),
      tool: "t", subsystem: "s", category: "c", pid: 1)
    await spans.measure("a") {}
    await spans.measure("b") {}
    let ids = recorder.recorded.compactMap { record -> String? in
      guard case .string(let value)? = field(record, "span_id") else { return nil }
      return value
    }
    #expect(Set(ids).count == 2)
  }
}
