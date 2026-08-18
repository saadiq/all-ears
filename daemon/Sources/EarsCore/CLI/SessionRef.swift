import Foundation

/// Resolves the `<ref>` argument of `ears session show` against a session
/// list: a unique session-id prefix, a start time `HH:MM` (today, in the
/// caller's zone), or a case-insensitive title fragment — tried in that
/// order, with the first form that matches anything deciding the outcome, so
/// an ambiguous answer names candidates of one kind rather than a mixed bag.
public enum SessionRef {
  public enum Resolution: Equatable {
    case match(Session)
    /// More than one candidate — surfaced to the user to disambiguate.
    case ambiguous([Session])
    case notFound
  }

  public static func resolve(
    _ ref: String, in sessions: [Session], now: Instant, timeZone: TimeZone
  ) -> Resolution {
    let lowered = ref.lowercased()

    let byID = sessions.filter { $0.id.lowercased().hasPrefix(lowered) }
    if let exact = byID.first(where: { $0.id.lowercased() == lowered }) {
      return .match(exact)
    }
    if !byID.isEmpty { return decided(byID) }

    if let clock = normalizedClock(ref) {
      let localToday = HumanUnits.localDate(now, timeZone: timeZone)
      let byStart = sessions.filter {
        HumanUnits.localDate($0.started, timeZone: timeZone) == localToday
          && HumanUnits.clock($0.started, timeZone: timeZone) == clock
      }
      if !byStart.isEmpty { return decided(byStart) }
    }

    let byTitle = sessions.filter { $0.title.lowercased().contains(lowered) }
    if !byTitle.isEmpty { return decided(byTitle) }

    return .notFound
  }

  private static func decided(_ candidates: [Session]) -> Resolution {
    candidates.count == 1 ? .match(candidates[0]) : .ambiguous(candidates)
  }

  /// `"8:05"` → `"08:05"`; anything not shaped like `H:MM`/`HH:MM` → `nil`.
  private static func normalizedClock(_ ref: String) -> String? {
    let parts = ref.split(separator: ":")
    guard parts.count == 2,
      parts[0].count <= 2, parts[1].count == 2,
      parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
    else { return nil }
    let hour = parts[0].count == 1 ? "0\(parts[0])" : String(parts[0])
    return "\(hour):\(parts[1])"
  }
}
