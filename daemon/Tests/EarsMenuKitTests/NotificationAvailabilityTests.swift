import Testing

@testable import EarsMenuKit

@Suite("NotificationAvailability")
struct NotificationAvailabilityTests {
  @Test("a denied grant says what the user loses, not that an API call failed")
  func deniedNamesTheCost() {
    #expect(
      NotificationAvailability.denied.menuLine == "⚠ Notifications are off — no summary alerts")
  }

  @Test("the quiet cases stay quiet")
  func quietCases() {
    // Authorized is the happy path. Unsupported is a bare `swift run` binary
    // with no bundle, where notifications were never on offer — warning about
    // a grant the user cannot give would be noise in the one build that is
    // developer-only anyway.
    #expect(NotificationAvailability.authorized.menuLine == nil)
    #expect(NotificationAvailability.unsupported.menuLine == nil)
  }
}
