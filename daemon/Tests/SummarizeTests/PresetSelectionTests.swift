import EarsCore
import EarsCoreTestSupport
import Foundation
import Testing

@testable import summarize

/// Coverage for picking the one preset a conversation belongs to: the `when`
/// descriptions config carries, the classification prompt built from them, and
/// every way the model's answer can come back wrong.
@Suite("PresetSelection")
struct PresetSelectionTests {
  private static let candidates = [
    PresetSelection.Candidate(
      name: "meeting", when: "a call with an external person: user research, sales, investor"),
    PresetSelection.Candidate(name: "workshop", when: "a working session with an advisor"),
  ]

  private struct ScriptedFailure: Error {}

  private static func backend(answering answer: String) -> FakeLLMBackend {
    FakeLLMBackend(results: [.success(LLMCompletionResult(text: answer))])
  }

  // MARK: - config

  @Test("a preset's `when` is parsed; without one the preset is not a candidate")
  func whenIsParsed() {
    let root = ConfigValue.table([
      "summarize": .table([
        "preset": .array([
          .table([
            "name": .string("meeting"),
            "prompt_file": .string("prompts/meeting.md"),
            "when": .string("a call with an external person"),
          ]),
          .table(["name": .string("brief")]),
          // An empty `when` is not a description of anything, so it reads the
          // same as no `when` at all rather than offering the classifier a
          // blank candidate.
          .table(["name": .string("blank"), "when": .string("")]),
        ])
      ])
    ])

    let presets = SummarizeRuntime.presetEntries(root)

    #expect(presets.map(\.name) == ["meeting", "brief", "blank"])
    #expect(presets[0].when == "a call with an external person")
    #expect(presets[1].when == nil)
    #expect(presets[2].when == nil)
  }

  // MARK: - the prompt

  @Test("the classification prompt offers every candidate with its own description")
  func promptCarriesTheDescriptions() {
    let prompt = PresetSelection.prompt(candidates: Self.candidates, transcript: "Hello there.")

    #expect(prompt.stablePrefix.contains("- meeting: a call with an external person"))
    #expect(prompt.stablePrefix.contains("- workshop: a working session with an advisor"))
    #expect(prompt.stablePrefix.contains("preset: <one of the names above"))
    #expect(prompt.dynamicSuffix == "Hello there.")
  }

  @Test("a long transcript is classified from its opening, and the elision is marked")
  func longTranscriptIsBounded() {
    let transcript = String(repeating: "a", count: PresetSelection.maxTranscriptCharacters + 500)

    let excerpt = PresetSelection.excerpt(transcript)

    #expect(excerpt.hasPrefix(String(repeating: "a", count: 100)))
    #expect(excerpt.contains("transcript truncated"))
    #expect(excerpt.count < transcript.count)
  }

  // MARK: - selection

  @Test("the named preset is selected, with the model's reasoning kept for the log")
  func selectsTheNamedPreset() async {
    let choice = await PresetSelection.select(
      candidates: Self.candidates, fallback: "meeting", transcript: "…",
      backend: Self.backend(answering: "preset: workshop\nbecause: an advisor is coaching me."))

    #expect(choice.name == "workshop")
    #expect(choice.reason == "an advisor is coaching me.")
    #expect(!choice.fellBack)
  }

  @Test("a decorated or chatty answer still resolves to the preset it names")
  func toleratesDecoratedAnswers() async {
    for answer in ["preset: **workshop**", "`workshop`", "The preset is workshop.", "workshop\n"] {
      let choice = await PresetSelection.select(
        candidates: Self.candidates, fallback: "meeting", transcript: "…",
        backend: Self.backend(answering: answer))
      #expect(choice.name == "workshop", "answer: \(answer.debugDescription)")
      #expect(!choice.fellBack)
    }
  }

  @Test("an answer naming no configured preset falls back to the first one, quoting the answer")
  func unknownAnswerFallsBack() async throws {
    let choice = await PresetSelection.select(
      candidates: Self.candidates, fallback: "meeting", transcript: "…",
      backend: Self.backend(answering: "preset: podcast\nbecause: it sounded like one."))

    #expect(choice.name == "meeting")
    #expect(choice.fellBack)
    #expect(try #require(choice.rawAnswer).contains("podcast"))
  }

  @Test("a classification call that throws falls back rather than failing the run")
  func backendFailureFallsBack() async throws {
    let choice = await PresetSelection.select(
      candidates: Self.candidates, fallback: "meeting", transcript: "…",
      backend: FakeLLMBackend(results: [.failure(ScriptedFailure())]))

    #expect(choice.name == "meeting")
    #expect(choice.fellBack)
    #expect(try #require(choice.reason).contains("classification failed"))
  }

  @Test("a preset name mentioned before the answer does not outrank the answer")
  func earliestStandaloneNameWins() async {
    let choice = await PresetSelection.select(
      candidates: Self.candidates, fallback: "meeting", transcript: "…",
      backend: Self.backend(answering: "This is a workshop, not a meeting."))

    #expect(choice.name == "workshop")
  }
}
