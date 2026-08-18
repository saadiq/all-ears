import Foundation
import Testing

@testable import EarsCore

@Suite("SessionShowRendering")
struct SessionShowRenderingTests {
  private let utc = TimeZone(identifier: "UTC")!
  /// 2026-08-17T15:01:00Z.
  private let started = Instant(secondsSinceEpoch: 1_786_978_860)
  private var ended: Instant { started.advanced(by: 31 * 60) }
  private var now: Instant { ended.advanced(by: 3_600) }

  private func session(
    state: SessionState = .ended, warnings: [String] = [],
    trigger: TriggerKind = .browserExtension
  ) -> Session {
    Session(
      id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff",
      title: "Matt Silva",
      state: state,
      started: started,
      ended: state == .ended ? ended : nil,
      warnings: warnings,
      sources: ["mic", "browser:meet:t1", "browser:meet:t2", "browser:meet:t3"].map {
        SourceID($0)
      },
      trigger: trigger)
  }

  private func artifacts() -> SessionArtifacts {
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
    artifacts.transcriptPath = "/data/sessions/3db61b03/transcript.md"
    artifacts.transcriptSegments = 177
    artifacts.transcriptWords = 5_745
    artifacts.cleanupPath = "/out/2026/08/17/2026-08-17 - Matt Silva.md"
    artifacts.cleanupExists = true
    artifacts.cleanupSegments = 177
    artifacts.summaryCount = 3
    artifacts.noteLink = "[[calls/2026-08-17 - Matt Silva]]"
    return artifacts
  }

  @Test("an ended, published session renders the five-stage view with a warnings hint")
  func endedSessionRenders() {
    let text = SessionShowRendering.render(
      session: session(warnings: ["w1", "w2"]), artifacts: artifacts(), now: now,
      timeZone: utc, showWarnings: false, configuredChain: OnEndStage.allCases)
    #expect(
      text == """
        Matt Silva — ended 15:32, 31m

          capture     ✓ 33 MB mic, 21 MB remote (1 of 3 tracks carried speech)
          transcribe  ✓ 177 segments, 5,745 words
          cleanup     ✓ 177 segments cleaned
          summarize   ✓ 3 presets
          note        ✓ calls/2026-08-17 - Matt Silva
          ⚠ 2 attribution warnings — show with --warnings
        """)
  }

  @Test("--warnings prints each warning verbatim instead of the hint")
  func warningsPrintVerbatim() {
    let text = SessionShowRendering.render(
      session: session(warnings: ["first warning", "second warning"]), artifacts: artifacts(),
      now: now, timeZone: utc, showWarnings: true, configuredChain: OnEndStage.allCases)
    #expect(text.hasSuffix("  ⚠ first warning\n  ⚠ second warning"))
    #expect(!text.contains("--warnings"))
  }

  @Test("an active session renders a recording header and waiting stages")
  func activeSessionRenders() {
    var live = SessionArtifacts()
    live.captureBytesBySource = [SourceID("mic"): 9_904_279]
    let text = SessionShowRendering.render(
      session: session(state: .active), artifacts: live,
      now: started.advanced(by: 26 * 60), timeZone: utc, showWarnings: false,
      configuredChain: OnEndStage.allCases)
    #expect(text.hasPrefix("Matt Silva — recording, started 15:01 (26m ago)"))
    #expect(text.contains("  capture     · 9.9 MB mic"))
    #expect(text.contains("  transcribe  · waits for session end"))
  }

  @Test("the JSON view mirrors the rendered structure")
  func jsonViewMirrorsStructure() {
    let view = SessionShowView.build(
      session: session(warnings: ["w1"]), artifacts: artifacts(), now: now,
      configuredChain: OnEndStage.allCases)
    #expect(view.schema == 1)
    #expect(view.stages.map(\.stage) == ["capture", "transcribe", "cleanup", "summarize", "note"])
    #expect(view.stages.allSatisfy { $0.state == .done })
    #expect(view.artifacts.transcript == "/data/sessions/3db61b03/transcript.md")
    #expect(view.artifacts.cleanup == "/out/2026/08/17/2026-08-17 - Matt Silva.md")
    #expect(view.artifacts.summaries == 3)
    #expect(view.artifacts.note == "[[calls/2026-08-17 - Matt Silva]]")
    #expect(view.warnings == ["w1"])
    #expect(view.session.id == "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff")
  }

  @Test("stages the session never asked for render as an empty slot, not a gap")
  func unrequestedStagesRenderNeutrally() {
    var captured = SessionArtifacts()
    captured.captureBytesBySource = [SourceID("mic"): 9_904_279]
    let text = SessionShowRendering.render(
      session: session(trigger: .manual), artifacts: captured, now: now, timeZone: utc,
      showWarnings: false, configuredChain: OnEndStage.allCases)
    #expect(text.contains("  transcribe  ○ not requested"))
    #expect(text.contains("  note        ○ not requested"))
    #expect(!text.contains("–"))

    let view = SessionShowView.build(
      session: session(trigger: .manual), artifacts: captured, now: now,
      configuredChain: OnEndStage.allCases)
    #expect(view.stages.dropFirst().allSatisfy { $0.state == .notRequested })
  }
}
