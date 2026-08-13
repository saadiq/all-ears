import Testing

@testable import EarsCore

@Suite("RosterReconciler")
struct RosterReconcilerTests {
  private static let start = Instant(secondsSinceEpoch: 1_786_544_990)  // 2026-08-12T14:29:50Z

  private static func at(_ offset: Double) -> Instant { start.advanced(by: offset) }

  /// The 2026-08-12 Matthew Barras call, exactly as `session.toml` recorded
  /// it. Two humans; the correlator bound a *remote* browser track to the
  /// local participant's own device id, leaving the one other named attendee
  /// with no audio at all, and the transcript was written under the wrong
  /// person's name for its whole 49 minutes.
  private static func misattributedOneToOne() -> (
    attendees: [SessionAttendee], sources: [SourceID]
  ) {
    let attendees = [
      // You: joined 3s after the session started, because your joining is what
      // started it. The binding below is the impossible one.
      SessionAttendee(
        id: "spaces/wUE9lE2sg5YB/devices/404", displayName: "Tom Elliot", joined: Self.at(3),
        source: SourceID("browser:meet:spaces-wUE9lE2sg5YB-devices-404")),
      SessionAttendee(
        id: "speaker-1", joined: Self.at(53), source: SourceID("browser:meet:speaker-1")),
      SessionAttendee(
        id: "spaces/wUE9lE2sg5YB/devices/403", displayName: "Matthew Barras", joined: Self.at(53)),
      SessionAttendee(
        id: "speaker-2", joined: Self.at(90), source: SourceID("browser:meet:speaker-2")),
    ]
    let sources: [SourceID] = [
      "mic", "browser:meet:speaker-1", "browser:meet:speaker-2",
      "browser:meet:spaces-wUE9lE2sg5YB-devices-404",
    ]
    return (attendees, sources)
  }

  @Test("a remote track bound to the local participant is rejected, not ranked")
  func rejectsLocalBinding() {
    let (attendees, sources) = Self.misattributedOneToOne()
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start)

    #expect(!outcome.speakers.contains { $0.name == "Tom Elliot" })
    #expect(outcome.warnings.contains { $0.contains("browser capture only ever records") })
  }

  @Test("every remote track on a one-to-one call resolves to the only other participant")
  func assignsTheOnlyRemote() {
    let (attendees, sources) = Self.misattributedOneToOne()
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start)

    // Including the track that was mislabelled as the local user: dropping
    // that binding returns its source to the pool, and counting settles it.
    #expect(
      Set(outcome.speakers.map(\.source.rawValue)) == [
        "browser:meet:speaker-1", "browser:meet:speaker-2",
        "browser:meet:spaces-wUE9lE2sg5YB-devices-404",
      ])
    #expect(outcome.speakers.allSatisfy { $0.name == "Matthew Barras" })
    // `mic` is the local participant by construction and is never assigned.
    #expect(!outcome.speakers.contains { $0.source == SourceID("mic") })
  }

  @Test("the local participant is inferred from join order when nobody reports it")
  func infersLocalFromJoinOrder() {
    let (attendees, sources) = Self.misattributedOneToOne()
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start)

    #expect(outcome.localAttendeeID == "spaces/wUE9lE2sg5YB/devices/404")
    #expect(outcome.localResolution == RosterReconciler.LocalResolution.inferred)
  }

  @Test("a reported local participant outranks the join-order inference")
  func reportedLocalWins() {
    var (attendees, sources) = Self.misattributedOneToOne()
    // Whoever the join times point at, the client's own answer is the one
    // that stands — it read the platform's marker rather than a heuristic.
    attendees[2].isLocal = true
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start)

    #expect(outcome.localAttendeeID == "spaces/wUE9lE2sg5YB/devices/403")
    #expect(outcome.localResolution == RosterReconciler.LocalResolution.reported)
  }

  @Test("joining a call already in progress leaves the local participant unknown")
  func ambiguousJoinsInferNothing() {
    // Everyone lands in the same burst, so join order distinguishes nobody.
    let attendees = [
      SessionAttendee(
        id: "a", displayName: "Ana", joined: Self.at(2), source: SourceID("browser:x:a")),
      SessionAttendee(id: "b", displayName: "Ben", joined: Self.at(3)),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:x:a"], sessionStart: Self.start)

    #expect(outcome.localAttendeeID == nil)
    #expect(outcome.localResolution == RosterReconciler.LocalResolution.unknown)
    // And it says so, rather than quietly not applying the invariant.
    #expect(
      outcome.warnings.contains { $0.contains("could not identify which roster entry is you") })
  }

  @Test("with two remote participants an unmatched track is left unnamed, not guessed")
  func refusesToGuessAmongMany() {
    let attendees = [
      SessionAttendee(id: "me", displayName: "Tom Elliot", joined: Self.at(1), isLocal: true),
      SessionAttendee(
        id: "a", displayName: "Ana", joined: Self.at(60), source: SourceID("browser:x:a")),
      SessionAttendee(id: "b", displayName: "Ben", joined: Self.at(70)),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:x:a", "browser:x:unknown"],
      sessionStart: Self.start)

    #expect(outcome.speakers.count == 1)
    #expect(outcome.speakers.first?.name == "Ana")
    #expect(outcome.warnings.contains { $0.contains("could not be matched to any of 2") })
  }

  @Test("a correlated binding that survives is marked as correlated, an assigned one as inferred")
  func recordsHowEachNameWasEstablished() {
    let (attendees, sources) = Self.misattributedOneToOne()
    var withGoodBinding = attendees
    withGoodBinding[2].source = SourceID("browser:meet:speaker-2")
    let outcome = RosterReconciler.reconcile(
      attendees: withGoodBinding, sources: sources, sessionStart: Self.start)

    let bySource = Dictionary(
      uniqueKeysWithValues: outcome.speakers.map { ($0.source.rawValue, $0.confidence) })
    #expect(bySource["browser:meet:speaker-2"] == SpeakerConfidence.correlated)
    #expect(bySource["browser:meet:speaker-1"] == SpeakerConfidence.inferred)
  }

  @Test("a named participant nobody heard is reported rather than passed over")
  func reportsSilentAttendees() {
    let attendees = [
      SessionAttendee(id: "me", displayName: "Tom Elliot", joined: Self.at(1), isLocal: true),
      SessionAttendee(id: "a", displayName: "Ana", joined: Self.at(60)),
      SessionAttendee(id: "b", displayName: "Ben", joined: Self.at(70)),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic"], sessionStart: Self.start)

    #expect(outcome.warnings.contains { $0.contains("Ana was on the roster but no audio") })
    #expect(outcome.warnings.contains { $0.contains("Ben was on the roster but no audio") })
  }

  @Test("a title is derived from everyone but you")
  func derivesTitle() {
    let (attendees, _) = Self.misattributedOneToOne()
    let title = RosterReconciler.derivedTitle(
      attendees: attendees, localAttendeeID: "spaces/wUE9lE2sg5YB/devices/404")

    #expect(title == "Matthew Barras")
  }

  @Test("a roster that names nobody derives no title")
  func derivesNoTitleFromAnEmptyRoster() {
    #expect(RosterReconciler.derivedTitle(attendees: [], localAttendeeID: nil) == nil)
    #expect(
      RosterReconciler.derivedTitle(
        attendees: [SessionAttendee(id: "me", displayName: "Tom", isLocal: true)],
        localAttendeeID: "me") == nil)
  }

  @Test("one participant seen under several ids is one participant")
  func dedupesByName() {
    // A rejoin, or an identity upgrade, puts the same human on the roster
    // twice. Counted as two, it would block the one-remote assignment the
    // call actually qualifies for.
    let attendees = [
      SessionAttendee(id: "me", displayName: "Tom Elliot", joined: Self.at(1), isLocal: true),
      SessionAttendee(id: "a1", displayName: "Ana", joined: Self.at(60)),
      SessionAttendee(id: "a2", displayName: "Ana", joined: Self.at(90)),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:x:1"], sessionStart: Self.start)

    #expect(outcome.speakers.map(\.name) == ["Ana"])
  }
}
