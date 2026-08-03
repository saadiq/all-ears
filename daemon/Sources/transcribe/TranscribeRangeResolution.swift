import EarsCore

/// Resolves `transcribe`'s raw range flags (`--last`, `--from`/`--to`, per
/// `docs/specs/transcribe.md`'s CLI) into a wall-clock ``TimeRange``. The
/// entity path is `--session`, which names its own intervals and never
/// reaches this resolver (``TranscribePipeline`` reads the session record
/// directly).
///
/// Pure and clock-injected -- no wall-clock read here -- per
/// `docs/engineering-practices.md`'s "no wall-clock time in tests" rule;
/// ``TranscribeRuntime``/``TranscribePipeline`` supply the real `now` via
/// `NowProviding`, tests supply a fixed ``Instant`` directly.
enum TranscribeRangeResolution {
  enum RangeError: Error, Equatable, CustomStringConvertible {
    /// Neither `--last` nor `--from`/`--to` was given.
    case noRangeSpecified
    /// Both `--last` and `--from`/`--to` were given.
    case multipleRangeSourcesSpecified
    /// Only one of `--from`/`--to` was given; both are required together.
    case incompleteFromTo
    /// `--from`/`--to`'s value didn't parse as an ISO-8601 UTC timestamp.
    case invalidTimestamp(field: String, value: String)
    /// `--last`'s value didn't parse as a duration.
    case invalidDuration(String)
    /// The resolved range has zero or negative length.
    case emptyRange

    var description: String {
      switch self {
      case .noRangeSpecified:
        return "no range specified: pass --last <duration>, --from/--to, or --session <id>"
      case .multipleRangeSourcesSpecified:
        return "specify only one of --last, --from/--to, or --session"
      case .incompleteFromTo:
        return "--from and --to must both be given together"
      case .invalidTimestamp(let field, let value):
        return "--\(field) is not a valid ISO-8601 UTC timestamp: '\(value)'"
      case .invalidDuration(let detail):
        return detail
      case .emptyRange:
        return "requested range is empty"
      }
    }
  }

  static func resolve(
    last: String?,
    from: String?,
    to: String?,
    now: Instant
  ) -> Result<TimeRange, RangeError> {
    let specifiedCount = [last != nil, from != nil || to != nil]
      .filter { $0 }.count
    guard specifiedCount <= 1 else { return .failure(.multipleRangeSourcesSpecified) }

    if from != nil || to != nil {
      return resolveFromTo(from: from, to: to)
    }
    return resolveLast(last, now: now)
  }

  private static func resolveFromTo(from: String?, to: String?) -> Result<TimeRange, RangeError> {
    guard let from, let to else { return .failure(.incompleteFromTo) }
    guard let start = ISO8601InstantCodec.parse(from) else {
      return .failure(.invalidTimestamp(field: "from", value: from))
    }
    guard let end = ISO8601InstantCodec.parse(to) else {
      return .failure(.invalidTimestamp(field: "to", value: to))
    }
    guard start < end else { return .failure(.emptyRange) }
    return .success(TimeRange(start: start, end: end))
  }

  private static func resolveLast(_ last: String?, now: Instant) -> Result<TimeRange, RangeError> {
    guard let last else { return .failure(.noRangeSpecified) }
    switch DurationParsing.seconds(from: last) {
    case .failure(let parseError):
      return .failure(.invalidDuration(parseError.description))
    case .success(let seconds):
      guard seconds > 0 else { return .failure(.emptyRange) }
      return .success(TimeRange(start: now.advanced(by: -seconds), end: now))
    }
  }
}
