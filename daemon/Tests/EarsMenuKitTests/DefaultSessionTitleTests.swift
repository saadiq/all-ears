import EarsCore
import Foundation
import Testing

@testable import EarsMenuKit

@Suite("DefaultSessionTitle")
struct DefaultSessionTitleTests {
  // 2026-08-05T21:03:07Z — deliberately off a minute boundary so a title that
  // leaked seconds would fail, and 14:03 the same day in Los Angeles.
  let instant = Instant(secondsSinceEpoch: 1_785_963_787)

  @Test("renders the local date and minute, dropping seconds")
  func rendersLocalMinute() {
    let title = DefaultSessionTitle.forManualStart(
      at: instant, timeZone: TimeZone(identifier: "UTC")!)
    #expect(title == "Recording 2026-08-05 21:03")
  }

  @Test("uses the caller's time zone, not UTC")
  func usesGivenTimeZone() {
    let title = DefaultSessionTitle.forManualStart(
      at: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    #expect(title == "Recording 2026-08-05 14:03")
  }
}
