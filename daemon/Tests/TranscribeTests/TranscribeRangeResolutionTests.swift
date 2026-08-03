import EarsCore
import Testing

@testable import transcribe

@Suite("TranscribeRangeResolution")
struct TranscribeRangeResolutionTests {
  private let now = Instant(secondsSinceEpoch: 1_784_284_200)

  private func resolve(
    last: String? = nil, from: String? = nil, to: String? = nil
  ) -> Result<TimeRange, TranscribeRangeResolution.RangeError> {
    TranscribeRangeResolution.resolve(last: last, from: from, to: to, now: now)
  }

  // MARK: - --last

  @Test("--last 20m resolves to a range ending now, 20 minutes long")
  func lastResolvesRangeEndingNow() {
    let result = resolve(last: "20m")
    #expect(result == .success(TimeRange(start: now.advanced(by: -1200), end: now)))
  }

  @Test("--last 2h resolves correctly")
  func lastHoursResolves() {
    let result = resolve(last: "2h")
    #expect(result == .success(TimeRange(start: now.advanced(by: -7200), end: now)))
  }

  @Test("nothing at all is an error naming that no range was specified")
  func noneIsError() {
    let result = resolve()
    #expect(result == .failure(.noRangeSpecified))
  }

  @Test("a malformed --last value is an error")
  func malformedLastIsError() {
    let result = resolve(last: "not-a-duration")
    guard case .failure(.invalidDuration) = result else {
      Issue.record("expected .invalidDuration, got \(result)")
      return
    }
  }

  @Test("--last 0m is an error naming the range as empty")
  func zeroLastIsEmptyRangeError() {
    let result = resolve(last: "0m")
    #expect(result == .failure(.emptyRange))
  }

  // MARK: - --from/--to

  @Test("--from/--to resolves an explicit ISO-8601 range")
  func fromToResolves() {
    let result = resolve(from: "2026-07-17T10:30:00Z", to: "2026-07-17T11:02:00Z")
    #expect(
      result
        == .success(
          TimeRange(
            start: Instant(secondsSinceEpoch: 1_784_284_200),
            end: Instant(secondsSinceEpoch: 1_784_286_120))))
  }

  @Test("--from without --to is an error")
  func fromWithoutToIsError() {
    #expect(resolve(from: "2026-07-17T10:30:00Z") == .failure(.incompleteFromTo))
  }

  @Test("--to without --from is an error")
  func toWithoutFromIsError() {
    #expect(resolve(to: "2026-07-17T11:02:00Z") == .failure(.incompleteFromTo))
  }

  @Test("a malformed --from value names the offending field")
  func malformedFromIsError() {
    let result = resolve(from: "not-a-timestamp", to: "2026-07-17T11:02:00Z")
    #expect(result == .failure(.invalidTimestamp(field: "from", value: "not-a-timestamp")))
  }

  @Test("--from after --to is an empty-range error")
  func fromAfterToIsEmptyRange() {
    let result = resolve(from: "2026-07-17T11:02:00Z", to: "2026-07-17T10:30:00Z")
    #expect(result == .failure(.emptyRange))
  }

  // MARK: - Mutual exclusivity

  @Test("--last and --from/--to together is an error")
  func lastAndFromToTogetherIsError() {
    let result = resolve(last: "20m", from: "2026-07-17T10:30:00Z", to: "2026-07-17T11:02:00Z")
    #expect(result == .failure(.multipleRangeSourcesSpecified))
  }
}
