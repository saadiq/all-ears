import Testing

@testable import EarsCore

@Suite("SessionPipeline")
struct SessionPipelineTests {
  /// 2026-08-17T15:01:00Z.
  private let started = Instant(secondsSinceEpoch: 1_786_978_860)
  private var ended: Instant { started.advanced(by: 31 * 60) }
  /// Well past the post-end grace window.
  private var muchLater: Instant { ended.advanced(by: 3_600) }
  /// Inside the post-end grace window.
  private var justAfter: Instant { ended.advanced(by: 60) }

  private func session(
    state: SessionState = .ended,
    sources: [String] = ["mic", "browser:meet:t1", "browser:meet:t2", "browser:meet:t3"],
    warnings: [String] = []
  ) -> Session {
    Session(
      id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff",
      title: "Matt Silva",
      state: state,
      started: started,
      ended: state == .ended ? ended : nil,
      warnings: warnings,
      sources: sources.map { SourceID($0) })
  }

  private func fullArtifacts() -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [
      SourceID("mic"): 33_000_000,
      SourceID("browser:meet:t1"): 15_000_000,
      SourceID("browser:meet:t2"): 3_000_000,
      SourceID("browser:meet:t3"): 3_100_000,
    ]
    artifacts.hasAttributionLog = true
    artifacts.speechCaptures = ["t1"]
    artifacts.transcriptExists = true
    artifacts.transcriptSegments = 177
    artifacts.transcriptWords = 5_745
    artifacts.cleanupPath = "/out/2026/08/17/2026-08-17 - Matt Silva.md"
    artifacts.cleanupExists = true
    artifacts.cleanupSegments = 177
    artifacts.summaryCount = 3
    artifacts.noteLink = "[[calls/2026-08-17 - Matt Silva]]"
    return artifacts
  }

  // MARK: - stage derivation, fully-published session

  @Test("a fully published session derives five done stages")
  func fullyPublishedSessionIsAllDone() {
    let stages = SessionPipeline.stages(
      session: session(), artifacts: fullArtifacts(), now: muchLater)
    #expect(stages.map(\.name) == ["capture", "transcribe", "cleanup", "summarize", "note"])
    #expect(stages.allSatisfy { $0.state == .done })
    #expect(stages[0].detail == "33 MB mic, 21 MB remote (1 of 3 tracks carried speech)")
    #expect(stages[1].detail == "177 segments, 5,745 words")
    #expect(stages[2].detail == "177 segments cleaned")
    #expect(stages[3].detail == "3 presets")
    #expect(stages[4].detail == "calls/2026-08-17 - Matt Silva")
  }

  @Test("a mic-only session's capture detail names no remote tracks")
  func micOnlyCaptureDetail() {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 9_904_279]
    let stages = SessionPipeline.stages(
      session: session(sources: ["mic"]), artifacts: artifacts, now: justAfter)
    #expect(stages[0].state == .done)
    #expect(stages[0].detail == "9.9 MB mic")
  }

  // MARK: - absence: recent means running, old means missing

  @Test("an ended-recently session with no transcript renders transcribe as running, not failed")
  func recentAbsenceIsRunning() {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 1_000]
    let stages = SessionPipeline.stages(
      session: session(sources: ["mic"]), artifacts: artifacts, now: justAfter)
    #expect(stages[1].state == .running)
    #expect(stages[2].state == .waiting)
    #expect(stages[3].state == .waiting)
    #expect(stages[4].state == .waiting)
  }

  @Test("long after the end, the same absence reads as missing")
  func oldAbsenceIsMissing() {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 1_000]
    let stages = SessionPipeline.stages(
      session: session(sources: ["mic"]), artifacts: artifacts, now: muchLater)
    #expect(stages[1].state == .missing)
    #expect(stages[1].detail == "no transcript on disk")
    #expect(stages[2].state == .missing)
    #expect(stages[2].detail == "not run")
  }

  @Test("evicted audio with a completed transcript still renders capture as done")
  func evictedAudioIsNotAFailure() {
    var artifacts = fullArtifacts()
    artifacts.captureBytesBySource = [:]
    let stages = SessionPipeline.stages(
      session: session(), artifacts: artifacts, now: muchLater)
    #expect(stages[0].state == .done)
    #expect(stages[0].detail == "audio evicted (transcript retained)")
  }

  // MARK: - active sessions

  @Test("an active session marks capture as running and every later stage as waiting")
  func activeSessionWaitsForEnd() {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 9_904_279]
    let stages = SessionPipeline.stages(
      session: session(state: .active, sources: ["mic"]), artifacts: artifacts,
      now: started.advanced(by: 26 * 60))
    #expect(stages[0].state == .running)
    #expect(stages[0].detail == "9.9 MB mic")
    for stage in stages.dropFirst() {
      #expect(stage.state == .waiting)
      #expect(stage.detail == "waits for session end")
    }
  }

  // MARK: - one-line outcomes

  @Test("outcomes: recording, published, published-with-warnings, in-flight, and stalled")
  func outcomeLines() {
    let active = session(state: .active)
    #expect(
      SessionPipeline.outcome(
        session: active, artifacts: SessionArtifacts(), now: started.advanced(by: 26 * 60))
        == PipelineOutcome(glyph: "●", text: "recording (26m)"))

    #expect(
      SessionPipeline.outcome(session: session(), artifacts: fullArtifacts(), now: muchLater)
        == PipelineOutcome(glyph: "✓", text: "published"))

    var warned = fullArtifacts()
    #expect(
      SessionPipeline.outcome(
        session: session(warnings: ["w1", "w2"]), artifacts: warned, now: muchLater)
        == PipelineOutcome(glyph: "⚠", text: "published, 2 warnings"))

    warned.noteLink = nil
    warned.summaryCount = 0
    #expect(
      SessionPipeline.outcome(session: session(), artifacts: warned, now: justAfter)
        == PipelineOutcome(glyph: "·", text: "summarizing"))
    #expect(
      SessionPipeline.outcome(session: session(), artifacts: warned, now: muchLater)
        == PipelineOutcome(glyph: "–", text: "transcribed, no note"))

    #expect(
      SessionPipeline.outcome(session: session(), artifacts: SessionArtifacts(), now: justAfter)
        == PipelineOutcome(glyph: "·", text: "transcribing"))
    #expect(
      SessionPipeline.outcome(session: session(), artifacts: SessionArtifacts(), now: muchLater)
        == PipelineOutcome(glyph: "–", text: "no transcript"))
  }

  @Test("a paused session's outcome says paused")
  func pausedOutcome() {
    #expect(
      SessionPipeline.outcome(
        session: session(state: .paused), artifacts: SessionArtifacts(),
        now: started.advanced(by: 600))
        == PipelineOutcome(glyph: "◐", text: "paused (10m)"))
  }
}
