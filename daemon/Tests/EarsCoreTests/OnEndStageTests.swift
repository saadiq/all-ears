import Testing

@testable import EarsCore

@Suite("OnEndStage")
struct OnEndStageTests {
  @Test("resolveList canonicalises order, collapses duplicates, and accepts the full vocabulary")
  func resolveListValid() {
    let resolved = OnEndStage.resolveList(["summarize", "transcribe", "cleanup", "transcribe"])
    #expect(resolved.stages == [.transcribe, .cleanup, .summarize])
    #expect(resolved.problems.isEmpty)
    #expect(OnEndStage.resolveList([]).stages.isEmpty)
    #expect(OnEndStage.resolveList([]).problems.isEmpty)
  }

  @Test("resolveList drops unknown names with a problem naming the valid vocabulary")
  func resolveListUnknownName() {
    let resolved = OnEndStage.resolveList(["transcribe", "sumarize"])
    #expect(resolved.stages == [.transcribe])
    let problem = try? #require(resolved.problems.first)
    #expect(problem?.contains("'sumarize'") == true)
    #expect(problem?.contains("transcribe, cleanup, summarize") == true)
  }

  @Test("resolveList drops LLM stages configured without transcribe — they need its output")
  func resolveListLLMWithoutTranscribe() {
    let resolved = OnEndStage.resolveList(["cleanup", "summarize"])
    #expect(resolved.stages.isEmpty)
    #expect(resolved.problems.contains { $0.contains("require the transcribe stage") })
  }
}
