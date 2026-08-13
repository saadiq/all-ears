/// Reconciles a session's observed roster into the speaker map transcription
/// actually labels turns with — the deterministic, re-runnable derivation that
/// used to happen implicitly and irreversibly, as a side effect of whichever
/// live timing correlation happened to win a race in the browser.
///
/// **Roster and speaker map are different things.** The roster
/// (``SessionAttendee``) is *observed fact*: the platform told us device
/// `spaces/x/devices/403` is called "Matthew Barras", and that is as reliable
/// as anything in the system. The `source` link on an attendee is a *guess*:
/// the extension's `SpeakingCorrelator` pairs a decoded audio track with a
/// device id by temporal coincidence, and a coincidence can be wrong. Storing
/// both in one struct made the guess look exactly as solid as the fact, and
/// everything downstream — speaker labels, the note's title, its `attendees:`
/// — read only the guess. A correlator miss therefore *erased a name the
/// session had known since the moment its owner joined.
///
/// This type keeps the two apart. It takes the roster, applies the invariants
/// that a binding must satisfy to be believable, fills what the roster
/// determines on its own, and emits ``SessionSpeaker`` entries carrying *how*
/// each name was established. What it cannot resolve it says so about, in
/// warnings that travel with the artifacts rather than dying in a log file.
///
/// Pure: no clock, no filesystem, no I/O. `SessionRegistry` calls it once at
/// `session.end` and persists the result, so the same inputs always yield the
/// same map and an old session can be re-reconciled after a fix.
///
/// ## The invariants
///
/// 1. **A browser-captured track is never the local participant.** The local
///    user is captured on `mic`; the browser taps *remote* streams. So a
///    binding from a `browser:*` source to the local attendee is not a
///    low-confidence reading of the evidence, it is an impossible one, and it
///    is dropped rather than ranked. This is the failure behind journal
///    #158/#172, and it is checked here — on durable state, after the call —
///    as well as live in `lib/identity/meet.ts`, because the live check needs
///    a DOM marker that a build or locale can withhold and then fails *open*.
///
/// 2. **A one-remote call needs no correlation at all.** With exactly one
///    named non-local attendee on the roster, every remote audio track in the
///    session is that person's, by counting. Correlation is a heuristic
///    answer to a question that arithmetic already settles, so where the
///    counts force the assignment this makes it — including across the
///    several source ids one participant accumulates through a Meet identity
///    upgrade, which resolve to a single speaker label downstream precisely
///    because they share a name.
///
/// With two or more remote attendees and an unresolved track, the counts
/// force nothing, and this deliberately assigns nothing: an unlabelled turn
/// is recoverable, a confidently mislabelled one is not.
public enum RosterReconciler {

  /// The version of this derivation, persisted as `reconciler_version` in
  /// `session.toml` beside the `[[speaker]]` map it produced.
  ///
  /// Bumped whenever a change here can produce a different map from the same
  /// roster — new invariants, changed tie-breaking. `transcribe` compares a
  /// stored map's version against this and re-derives when the stored one is
  /// older, which is what turns a reconciler bug fix into a repair for every
  /// past session instead of only future ones. A file without the field is
  /// version 0: reconciled (or captured) before versioning existed, and
  /// therefore always stale.
  public static let version = 1

  /// How far after a session's start an attendee may join and still be taken
  /// for the local participant by ``inferLocalAttendee(_:sessionStart:)``.
  ///
  /// A browser session is declared *because* the local tab joined a call, so
  /// the local participant's roster row lands within seconds of the start.
  /// Anyone already in the meeting when you arrive lands in the same burst,
  /// which is exactly the case this window cannot separate — and there it
  /// reports nothing rather than picking one.
  public static let localJoinWindowSeconds: Double = 30

  /// Everything reconciliation concluded, ready to persist on the session.
  public struct Outcome: Sendable, Hashable {
    /// The source → display-name map transcription labels turns with, each
    /// entry carrying how its name was established.
    public var speakers: [SessionSpeaker]
    /// The attendee id taken to be the local participant, or `nil` when that
    /// could not be established — in which case invariant 1 is not applied
    /// and ``warnings`` says so.
    public var localAttendeeID: String?
    /// How ``localAttendeeID`` was arrived at, for the log line.
    public var localResolution: LocalResolution
    /// Human-readable notes about what could not be resolved, or was
    /// resolved by inference rather than observation. These are written into
    /// the transcript's frontmatter and surfaced in the note itself, because
    /// a warning the user never sees is indistinguishable from no warning.
    public var warnings: [String]

    public init(
      speakers: [SessionSpeaker] = [],
      localAttendeeID: String? = nil,
      localResolution: LocalResolution = .unknown,
      warnings: [String] = []
    ) {
      self.speakers = speakers
      self.localAttendeeID = localAttendeeID
      self.localResolution = localResolution
      self.warnings = warnings
    }
  }

  /// How the local participant was identified.
  public enum LocalResolution: String, Sendable, Hashable, CaseIterable {
    /// The capture client flagged the attendee (`self` on `session.attendee`)
    /// — the platform's own answer, and the one to trust.
    case reported
    /// Derived from join order against the session start (see
    /// ``localJoinWindowSeconds``).
    case inferred
    /// Neither available: invariant 1 was not applied.
    case unknown
  }

  /// Reconciles `attendees` against the session's `sources`.
  ///
  /// - Parameters:
  ///   - attendees: the roster as observed, bindings and all.
  ///   - sources: every source the session involves. Only `browser:*` entries
  ///     participate — `mic` is the local participant by construction and
  ///     keeps its own label, and an `app:`/`device:` source is whole-room
  ///     audio that no single attendee owns.
  ///   - sessionStart: when the session began, for the local-participant
  ///     inference.
  public static func reconcile(
    attendees: [SessionAttendee], sources: [SourceID], sessionStart: Instant
  ) -> Outcome {
    var warnings: [String] = []

    // ── Who is the local participant? ────────────────────────────────────
    let reportedLocal = attendees.first(where: \.isLocal)?.id
    let localID: String?
    let resolution: LocalResolution
    if let reportedLocal {
      localID = reportedLocal
      resolution = .reported
    } else if let inferred = inferLocalAttendee(attendees, sessionStart: sessionStart) {
      localID = inferred
      resolution = .inferred
    } else {
      localID = nil
      resolution = .unknown
    }

    // ── Invariant 1: no browser track belongs to the local participant ───
    // Dropped bindings do not vanish; their sources return to the unassigned
    // pool below, which is what lets the track that was mislabelled as the
    // user get relabelled as the person actually speaking on it.
    var bound: [(source: SourceID, name: String)] = []
    for attendee in attendees {
      guard let source = attendee.source, let name = attendee.displayName, !name.isEmpty
      else { continue }
      if attendee.id == localID, source.sourceClass == .browser {
        warnings.append(
          "speaker attribution: dropped a binding of remote audio (\(source.rawValue)) to you "
            + "(\(name)) — browser capture only ever records other participants")
        continue
      }
      bound.append((source, name))
    }
    if localID == nil && attendees.contains(where: { $0.source?.sourceClass == .browser }) {
      warnings.append(
        "speaker attribution: could not identify which roster entry is you, so a remote "
          + "track bound to your own name could not be ruled out")
    }

    var speakers = bound.map {
      SessionSpeaker(source: $0.source, name: $0.name, confidence: .correlated)
    }

    // ── Invariant 2: a one-remote call is settled by counting ────────────
    let assigned = Set(speakers.map(\.source.rawValue))
    let unassigned = sources.filter {
      $0.sourceClass == .browser && !assigned.contains($0.rawValue)
    }
    let remoteNames = namedRemoteAttendees(attendees, localID: localID)

    if !unassigned.isEmpty {
      if remoteNames.count == 1, let only = remoteNames.first {
        for source in unassigned {
          speakers.append(SessionSpeaker(source: source, name: only, confidence: .inferred))
        }
        warnings.append(
          "speaker attribution: assigned \(unassigned.count) unidentified audio "
            + "\(unassigned.count == 1 ? "track" : "tracks") to \(only), the call's only other "
            + "participant")
      } else if remoteNames.isEmpty {
        warnings.append(
          "speaker attribution: \(unassigned.count) audio "
            + "\(unassigned.count == 1 ? "track has" : "tracks have") no name — the roster named "
            + "no other participants")
      } else {
        warnings.append(
          "speaker attribution: \(unassigned.count) audio "
            + "\(unassigned.count == 1 ? "track" : "tracks") could not be matched to any of "
            + "\(remoteNames.count) named participants (\(remoteNames.joined(separator: ", "))) "
            + "— turns from \(unassigned.count == 1 ? "it" : "them") are labelled by source id")
      }
    }

    // ── Named, but never heard ───────────────────────────────────────────
    // Worth saying even when nothing is unassigned: it is the difference
    // between "they said nothing" and "we lost their audio".
    let heard = Set(speakers.map(\.name))
    for name in remoteNames where !heard.contains(name) {
      warnings.append(
        "speaker attribution: \(name) was on the roster but no audio was matched to them")
    }

    return Outcome(
      speakers: speakers, localAttendeeID: localID, localResolution: resolution,
      warnings: warnings)
  }

  /// The distinct display names of attendees who are neither the local
  /// participant nor nameless, in roster order.
  ///
  /// Distinct by name rather than by id on purpose: one human who rejoins, or
  /// whose device id changes through an identity upgrade, is one participant
  /// for every question this type asks — above all "is there exactly one
  /// other person on this call?", which a duplicate id would otherwise answer
  /// "no" and block the assignment invariant 2 exists to make.
  public static func namedRemoteAttendees(
    _ attendees: [SessionAttendee], localID: String?
  ) -> [String] {
    var names: [String] = []
    var seen: Set<String> = []
    for attendee in attendees {
      guard attendee.id != localID else { continue }
      guard let name = attendee.displayName, !name.isEmpty else { continue }
      if seen.insert(name).inserted { names.append(name) }
    }
    return names
  }

  /// A session title built from who was on the call, for a session nobody
  /// ever named.
  ///
  /// The fallback this replaces was the platform's meeting id (`meet
  /// wUE9lE2sg5YB`), which is the worst answer available: unreadable in a
  /// file listing, unsearchable, and — because `[[summarize.preset]]`'s
  /// `notes` template interpolates `{title}` — guaranteed not to match the
  /// note the user was actually typing into during the call. "Matthew Barras"
  /// is a name a human would have chosen, and it makes that lookup land.
  ///
  /// `nil` when the roster names nobody, leaving the platform default in
  /// place: an opaque id beats an empty title.
  public static func derivedTitle(
    attendees: [SessionAttendee], localAttendeeID: String?
  ) -> String? {
    let names = namedRemoteAttendees(attendees, localID: localAttendeeID)
    guard !names.isEmpty else { return nil }
    return names.joined(separator: ", ")
  }

  /// The local participant's attendee id, inferred from join order when the
  /// capture client never flagged one.
  ///
  /// Requires exactly one *named* attendee inside ``localJoinWindowSeconds``
  /// of the session start, and that they be strictly the earliest — the
  /// signature of "you opened the call and others arrived after you". Joining
  /// a meeting already in progress puts several names in that window at once,
  /// and there this returns `nil`: excluding the wrong person would silence a
  /// real participant for the whole call, which is worse than not applying
  /// the invariant at all.
  static func inferLocalAttendee(_ attendees: [SessionAttendee], sessionStart: Instant) -> String? {
    let named = attendees.compactMap { attendee -> (id: String, joined: Instant)? in
      guard let name = attendee.displayName, !name.isEmpty, let joined = attendee.joined
      else { return nil }
      return (attendee.id, joined)
    }
    guard named.count >= 2 else { return nil }
    let inWindow = named.filter {
      $0.joined.interval(since: sessionStart) <= localJoinWindowSeconds
    }
    guard inWindow.count == 1, let candidate = inWindow.first else { return nil }
    // Strictly earliest: a tie means two rows landed together and neither is
    // distinguishable as the one whose join created the session.
    guard named.allSatisfy({ $0.id == candidate.id || $0.joined > candidate.joined })
    else { return nil }
    return candidate.id
  }
}

/// One entry of a session's reconciled speaker map: which display name a
/// source's turns are labelled with, and how that was established.
///
/// Distinct from ``SessionAttendee`` by design — see ``RosterReconciler``.
/// An attendee is who was on the call; a speaker is whose voice a given audio
/// track carries. Several sources may name the same speaker (a participant
/// whose track was re-established mid-call), and they then coalesce into one
/// labelled speaker in the transcript.
public struct SessionSpeaker: Sendable, Hashable {
  public var source: SourceID
  public var name: String
  public var confidence: SpeakerConfidence

  public init(source: SourceID, name: String, confidence: SpeakerConfidence) {
    self.source = source
    self.name = name
    self.confidence = confidence
  }
}

/// How a ``SessionSpeaker``'s name was established — carried through to the
/// transcript so a guess is never presented as an observation.
public enum SpeakerConfidence: String, Sendable, Hashable, Codable, CaseIterable {
  /// The capture client matched this track to a named roster entry, and the
  /// binding survived reconciliation's invariants.
  case correlated
  /// Reconciliation assigned it, because the roster left exactly one
  /// possibility (``RosterReconciler``'s invariant 2).
  case inferred
}

extension SessionSpeaker: Codable {
  private enum CodingKeys: String, CodingKey {
    case source, name, confidence
  }
}
