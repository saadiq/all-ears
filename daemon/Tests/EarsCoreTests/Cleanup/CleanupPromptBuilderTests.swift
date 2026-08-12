import Testing

@testable import EarsCore

@Suite("CleanupPromptBuilder")
struct CleanupPromptBuilderTests {
  @Test("the dynamic suffix is exactly the transcript text, unwrapped")
  func dynamicSuffixIsRawTranscript() {
    let builder = CleanupPromptBuilder()
    let prompt = builder.build(transcript: "so um the deploy went out last night")
    #expect(prompt.dynamicSuffix == "so um the deploy went out last night")
  }

  @Test("the stable prefix is identical across calls with different transcripts")
  func stablePrefixIsStableAcrossCalls() {
    let builder = CleanupPromptBuilder(vocabulary: ["kubectl", "Priya Raman"])
    let first = builder.build(transcript: "first segment text")
    let second = builder.build(transcript: "a completely different second segment")
    #expect(first.stablePrefix == second.stablePrefix)
    #expect(first.stablePrefix != first.dynamicSuffix)
  }

  @Test("the stable prefix lists every vocabulary term as a correction backstop")
  func stablePrefixListsVocabulary() {
    let builder = CleanupPromptBuilder(vocabulary: ["kubectl", "Priya Raman"])
    let prompt = builder.build(transcript: "text")
    #expect(prompt.stablePrefix.contains("kubectl"))
    #expect(prompt.stablePrefix.contains("Priya Raman"))
  }

  @Test("an empty vocabulary produces no vocabulary section")
  func emptyVocabularyOmitsSection() {
    let builder = CleanupPromptBuilder(vocabulary: [])
    let prompt = builder.build(transcript: "text")
    #expect(!prompt.stablePrefix.contains("Known words"))
  }

  @Test("the default instructs keeping filler words")
  func defaultKeepsFiller() {
    let builder = CleanupPromptBuilder()
    let prompt = builder.build(transcript: "text")
    #expect(prompt.stablePrefix.lowercased().contains("keep filler"))
    #expect(!prompt.stablePrefix.lowercased().contains("remove filler"))
  }

  @Test("removeFiller opts into filler removal instructions")
  func removeFillerOptsIn() {
    let builder = CleanupPromptBuilder(removeFiller: true)
    let prompt = builder.build(transcript: "text")
    #expect(prompt.stablePrefix.lowercased().contains("remove filler"))
  }

  @Test("the stable prefix instructs a minimal-change edit")
  func instructsMinimalChange() {
    let builder = CleanupPromptBuilder()
    let prompt = builder.build(transcript: "text")
    #expect(prompt.stablePrefix.lowercased().contains("smallest"))
  }

  @Test("fullText concatenates the prefix and suffix")
  func fullTextConcatenates() {
    let builder = CleanupPromptBuilder()
    let prompt = builder.build(transcript: "the transcript")
    #expect(prompt.fullText == prompt.stablePrefix + "the transcript")
  }

  // MARK: - Batched turns

  private static let turns = [
    CleanupChunkTurn(index: 1, speaker: "You", text: "so um the deploy went out"),
    CleanupChunkTurn(index: 2, speaker: "Priya Raman", text: "did it pass see eye"),
  ]

  @Test("a chunk renders one marked line per turn")
  func chunkRendersOneLinePerTurn() {
    let rendered = CleanupPromptBuilder.renderChunk(Self.turns)
    #expect(
      rendered == """
        [[1|You]] so um the deploy went out
        [[2|Priya Raman]] did it pass see eye
        """)
  }

  @Test("a turn's newlines collapse so one turn is always exactly one line")
  func newlinesCollapseWithinATurn() {
    let rendered = CleanupPromptBuilder.renderChunk([
      CleanupChunkTurn(index: 1, speaker: "You", text: "first line\nsecond line")
    ])
    #expect(rendered == "[[1|You]] first line second line")
    #expect(!rendered.dropFirst().contains("\n"))
  }

  @Test("a speaker label can't break out of its own marker")
  func speakerLabelIsSanitized() {
    let rendered = CleanupPromptBuilder.renderChunk([
      CleanupChunkTurn(index: 1, speaker: "od]]d | name", text: "text")
    ])
    let parsed = CleanupPromptBuilder.parseChunkResponse(rendered)
    #expect(parsed == [1: "text"])
  }

  @Test("the batched prefix carries the marker contract and stays stable across chunks")
  func chunkPrefixIsStableAndCarriesTheContract() {
    let builder = CleanupPromptBuilder()
    let first = builder.build(chunk: Self.turns)
    let second = builder.build(chunk: [CleanupChunkTurn(index: 1, speaker: "You", text: "other")])
    #expect(first.stablePrefix == second.stablePrefix)
    #expect(first.stablePrefix.contains("[[3|Alice]]"))
    // The batched prefix extends the single-turn one rather than replacing it,
    // so the minimal-change guardrail still applies.
    #expect(first.stablePrefix.hasPrefix(builder.stablePrefix))
  }

  @Test("a well-formed response parses back to turn number -> text")
  func parsesAWellFormedResponse() {
    let parsed = CleanupPromptBuilder.parseChunkResponse(
      """
      [[1|You]] So, um, the deploy went out.
      [[2|Priya Raman]] Did it pass CI?
      """)
    #expect(parsed == [1: "So, um, the deploy went out.", 2: "Did it pass CI?"])
  }

  @Test("a bare [[n]] marker parses too -- the speaker field is optional on the way back")
  func parsesBareMarkers() {
    #expect(CleanupPromptBuilder.parseChunkResponse("[[7]] text") == [7: "text"])
  }

  @Test("preamble is dropped and wrapped continuation lines fold into the turn above")
  func toleratesPreambleAndWrapping() {
    let parsed = CleanupPromptBuilder.parseChunkResponse(
      """
      Sure! Here are the corrected turns:

      [[1|You]] So, um, the deploy
        went out last night.

      [[2|You]] Did it pass CI?
      """)
    #expect(parsed == [1: "So, um, the deploy went out last night.", 2: "Did it pass CI?"])
  }

  @Test("a dropped turn is simply absent, so the caller can fall back to its original")
  func droppedTurnIsAbsent() {
    let parsed = CleanupPromptBuilder.parseChunkResponse("[[1|You]] only this one came back")
    #expect(parsed[1] != nil)
    #expect(parsed[2] == nil)
  }

  @Test("a repeated turn number keeps the first occurrence")
  func repeatedNumberKeepsTheFirst() {
    let parsed = CleanupPromptBuilder.parseChunkResponse(
      """
      [[1|You]] first
      [[1|You]] second
      """)
    #expect(parsed == [1: "first"])
  }

  @Test("an unmarked response parses to nothing rather than to a wrong turn")
  func unmarkedResponseParsesToNothing() {
    #expect(CleanupPromptBuilder.parseChunkResponse("Here is the cleaned text.").isEmpty)
  }

  @Test("render and parse round-trip a chunk unchanged")
  func renderParseRoundTrips() {
    let parsed = CleanupPromptBuilder.parseChunkResponse(
      CleanupPromptBuilder.renderChunk(Self.turns))
    #expect(parsed == [1: Self.turns[0].text, 2: Self.turns[1].text])
  }
}
