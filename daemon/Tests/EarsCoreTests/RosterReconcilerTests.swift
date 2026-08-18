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

  @Test("a self flag contradicted by a remote binding and join order is revised")
  func revisesContradictedLocalFlag() {
    // The wrong latch: the remote participant got flagged as you, and their
    // (correct) track binding now looks like the impossible state invariant 1
    // exists to reject. The flag is contradicted on both fronts — the flagged
    // row is bound to remote audio, and join order singles out somebody else
    // as the one whose arrival started the session — so the flag is revised,
    // not the binding dropped.
    let attendees = [
      SessionAttendee(id: "tom", displayName: "Tom Elliot", joined: Self.at(3)),
      SessionAttendee(
        id: "matt", displayName: "Matthew Barras", joined: Self.at(53),
        source: SourceID("browser:meet:matt"), isLocal: true),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:meet:matt"], sessionStart: Self.start)

    #expect(outcome.localAttendeeID == "tom")
    #expect(outcome.localResolution == RosterReconciler.LocalResolution.revised)
    // The evidence for the revision travels in the warnings…
    #expect(
      outcome.warnings.contains {
        $0.contains("marked Matthew Barras as you") && $0.contains("browser:meet:matt")
      })
    // …and the correct binding survives instead of being dropped, so the
    // whole call is no longer misattributed by one wrong flag (the failure
    // the irreversible latch made permanent).
    #expect(
      outcome.speakers.contains {
        $0.source == SourceID("browser:meet:matt") && $0.name == "Matthew Barras"
      })
  }

  @Test("a contradicted self flag stands when join order distinguishes nobody")
  func keepsContradictedFlagWithoutJoinEvidence() {
    // The flagged row is bound to remote audio, but everyone joined in the
    // same burst — half the evidence is missing, so the conservative answer
    // is today's: keep the reported flag, drop the impossible binding.
    let attendees = [
      SessionAttendee(id: "tom", displayName: "Tom Elliot", joined: Self.at(3)),
      SessionAttendee(
        id: "matt", displayName: "Matthew Barras", joined: Self.at(5),
        source: SourceID("browser:meet:matt"), isLocal: true),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:meet:matt"], sessionStart: Self.start)

    #expect(outcome.localAttendeeID == "matt")
    #expect(outcome.localResolution == RosterReconciler.LocalResolution.reported)
    #expect(!outcome.speakers.contains { $0.name == "Matthew Barras" })
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

  @Test("two attendees claiming one source keep the roster's first claimant, with a warning")
  func duplicateSourceClaimsResolveDeterministically() {
    // Both Ana and Ben claim browser:x:1. Before this invariant the map held
    // two rows and transcribe's source→name dictionary silently kept
    // whichever landed last; roster order (the order the claims arrived)
    // decides the same way on every re-run.
    let attendees = [
      SessionAttendee(id: "me", displayName: "Tom Elliot", joined: Self.at(1), isLocal: true),
      SessionAttendee(
        id: "a", displayName: "Ana", joined: Self.at(60), source: SourceID("browser:x:1")),
      SessionAttendee(
        id: "b", displayName: "Ben", joined: Self.at(70), source: SourceID("browser:x:1")),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:x:1"], sessionStart: Self.start)

    #expect(outcome.speakers.filter { $0.source == SourceID("browser:x:1") }.map(\.name) == ["Ana"])
    #expect(
      outcome.warnings.contains {
        $0.contains("claimed by") && $0.contains("Ana") && $0.contains("Ben")
      })
  }

  @Test("one human claiming a source under two roster rows is one claim, not a conflict")
  func duplicateClaimsSharingANameCoalesce() {
    // A rejoin puts the same person on the roster twice, both rows bound to
    // the surviving track. That is agreement — one speaker row, no warning.
    let attendees = [
      SessionAttendee(id: "me", displayName: "Tom Elliot", joined: Self.at(1), isLocal: true),
      SessionAttendee(
        id: "a1", displayName: "Ana", joined: Self.at(60), source: SourceID("browser:x:1")),
      SessionAttendee(
        id: "a2", displayName: "Ana", joined: Self.at(90), source: SourceID("browser:x:1")),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:x:1"], sessionStart: Self.start)

    #expect(
      outcome.speakers == [
        SessionSpeaker(source: SourceID("browser:x:1"), name: "Ana", confidence: .correlated)
      ])
    #expect(!outcome.warnings.contains { $0.contains("claimed by") })
  }

  @Test("a named synthetic row never blocks the one-remote inference (B7)")
  func syntheticRowsDoNotBlockCounting() {
    // One real remote (Ana, platform-origin) plus a junk row: a synthetic
    // stand-in that somehow acquired a display name. Counted as a second
    // remote it would raise remoteNames.count above 1 and block invariant 2;
    // its origin says it names a track, not a person, so it never counts.
    let attendees = [
      SessionAttendee(id: "me", displayName: "Tom Elliot", joined: Self.at(1), isLocal: true),
      SessionAttendee(
        id: "a", displayName: "Ana", joined: Self.at(60), origin: .platform),
      SessionAttendee(
        id: "webaudio-track-2", displayName: "Meet junk", joined: Self.at(61),
        origin: .synthetic),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:x:unassigned"], sessionStart: Self.start)

    #expect(
      outcome.speakers == [
        SessionSpeaker(source: SourceID("browser:x:unassigned"), name: "Ana", confidence: .inferred)
      ])
  }

  @Test("a named unknown-origin row still blocks the inference (old rosters)")
  func unknownOriginRowsCountAsToday() {
    // Same shape, but the junk row predates provenance (origin nil). It is
    // indistinguishable from a real second participant, so the counts force
    // nothing — exactly the pre-origin behaviour, preserved for old files.
    let attendees = [
      SessionAttendee(id: "me", displayName: "Tom Elliot", joined: Self.at(1), isLocal: true),
      SessionAttendee(id: "a", displayName: "Ana", joined: Self.at(60), origin: .platform),
      SessionAttendee(id: "webaudio-track-2", displayName: "Meet junk", joined: Self.at(61)),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:x:unassigned"], sessionStart: Self.start)

    #expect(outcome.speakers.isEmpty)
    #expect(outcome.warnings.contains { $0.contains("could not be matched to any of 2") })
  }

  @Test("a named synthetic row is left out of the derived title")
  func syntheticRowsAreLeftOutOfTitles() {
    let attendees = [
      SessionAttendee(id: "me", displayName: "Tom Elliot", isLocal: true),
      SessionAttendee(id: "a", displayName: "Ana", origin: .platform),
      SessionAttendee(id: "speaker-3", displayName: "Meet junk", origin: .synthetic),
    ]
    #expect(RosterReconciler.derivedTitle(attendees: attendees, localAttendeeID: "me") == "Ana")
  }

  @Test("calendar attendees count as named people and produce no speaker bindings for app sessions")
  func calendarAttendeesAreRosterOnly() {
    let outcome = RosterReconciler.reconcile(
      attendees: [
        SessionAttendee(id: "calendar-0", displayName: "Saadiq", origin: .calendar, isLocal: true),
        SessionAttendee(id: "calendar-1", displayName: "Priya", origin: .calendar),
      ],
      sources: [SourceID("mic"), SourceID("app:us.zoom.xos")],
      sessionStart: Self.start)

    #expect(outcome.speakers.isEmpty)
    let title = RosterReconciler.derivedTitle(
      attendees: [
        SessionAttendee(id: "calendar-0", displayName: "Saadiq", origin: .calendar, isLocal: true),
        SessionAttendee(id: "calendar-1", displayName: "Priya", origin: .calendar),
      ],
      localAttendeeID: "calendar-0")
    #expect(title?.contains("Priya") == true)
  }

  @Test("a session with no per-participant capture never warns about an unheard attendee")
  func appSessionsDoNotWarnAboutUnheardAttendees() {
    // Native Zoom/Teams/Slack capture is one mixed stream on `app:*`: every
    // remote voice shares it, so an invitee can never be matched to audio.
    // The warning would stand on every such session and nothing could ever
    // satisfy it.
    let outcome = RosterReconciler.reconcile(
      attendees: [
        SessionAttendee(id: "calendar-0", displayName: "Saadiq", origin: .calendar, isLocal: true),
        SessionAttendee(id: "calendar-1", displayName: "Priya", origin: .calendar),
        SessionAttendee(id: "calendar-2", displayName: "Wei Zhang", origin: .calendar),
      ],
      sources: [SourceID("mic"), SourceID("app:us.zoom.xos")],
      sessionStart: Self.start)

    #expect(outcome.warnings.isEmpty)
  }

  @Test("excluding synthetic rows from counting is a new derivation — the version says so")
  func countingChangeBumpedTheVersion() {
    // The same roster can now produce a different map (the two tests above),
    // which is the documented trigger for a bump: transcribe re-derives any
    // stored map older than this, repairing sessions reconciled under v1.
    #expect(RosterReconciler.version >= 2)
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

  // ── Attribution-log binding hints (R3: track-scoped sources) ────────────

  /// Three-person call with track-handle sources: counting can force nothing,
  /// so every assignment below is the hints' doing.
  private static func trackScopedCall() -> (attendees: [SessionAttendee], sources: [SourceID]) {
    let attendees = [
      SessionAttendee(
        id: "devices/1", displayName: "Tom Elliot", joined: Self.at(2), origin: .platform,
        isLocal: true),
      SessionAttendee(
        id: "devices/2", displayName: "Ana Flores", joined: Self.at(40), origin: .platform),
      SessionAttendee(
        id: "devices/3", displayName: "Bram Okafor", joined: Self.at(45), origin: .platform),
      SessionAttendee(id: "t1", joined: Self.at(41), origin: .synthetic),
      SessionAttendee(id: "t2", joined: Self.at(46), origin: .synthetic),
    ]
    let sources: [SourceID] = ["mic", "browser:meet:t1", "browser:meet:t2"]
    return (attendees, sources)
  }

  private static func hint(
    _ captureId: String, _ attendeeID: String, t: Double, correlator: String? = "dom"
  ) -> AttributionBindingHint {
    AttributionBindingHint(
      captureId: captureId, attendeeID: attendeeID, trackId: "trk-\(captureId)", t: t,
      correlator: correlator, confirmations: correlator == nil ? nil : 2)
  }

  @Test("binding hints name track-handle sources the roster's links never carried")
  func hintsNameSources() {
    let (attendees, sources) = Self.trackScopedCall()
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start,
      hints: [
        Self.hint("t1", "devices/2", t: 1000),
        Self.hint("t2", "devices/3", t: 2000),
      ])

    #expect(
      outcome.speakers.map { "\($0.source.rawValue)→\($0.name)" } == [
        "browser:meet:t1→Ana Flores", "browser:meet:t2→Bram Okafor",
      ])
    #expect(outcome.speakers.allSatisfy { $0.confidence == .correlated })
  }

  @Test(
    "multiple hints can name several sources for one attendee — the rejoin the roster link loses")
  func multipleHintsPerAttendee() {
    var (attendees, sources) = Self.trackScopedCall()
    sources.append("browser:meet:t3")
    attendees.append(SessionAttendee(id: "t3", joined: Self.at(300), origin: .synthetic))
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start,
      hints: [
        Self.hint("t1", "devices/2", t: 1000),
        Self.hint("t2", "devices/3", t: 2000),
        // Ana rejoined on a fresh track; the roster's single source field
        // would have kept only this last link.
        Self.hint("t3", "devices/2", t: 3000),
      ])

    #expect(
      Set(outcome.speakers.filter { $0.name == "Ana Flores" }.map(\.source.rawValue)) == [
        "browser:meet:t1", "browser:meet:t3",
      ])
  }

  @Test("a hint binding remote audio to the local participant is dropped (invariant 1)")
  func hintsToLocalAreDropped() {
    let (attendees, sources) = Self.trackScopedCall()
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start,
      hints: [Self.hint("t1", "devices/1", t: 1000)])

    #expect(!outcome.speakers.contains { $0.name == "Tom Elliot" })
    #expect(outcome.warnings.contains { $0.contains("browser capture only ever records") })
  }

  @Test("a hint never outranks the roster's own claim on a source (invariant 3)")
  func rosterClaimBeatsHint() {
    var (attendees, sources) = Self.trackScopedCall()
    // The roster's own link says t1 is Ana; a stray hint claims Bram.
    attendees[1].source = SourceID("browser:meet:t1")
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start,
      hints: [Self.hint("t1", "devices/3", t: 1000)])

    #expect(
      outcome.speakers.contains {
        $0.source == SourceID("browser:meet:t1") && $0.name == "Ana Flores"
      })
    #expect(
      !outcome.speakers.contains {
        $0.source == SourceID("browser:meet:t1") && $0.name == "Bram Okafor"
      })
    #expect(outcome.warnings.contains { $0.contains("claimed by both") })
  }

  @Test("a hint naming an attendee the roster never named contributes nothing")
  func hintsToNamelessAttendeesAreIgnored() {
    let (attendees, sources) = Self.trackScopedCall()
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start,
      hints: [Self.hint("t1", "devices/99", t: 1000)])

    #expect(outcome.speakers.isEmpty)
  }

  @Test("hints match sources whose label suffix needed sanitising (older capture ids)")
  func hintsMatchSanitisedSuffixes() {
    // Pre-R3 logs can carry capture ids in their natural form while the
    // label holds the sanitised spelling.
    let attendees = [
      SessionAttendee(
        id: "devices/1", displayName: "Tom Elliot", joined: Self.at(2), isLocal: true),
      SessionAttendee(id: "devices/2", displayName: "Ana Flores", joined: Self.at(40)),
      SessionAttendee(id: "devices/3", displayName: "Bram Okafor", joined: Self.at(41)),
    ]
    let sources: [SourceID] = ["mic", "browser:meet:spaces-s-devices-2"]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: sources, sessionStart: Self.start,
      hints: [Self.hint("spaces/s/devices/2", "devices/2", t: 1000)])

    #expect(
      outcome.speakers.contains {
        $0.source == SourceID("browser:meet:spaces-s-devices-2") && $0.name == "Ana Flores"
      })
  }

  @Test("consuming hints is a new derivation — the version says so")
  func hintConsumptionBumpedTheVersion() {
    // The same roster with a hints-bearing attribution log can now produce a
    // different map, so stored v2 maps must re-derive on next transcription.
    #expect(RosterReconciler.version >= 3)
  }

  // ── Speech evidence: silence is unremarkable (journal #181) ────────────

  @Test("silent tracks draw no warnings and no speaker rows")
  func silentTracksAreUnremarkable() {
    // The 2026-08-17 Matt call: t1 correlated and carrying all remote speech
    // (2,896 onsets), t2/t3 captured-but-silent, two named remotes — one a
    // Presentation pseudo-device with 4 stray ring flickers. The warnings
    // described turns that never existed.
    let attendees = [
      SessionAttendee(
        id: "devices/473", displayName: "Tom Elliot", joined: Self.at(0), origin: .platform,
        isLocal: true),
      SessionAttendee(
        id: "devices/472", displayName: "Matt Silva", joined: Self.at(5), origin: .platform),
      SessionAttendee(
        id: "devices/476", displayName: "Matt Silva (Presentation)", joined: Self.at(300),
        origin: .platform),
      SessionAttendee(id: "t1", joined: Self.at(6), origin: .synthetic),
      SessionAttendee(id: "t2", joined: Self.at(7), origin: .synthetic),
      SessionAttendee(id: "t3", joined: Self.at(8), origin: .synthetic),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees,
      sources: ["mic", "browser:meet:t1", "browser:meet:t2", "browser:meet:t3"],
      sessionStart: Self.start,
      hints: [Self.hint("t1", "devices/472", t: 1000)],
      speech: AttributionSpeechEvidence(
        speechCaptures: ["t1"],
        burstCounts: ["devices/472": 64, "devices/473": 108, "devices/476": 4]))

    #expect(outcome.speakers.map(\.source) == [SourceID("browser:meet:t1")])
    #expect(outcome.warnings.isEmpty)
  }

  @Test("the one-remote inference skips silent tracks and claims only the one that spoke")
  func silentTrackNotInferred() {
    let attendees = [
      SessionAttendee(
        id: "devices/1", displayName: "Tom Elliot", joined: Self.at(0), origin: .platform,
        isLocal: true),
      SessionAttendee(
        id: "devices/2", displayName: "Ana Flores", joined: Self.at(30), origin: .platform),
      SessionAttendee(id: "t1", joined: Self.at(31), origin: .synthetic),
      SessionAttendee(id: "t2", joined: Self.at(32), origin: .synthetic),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:meet:t1", "browser:meet:t2"],
      sessionStart: Self.start,
      speech: AttributionSpeechEvidence(speechCaptures: ["t1"], burstCounts: [:]))

    #expect(
      outcome.speakers.map { "\($0.source.rawValue)→\($0.name)" } == [
        "browser:meet:t1→Ana Flores"
      ])
    #expect(outcome.speakers.first?.confidence == SpeakerConfidence.inferred)
    // The warning counts only the track that actually carried speech.
    #expect(outcome.warnings.contains { $0.contains("assigned 1 unidentified audio track") })
  }

  @Test("an unmatched track that carried speech warns exactly as before")
  func speechTrackStillWarns() {
    let attendees = [
      SessionAttendee(
        id: "devices/1", displayName: "Tom Elliot", joined: Self.at(0), origin: .platform,
        isLocal: true),
      SessionAttendee(
        id: "devices/2", displayName: "Ana", joined: Self.at(30), origin: .platform),
      SessionAttendee(
        id: "devices/3", displayName: "Ben", joined: Self.at(40), origin: .platform),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:x:a"], sessionStart: Self.start,
      speech: AttributionSpeechEvidence(speechCaptures: ["a"], burstCounts: [:]))

    #expect(outcome.warnings.contains { $0.contains("could not be matched to any of 2") })
  }

  @Test("without an attribution log the warnings behave exactly as before")
  func noEvidenceKeepsOldWarnings() {
    let attendees = [
      SessionAttendee(
        id: "devices/1", displayName: "Tom Elliot", joined: Self.at(0), origin: .platform,
        isLocal: true),
      SessionAttendee(
        id: "devices/2", displayName: "Matt Silva", joined: Self.at(5), origin: .platform),
      SessionAttendee(
        id: "devices/3", displayName: "Matt Silva (Presentation)", joined: Self.at(300),
        origin: .platform),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic", "browser:meet:t2", "browser:meet:t3"],
      sessionStart: Self.start, speech: nil)

    #expect(outcome.warnings.contains { $0.contains("could not be matched to any of 2") })
    #expect(outcome.warnings.contains { $0.contains("no audio was matched") })
  }

  @Test(
    "named-but-unheard still warns when the platform showed them speaking — the lost-audio case")
  func lostAudioStillWarns() {
    // The 2026-08-17 morning call: the remote demonstrably spoke (17 bursts
    // in four minutes) but capture produced nothing. That warning is the
    // honest record of lost audio and must survive silence-suppression.
    let attendees = [
      SessionAttendee(
        id: "devices/518", displayName: "Tom Elliot", joined: Self.at(0), origin: .platform,
        isLocal: true),
      SessionAttendee(
        id: "devices/519", displayName: "Stefni Bridges", joined: Self.at(60), origin: .platform),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic"], sessionStart: Self.start,
      speech: AttributionSpeechEvidence(speechCaptures: [], burstCounts: ["devices/519": 17]))

    #expect(outcome.warnings.contains { $0.contains("no audio was matched") })
  }

  @Test("named-but-unheard is suppressed below the burst floor")
  func strayFlickersDoNotWarn() {
    let attendees = [
      SessionAttendee(
        id: "devices/518", displayName: "Tom Elliot", joined: Self.at(0), origin: .platform,
        isLocal: true),
      SessionAttendee(
        id: "devices/519", displayName: "Quiet Guest", joined: Self.at(60), origin: .platform),
    ]
    let outcome = RosterReconciler.reconcile(
      attendees: attendees, sources: ["mic"], sessionStart: Self.start,
      speech: AttributionSpeechEvidence(
        speechCaptures: [],
        burstCounts: ["devices/519": RosterReconciler.domBurstSpeechFloor - 1]))

    #expect(!outcome.warnings.contains { $0.contains("no audio was matched") })
  }
}
