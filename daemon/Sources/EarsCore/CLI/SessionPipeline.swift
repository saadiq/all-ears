/// Pure derivation of a session's pipeline state — capture → transcribe →
/// cleanup → summarize → note — from its `Session` record plus what a disk
/// scan found (``SessionArtifacts``). The scan itself is I/O and lives in the
/// `ears` executable; everything here is a deterministic function of its
/// inputs, per `docs/engineering-practices.md`'s tier-0 rule.
public enum SessionPipeline {
  /// How long after `ended` an absent artifact still reads as "running"
  /// rather than "missing": the on-end chain (transcribe, then two LLM
  /// stages) legitimately takes minutes, and a pipeline view that calls a
  /// stage failed while it is mid-flight teaches users to distrust it.
  public static let recentGraceSeconds: Double = 15 * 60

  /// The five stage rows of `ears session show`, in pipeline order.
  ///
  /// - Parameter configuredChain: the resolved `[earsd.sessions]
  ///   on_end_stages`, which an undeclared session may inherit. What this
  ///   session actually asked for is ``OnEndChainPolicy``'s call, and a stage
  ///   nobody asked for is reported as such rather than as a gap — an
  ///   `ears session start` capture is deliberately inert, not broken.
  public static func stages(
    session: Session, artifacts: SessionArtifacts, now: Instant, configuredChain: [OnEndStage]
  ) -> [PipelineStage] {
    let live = session.state != .ended
    if live {
      return [captureStage(session: session, artifacts: artifacts, live: true)]
        + ["transcribe", "cleanup", "summarize", "note"].map {
          PipelineStage(name: $0, state: .waiting, detail: "waits for session end")
        }
    }

    let recent = isRecent(session: session, now: now)
    let expected = expectedStages(session: session, configuredChain: configuredChain)
    let transcribeDone = transcribeDone(session: session, artifacts: artifacts)

    var stages = [captureStage(session: session, artifacts: artifacts, live: false)]

    if transcribeDone {
      stages.append(
        PipelineStage(name: "transcribe", state: .done, detail: transcribeDetail(artifacts)))
    } else if !expected.contains(.transcribe) {
      stages.append(notRequestedStage(name: "transcribe"))
    } else {
      stages.append(
        recent
          ? PipelineStage(name: "transcribe", state: .running, detail: "running")
          : PipelineStage(name: "transcribe", state: .missing, detail: "no transcript on disk"))
    }

    stages.append(
      laterStage(
        name: "cleanup",
        done: artifacts.cleanupExists,
        doneDetail: artifacts.cleanupSegments.map { "\(HumanUnits.grouped($0)) segments cleaned" }
          ?? "published",
        expected: expected.contains(.cleanup),
        previousPending: !transcribeDone && expected.contains(.transcribe),
        missingDetail: "not published",
        recent: recent))

    let summarizeDone = artifacts.summaryCount > 0 || artifacts.noteLink != nil
    stages.append(
      laterStage(
        name: "summarize",
        done: summarizeDone,
        doneDetail: artifacts.summaryCount > 0
          ? "\(artifacts.summaryCount) preset\(artifacts.summaryCount == 1 ? "" : "s")"
          : "note published",
        expected: expected.contains(.summarize),
        previousPending: !artifacts.cleanupExists && expected.contains(.cleanup),
        missingDetail: "no summaries",
        recent: recent))

    // `summarize` publishes the note, so the note row rides on summarize's
    // expectation: no summarize was asked for, no note was ever coming.
    stages.append(
      laterStage(
        name: "note",
        done: artifacts.noteLink != nil,
        doneDetail: artifacts.noteLink.map(displayNoteLink) ?? "",
        expected: expected.contains(.summarize),
        previousPending: !summarizeDone && expected.contains(.summarize),
        missingDetail: "not published",
        recent: recent))

    return stages
  }

  /// The one-line outcome `ears sessions` and the status dashboard's recent
  /// tail show per session. Terminal success is the *last stage the session
  /// asked for* completing, so a capture-only session reads as recorded and a
  /// transcribe-only one as transcribed — neither is waiting on a note.
  public static func outcome(
    session: Session, artifacts: SessionArtifacts, now: Instant, configuredChain: [OnEndStage]
  ) -> PipelineOutcome {
    switch session.state {
    case .active:
      let elapsed = HumanUnits.duration(seconds: now.interval(since: session.started))
      return PipelineOutcome(glyph: "●", text: "recording (\(elapsed))")
    case .paused:
      let elapsed = HumanUnits.duration(seconds: now.interval(since: session.started))
      return PipelineOutcome(glyph: "◐", text: "paused (\(elapsed))")
    case .ended:
      break
    }

    let warningsSuffix = warningsSuffix(session)
    if artifacts.noteLink != nil {
      guard session.warnings.isEmpty else {
        return PipelineOutcome(glyph: "⚠", text: "published\(warningsSuffix)")
      }
      return PipelineOutcome(glyph: "✓", text: "published")
    }

    let recent = isRecent(session: session, now: now)
    let expected = expectedStages(session: session, configuredChain: configuredChain)
    let base = endedOutcome(
      session: session, artifacts: artifacts, expected: expected, recent: recent)
    guard session.warnings.isEmpty else {
      return PipelineOutcome(glyph: "⚠", text: base.text + warningsSuffix)
    }
    return base
  }

  /// The outcome of an ended, note-less session, read against the last stage
  /// it asked for.
  private static func endedOutcome(
    session: Session, artifacts: SessionArtifacts, expected: Set<OnEndStage>, recent: Bool
  ) -> PipelineOutcome {
    guard expected.contains(.transcribe) else {
      return PipelineOutcome(glyph: "✓", text: "recorded")
    }
    guard transcribeDone(session: session, artifacts: artifacts) else {
      return recent
        ? PipelineOutcome(glyph: "·", text: "transcribing")
        : PipelineOutcome(glyph: "–", text: "no transcript")
    }
    if expected.contains(.summarize) {
      return recent
        ? PipelineOutcome(glyph: "·", text: "summarizing")
        : PipelineOutcome(glyph: "–", text: "transcribed, no note")
    }
    guard expected.contains(.cleanup) else {
      return PipelineOutcome(glyph: "✓", text: "transcribed")
    }
    guard artifacts.cleanupExists else {
      return recent
        ? PipelineOutcome(glyph: "·", text: "cleaning")
        : PipelineOutcome(glyph: "–", text: "transcribed, not cleaned")
    }
    return PipelineOutcome(glyph: "✓", text: "cleaned")
  }

  // MARK: - Stage helpers

  /// The stages this session's on-end chain was ever going to run. Chain
  /// problems are the daemon's to report, so they are dropped here.
  private static func expectedStages(
    session: Session, configuredChain: [OnEndStage]
  ) -> Set<OnEndStage> {
    Set(
      OnEndChainPolicy.stages(
        declared: session.onEndStages, trigger: session.trigger, configured: configuredChain
      ).stages)
  }

  private static func notRequestedStage(name: String) -> PipelineStage {
    PipelineStage(name: name, state: .notRequested, detail: "not requested")
  }

  private static func isRecent(session: Session, now: Instant) -> Bool {
    guard let ended = session.ended else { return true }
    return now.interval(since: ended) < recentGraceSeconds
  }

  private static func transcribeDone(session: Session, artifacts: SessionArtifacts) -> Bool {
    session.transcriptCompleted != nil || artifacts.transcriptExists
  }

  private static func warningsSuffix(_ session: Session) -> String {
    let count = session.warnings.count
    return ", \(count) warning\(count == 1 ? "" : "s")"
  }

  private static func captureStage(
    session: Session, artifacts: SessionArtifacts, live: Bool
  ) -> PipelineStage {
    guard !artifacts.captureBytesBySource.isEmpty else {
      if live {
        return PipelineStage(name: "capture", state: .running, detail: "recording")
      }
      if transcribeDone(session: session, artifacts: artifacts) {
        return PipelineStage(
          name: "capture", state: .done, detail: "audio evicted (transcript retained)")
      }
      return PipelineStage(name: "capture", state: .missing, detail: "no audio on disk")
    }
    return PipelineStage(
      name: "capture",
      state: live ? .running : .done,
      detail: captureDetail(session: session, artifacts: artifacts))
  }

  private static func captureDetail(session: Session, artifacts: SessionArtifacts) -> String {
    var micBytes = 0
    var remoteBytes = 0
    for (source, bytes) in artifacts.captureBytesBySource {
      if source.sourceClass == .mic {
        micBytes += bytes
      } else {
        remoteBytes += bytes
      }
    }
    var parts: [String] = []
    if micBytes > 0 { parts.append("\(HumanUnits.bytes(micBytes)) mic") }
    if remoteBytes > 0 { parts.append("\(HumanUnits.bytes(remoteBytes)) remote") }
    var detail = parts.joined(separator: ", ")

    // The speech-evidence parenthetical, only where the flight recorder
    // actually reported: a session with no attribution log gets no claim.
    let tracks = browserTracks(session: session, artifacts: artifacts)
    if artifacts.hasAttributionLog, !tracks.isEmpty {
      let carried = tracks.filter { artifacts.speechCaptures.contains(captureHandle($0)) }.count
      detail += " (\(carried) of \(tracks.count) tracks carried speech)"
    }
    return detail
  }

  /// Every browser-class source this session involved — the union of what
  /// the session record names and what actually landed on disk, so a track
  /// admitted after the record was last written still counts.
  private static func browserTracks(
    session: Session, artifacts: SessionArtifacts
  ) -> [SourceID] {
    var seen = Set<SourceID>()
    var tracks: [SourceID] = []
    for source in session.sources + Array(artifacts.captureBytesBySource.keys)
    where source.sourceClass == .browser && seen.insert(source).inserted {
      tracks.append(source)
    }
    return tracks.sorted { $0.rawValue < $1.rawValue }
  }

  /// The capture handle the attribution log names a browser source by — the
  /// id's last `:` component (`browser:meet:t1` → `t1`), per
  /// ``AttributionBindingHint/captureId``'s "suffix of the earsd source
  /// label" contract.
  static func captureHandle(_ source: SourceID) -> String {
    source.rawValue.split(separator: ":").last.map(String.init) ?? source.rawValue
  }

  /// - Parameters:
  ///   - expected: whether the session's chain asked for this stage. An
  ///     artifact that exists wins over it — a hand-run `cleanup` is done, not
  ///     unrequested.
  ///   - previousPending: whether the stage feeding this one was asked for and
  ///     has not produced its artifact. Only a pending predecessor queues this
  ///     one; a predecessor nobody asked for blocks nothing.
  private static func laterStage(
    name: String,
    done: Bool,
    doneDetail: String,
    expected: Bool,
    previousPending: Bool,
    missingDetail: String,
    recent: Bool
  ) -> PipelineStage {
    if done { return PipelineStage(name: name, state: .done, detail: doneDetail) }
    if !expected { return notRequestedStage(name: name) }
    if !previousPending {
      return recent
        ? PipelineStage(name: name, state: .running, detail: "running")
        : PipelineStage(name: name, state: .missing, detail: missingDetail)
    }
    return recent
      ? PipelineStage(name: name, state: .waiting, detail: "queued")
      : PipelineStage(name: name, state: .missing, detail: "not run")
  }

  private static func transcribeDetail(_ artifacts: SessionArtifacts) -> String {
    guard let segments = artifacts.transcriptSegments else { return "completed" }
    guard let words = artifacts.transcriptWords else {
      return "\(HumanUnits.grouped(segments)) segments"
    }
    return "\(HumanUnits.grouped(segments)) segments, \(HumanUnits.grouped(words)) words"
  }

  /// `[[calls/2026-08-17 - Matt Silva]]` → `calls/2026-08-17 - Matt Silva`;
  /// a plain path passes through untouched.
  private static func displayNoteLink(_ link: String) -> String {
    guard link.hasPrefix("[["), link.hasSuffix("]]") else { return link }
    return String(link.dropFirst(2).dropLast(2))
  }
}
