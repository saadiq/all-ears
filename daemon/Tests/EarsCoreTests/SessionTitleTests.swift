import Testing

@testable import EarsCore

/// ``Session/defaultTitle(identity:started:)`` and
/// ``Session/hasDefaultTitle`` — the recompute-and-compare title-precedence
/// scheme. The regression pinned here: a manual session's default title must
/// be derived from its own start instant, not a shared constant, so manual
/// sessions are distinguishable in every listing and note that interpolates
/// the title.
@Suite("Session titles")
struct SessionTitleTests {
  private static let started = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private static func manualSession(title: String) -> Session {
    Session(id: "m1", title: title, state: .active, started: started)
  }

  @Test("a manual session's default title carries its start time")
  func manualDefaultTitleCarriesStart() {
    #expect(
      Session.defaultTitle(identity: nil, started: Self.started) == "session 2026-07-17 10:30")
  }

  @Test("two manual sessions started at different times do not share a default title")
  func manualDefaultTitlesAreDistinct() {
    let later = Self.started.advanced(by: 3600)
    #expect(
      Session.defaultTitle(identity: nil, started: Self.started)
        != Session.defaultTitle(identity: nil, started: later))
  }

  @Test("an identity session's default title is unchanged by the start instant")
  func identityDefaultTitleIgnoresStart() {
    let identity = SessionIdentity(platform: "meet", externalID: "wUE9lE2sg5YB")
    #expect(Session.defaultTitle(identity: identity, started: Self.started) == "meet wUE9lE2sg5YB")
  }

  @Test("a manual session still carrying its stamped default is detected as unnamed")
  func stampedDefaultIsDetected() {
    let session = Self.manualSession(
      title: Session.defaultTitle(identity: nil, started: Self.started))
    #expect(session.hasDefaultTitle)
  }

  @Test("a manual session's real title is not mistaken for the default")
  func realTitleSurvivesDetection() {
    #expect(!Self.manualSession(title: "Interview with Bob").hasDefaultTitle)
    // The pre-fix constant: a session titled with the old shared default is a
    // *named* session now — nothing may overwrite it.
    #expect(!Self.manualSession(title: "session").hasDefaultTitle)
  }
}
