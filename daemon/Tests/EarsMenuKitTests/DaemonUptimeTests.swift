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
}
