/// Which week-of-year convention ``PathTemplate``'s `{week}` token renders,
/// selected by the top-level `week_numbering` config key.
///
/// The two conventions genuinely disagree — a January date can be week 01
/// under one and week 53 (of the *previous* year) under the other — so the
/// choice is explicit rather than guessed:
///
/// - ``us`` — weeks start on Sunday and week 1 is the week containing
///   January 1. This is moment.js/Obsidian's `ww` under the default `en`
///   locale, which is why it is the default here: a vault whose daily-note
///   paths already carry `ww` should keep filing transcripts alongside them.
/// - ``iso`` — ISO-8601: weeks start on Monday and week 1 is the week
///   containing the first Thursday of the year.
///
/// Note that `{week}` is computed independently of `{year}`: an ISO week
/// belonging to the previous year (2027-01-01 is ISO week 53 of 2026) still
/// renders next to `{year}` = 2027. That is the convention's own mismatch,
/// not a bug — a template mixing the two should use `{date}` if it needs
/// them to agree.
public enum WeekNumbering: String, Sendable, Hashable, CaseIterable {
  case us
  case iso

  /// Parses the config spelling; anything unrecognised is ``us`` (the
  /// default). Config validation rejects unknown spellings before this is
  /// reached, so the fallback only covers a caller bypassing validation.
  public init(configValue: String) {
    self = WeekNumbering(rawValue: configValue) ?? .us
  }

  /// The week-of-year number for `instant` under this convention.
  public func week(of instant: Instant) -> Int {
    let civil = UTCCalendar.civilTime(for: instant)
    let epochDay = UTCCalendar.daysFromCivil(
      year: civil.year, month: civil.month, day: civil.day)
    let januaryFirst = UTCCalendar.daysFromCivil(year: civil.year, month: 1, day: 1)
    let ordinalDay = epochDay - januaryFirst + 1

    switch self {
    case .us:
      // Weeks start on Sunday, week 1 contains January 1: shift the ordinal
      // day by how far into its week January 1 already was.
      let januaryFirstWeekday = sundayBasedWeekday(epochDay: januaryFirst)
      return (ordinalDay + januaryFirstWeekday - 1) / 7 + 1
    case .iso:
      let isoWeekday = mondayBasedWeekday(epochDay: epochDay)
      let week = (ordinalDay - isoWeekday + 10) / 7
      if week < 1 { return Self.isoWeeksInYear(civil.year - 1) }
      if week > Self.isoWeeksInYear(civil.year) { return 1 }
      return week
    }
  }

  /// 0 = Sunday … 6 = Saturday. Epoch day 0 (1970-01-01) was a Thursday.
  private func sundayBasedWeekday(epochDay: Int) -> Int {
    ((epochDay + 4) % 7 + 7) % 7
  }

  /// 1 = Monday … 7 = Sunday (ISO-8601's own weekday numbering).
  private func mondayBasedWeekday(epochDay: Int) -> Int {
    ((epochDay + 3) % 7 + 7) % 7 + 1
  }

  /// 52 or 53, per ISO-8601: a year has 53 weeks when it starts on a
  /// Thursday, or is a leap year starting on a Wednesday.
  private static func isoWeeksInYear(_ year: Int) -> Int {
    func p(_ y: Int) -> Int {
      let value = y + y / 4 - y / 100 + y / 400
      return ((value % 7) + 7) % 7
    }
    return 52 + (p(year) == 4 || p(year - 1) == 3 ? 1 : 0)
  }
}
