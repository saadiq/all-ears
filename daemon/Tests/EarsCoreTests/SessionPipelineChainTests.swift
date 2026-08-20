import Testing

@testable import EarsCore

/// The pipeline view read against the on-end chain a session actually
/// declared (or inherited from its trigger) — see ``OnEndChainPolicy``.
@Suite("SessionPipeline on-end chain")
struct SessionPipelineChainTests {
  /// 2026-08-17T15:01:00Z.
  private let started = Instant(secondsSinceEpoch: 1_786_978_860)
  private var ended: Instant { started.advanced(by: 31 * 60) }
  /// Well past the post-end grace window.
  private var muchLater: Instant { ended.advanced(by: 3_600) }
  /// Inside the post-end grace window.
  private var justAfter: Instant { ended.advanced(by: 60) }

  /// The resolved `[earsd.sessions] on_end_stages` these tests run against.
  private let fullChain = OnEndStage.allCases

  private func session(trigger: TriggerKind, onEndStages: [String]? = nil) -> Session {
    Session(
      id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff",
      title: "Matt Silva",
      state: .ended,
      started: started,
      ended: ended,
      sources: [SourceID("mic")],
      trigger: trigger,
      onEndStages: onEndStages)
  }

  /// A captured-only session: audio on disk, nothing downstream of it.
  private func capturedOnly() -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 9_904_279]
    return artifacts
  }

  @Test("an undeclared manual session's downstream stages were never requested")
  func undeclaredManualSessionRequestsNothing() {
    let record = session(trigger: .manual)
    let stages = SessionPipeline.stages(
      session: record, artifacts: capturedOnly(), now: muchLater, configuredChain: fullChain)
    #expect(stages[0].state == .done)
    #expect(stages.dropFirst().allSatisfy { $0.state == .notRequested })
    #expect(stages.dropFirst().allSatisfy { $0.detail == "not requested" })
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: capturedOnly(), now: muchLater, configuredChain: fullChain)
        == PipelineOutcome(glyph: "✓", text: "recorded"))
  }

  @Test("a declared empty chain is inert whatever the trigger's default would be")
  func declaredEmptyChainIsInert() {
    let record = session(trigger: .browserExtension, onEndStages: [])
    let stages = SessionPipeline.stages(
      session: record, artifacts: capturedOnly(), now: muchLater, configuredChain: fullChain)
    #expect(stages.dropFirst().allSatisfy { $0.state == .notRequested })
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: capturedOnly(), now: muchLater, configuredChain: fullChain)
        == PipelineOutcome(glyph: "✓", text: "recorded"))
  }

  @Test("a transcribe-only chain ends at the transcript, not at a missing note")
  func transcribeOnlyChainEndsAtTheTranscript() {
    let record = session(trigger: .manual, onEndStages: ["transcribe"])
    var artifacts = capturedOnly()
    artifacts.transcriptExists = true
    artifacts.transcriptSegments = 177
    artifacts.transcriptWords = 5_745
    let stages = SessionPipeline.stages(
      session: record, artifacts: artifacts, now: muchLater, configuredChain: fullChain)
    #expect(stages[1].state == .done)
    #expect(stages[1].detail == "177 segments, 5,745 words")
    #expect(stages.dropFirst(2).allSatisfy { $0.state == .notRequested })
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: artifacts, now: muchLater, configuredChain: fullChain)
        == PipelineOutcome(glyph: "✓", text: "transcribed"))
  }

  @Test("a cleanup-terminated chain is done at the cleaned transcript")
  func cleanupTerminatedChain() {
    let record = session(trigger: .manual, onEndStages: ["transcribe", "cleanup"])
    var artifacts = capturedOnly()
    artifacts.transcriptExists = true
    let stalled = SessionPipeline.stages(
      session: record, artifacts: artifacts, now: muchLater, configuredChain: fullChain)
    #expect(stalled[2].state == .missing)
    #expect(stalled[3].state == .notRequested)
    #expect(stalled[4].state == .notRequested)
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: artifacts, now: justAfter, configuredChain: fullChain)
        == PipelineOutcome(glyph: "·", text: "cleaning"))
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: artifacts, now: muchLater, configuredChain: fullChain)
        == PipelineOutcome(glyph: "–", text: "transcribed, not cleaned"))

    artifacts.cleanupExists = true
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: artifacts, now: muchLater, configuredChain: fullChain)
        == PipelineOutcome(glyph: "✓", text: "cleaned"))
  }

  @Test("an undeclared app-detected session renders exactly like the full chain")
  func appDetectedSessionInheritsTheConfiguredChain() {
    let record = session(trigger: .appDetected)
    let stages = SessionPipeline.stages(
      session: record, artifacts: capturedOnly(), now: muchLater, configuredChain: fullChain)
    #expect(stages[1].state == .missing)
    #expect(stages[1].detail == "no transcript on disk")
    #expect(stages[2].state == .missing)
    #expect(stages[2].detail == "not run")
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: capturedOnly(), now: muchLater, configuredChain: fullChain)
        == PipelineOutcome(glyph: "–", text: "no transcript"))
  }

  @Test("a hand-run artifact beyond the chain still renders done")
  func handRunArtifactBeyondTheChainIsDone() {
    let record = session(trigger: .manual)
    var artifacts = capturedOnly()
    artifacts.transcriptExists = true
    artifacts.transcriptSegments = 12
    artifacts.cleanupExists = true
    artifacts.cleanupSegments = 12
    let stages = SessionPipeline.stages(
      session: record, artifacts: artifacts, now: muchLater, configuredChain: fullChain)
    #expect(stages[1].state == .done)
    #expect(stages[2].state == .done)
    #expect(stages[2].detail == "12 segments cleaned")
    #expect(stages[3].state == .notRequested)
    #expect(stages[4].state == .notRequested)
  }

  /// The 2026-08-20 605-second session's measurements: one word over 0.556s
  /// of speech, on a session whose audio is still on disk.
  private func emptyTranscript() -> SessionArtifacts {
    var artifacts = capturedOnly()
    artifacts.transcriptExists = true
    artifacts.transcriptSegments = 1
    artifacts.transcriptWords = 1
    artifacts.transcriptSpeechSeconds = 0.556
    return artifacts
  }

  @Test("not requested outranks skipped: the gate never stopped what nobody asked for")
  func notRequestedOutranksSkipped() {
    let record = session(trigger: .browserExtension, onEndStages: ["transcribe"])
    let stages = SessionPipeline.stages(
      session: record, artifacts: emptyTranscript(), now: muchLater, configuredChain: fullChain)
    #expect(stages[1].state == .done)
    // The chain asked for transcribe alone, so the gate had nothing to stop —
    // calling these skipped would credit the gate with a decision the session
    // had already made for itself.
    #expect(stages.dropFirst(2).allSatisfy { $0.state == .notRequested })
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: emptyTranscript(), now: muchLater, configuredChain: fullChain)
        == PipelineOutcome(glyph: "\u{2713}", text: "transcribed"))
  }

  @Test("a cleanup-only chain the gate stopped reads as empty, not as a stall")
  func cleanupOnlyChainReportsEmpty() {
    let record = session(trigger: .browserExtension, onEndStages: ["transcribe", "cleanup"])
    let stages = SessionPipeline.stages(
      session: record, artifacts: emptyTranscript(), now: justAfter, configuredChain: fullChain)
    #expect(stages[2].state == .skipped)
    #expect(stages[2].detail == "skipped (empty transcript)")
    #expect(stages[3].state == .notRequested)
    #expect(stages[4].state == .notRequested)
    // Inside the grace window this would otherwise claim "cleaning" — a wait
    // that never ends, since the daemon already decided not to.
    #expect(
      SessionPipeline.outcome(
        session: record, artifacts: emptyTranscript(), now: justAfter, configuredChain: fullChain)
        == PipelineOutcome(glyph: "\u{2013}", text: "empty, not cleaned"))
  }
}
