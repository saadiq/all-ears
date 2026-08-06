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
}
