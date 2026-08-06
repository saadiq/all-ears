import EarsCore

/// The daemon's uptime, kept as an anchored value rather than a number that
/// has to be re-fetched to stay true.
///
/// `status` answers "how long has earsd been up" once, at the moment it is
/// asked. Storing that answer freezes it: a menu opened an hour later still
/// reports the uptime the app happened to read at launch. Storing *when* the
/// answer was true makes the current value derivable from the clock, so
/// refreshing the line costs no socket round-trip — which matters because the
/// refresh has to complete before the menu draws, and an async round-trip
/// lands after.
public struct DaemonUptime: Sendable, Hashable {
  /// The uptime the daemon reported, in seconds.
  public var reported: Double
  /// The local instant at which `reported` was true.
  public var anchor: Instant

  public init(reported: Double, anchor: Instant) {
    self.reported = reported
    self.anchor = anchor
  }

  /// The uptime now. A clock that moved backwards (NTP correction, sleep)
  /// clamps to `reported` rather than reporting a daemon that got younger.
  public func seconds(at now: Instant) -> Double {
    reported + max(0, now.secondsSinceEpoch - anchor.secondsSinceEpoch)
  }
}
