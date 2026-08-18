import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("DaemonUptime")
struct DaemonUptimeTests {
  @Test("uptime advances with the clock rather than staying at what status reported")
  func advancesWithTheClock() {
    let uptime = DaemonUptime(reported: 6, anchor: instant(1_000))
    #expect(uptime.seconds(at: instant(1_000)) == 6)
    #expect(uptime.seconds(at: instant(1_600)) == 606)
  }

  @Test("a clock that jumps backwards never makes the daemon younger")
  func clampsBackwardsClock() {
    let uptime = DaemonUptime(reported: 90, anchor: instant(1_000))
    #expect(uptime.seconds(at: instant(400)) == 90)
  }

  @Test("the status line claims an uptime only when one was anchored")
  func lineOmitsUnanchoredUptime() {
    let uptime = DaemonUptime(reported: 60, anchor: instant(1_000))
    #expect(
      DaemonUptime.line(daemon: "earsd/0.1.0", uptime: uptime, now: instant(1_060))
        == "earsd/0.1.0 · up 2m")
    // An anchor is only valid for the process it was read from. A caller that
    // could not re-anchor — a failed `status` after a restart, or a daemon
    // that just died — must drop it: counting on from the *previous* process's
    // figure told a user who had just clicked Restart Daemon that nothing
    // happened.
    #expect(
      DaemonUptime.line(daemon: "earsd/0.1.0", uptime: nil, now: instant(1_060))
        == "earsd/0.1.0")
    #expect(DaemonUptime.line(daemon: nil, uptime: uptime, now: instant(1_060)) == "Not connected")
  }

  /// The line speaks `ears status`'s vocabulary (``HumanUnits/duration``), so
  /// the same daemon reads the same age in the menu and on the CLI: hours run
  /// past a day rather than splitting into a `d` tier, and a whole hour is
  /// bare.
  @Test("uptime is rendered in the CLI's units")
  func lineUsesCLIUnits() {
    let long = DaemonUptime(reported: 0, anchor: instant(1_000))
    #expect(
      DaemonUptime.line(daemon: "earsd/0.1.0", uptime: long, now: instant(1_000 + 93_600))
        == "earsd/0.1.0 · up 26h")
    let whole = DaemonUptime(reported: 10_800, anchor: instant(1_000))
    #expect(
      DaemonUptime.line(daemon: "earsd/0.1.0", uptime: whole, now: instant(1_000))
        == "earsd/0.1.0 · up 3h")
  }
}
