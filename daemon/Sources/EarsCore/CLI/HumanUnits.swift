import Foundation

/// Human-readable units for `ears`'s status/session surfaces: byte counts,
/// durations, wall-clock times, and grouped integers. Pure formatting — the
/// caller supplies the instant and the time zone, so nothing here reads the
/// real clock or the machine's zone (`docs/engineering-practices.md`'s
/// no-wall-clock-in-tests rule).
public enum HumanUnits {
  /// Decimal units (KB = 1000 B, matching what Finder shows the user), one
  /// decimal below ten in the chosen unit: `9.9 MB`, `33 MB`, `999 B`.
  public static func bytes(_ count: Int) -> String {
    let units = ["KB", "MB", "GB", "TB"]
    if count < 1_000 { return "\(count) B" }
    var value = Double(count)
    var unit = "B"
    for next in units {
      guard value >= 1_000 else { break }
      value /= 1_000
      unit = next
    }
    if value < 10 {
      return String(format: "%.1f %@", value, unit)
    }
    return "\(Int(value.rounded())) \(unit)"
  }

  /// `45s`, `26m`, `1h 12m` — minutes-level precision past the first minute,
  /// because these annotate meetings, not benchmarks. Negative clamps to `0s`.
  public static func duration(seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
  }

  /// The local wall time `HH:MM` of `instant` in `timeZone`.
  public static func clock(_ instant: Instant, timeZone: TimeZone) -> String {
    String(UTCCalendar.timeOfDay(shifted(instant, into: timeZone)).prefix(5))
  }

  /// The local civil date `YYYY-MM-DD` of `instant` in `timeZone`.
  public static func localDate(_ instant: Instant, timeZone: TimeZone) -> String {
    UTCCalendar.isoDate(shifted(instant, into: timeZone))
  }

  /// `5,745` — comma-grouped, locale-independent.
  public static func grouped(_ value: Int) -> String {
    let digits = String(value)
    guard value >= 1_000 else { return digits }
    var groups: [String] = []
    var remaining = Substring(digits)
    while remaining.count > 3 {
      groups.append(String(remaining.suffix(3)))
      remaining = remaining.dropLast(3)
    }
    groups.append(String(remaining))
    return groups.reversed().joined(separator: ",")
  }

  /// `instant` shifted so `UTCCalendar`'s UTC field extraction yields the
  /// zone's local fields — DST-correct because the offset is asked of the
  /// zone *at that instant*.
  private static func shifted(_ instant: Instant, into timeZone: TimeZone) -> Instant {
    let offset = timeZone.secondsFromGMT(
      for: Date(timeIntervalSince1970: instant.secondsSinceEpoch))
    return instant.advanced(by: Double(offset))
  }
}
