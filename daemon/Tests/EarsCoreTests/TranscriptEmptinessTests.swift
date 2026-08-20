import EarsCore
import EarsCoreTestSupport
import Testing

/// The pure emptiness predicate behind the daemon's on-end gate: the
/// threshold boundaries, the OR between its two halves, and the `0`-disables
/// escape hatch. Both real 2026-08-20 sessions are exercised through it, since
/// the gate exists because of them.
@Suite("TranscriptEmptiness")
struct TranscriptEmptinessTests {
  private static let defaults = TranscriptEmptinessPolicy.defaults

  // MARK: - boundaries

  @Test("exactly at both thresholds is substantive — the test is strictly below")
  func atThresholdIsSubstantive() {
    let verdict = Self.defaults.verdict(wordCount: 10, speechSeconds: 5)
    #expect(!verdict.isEmpty)
  }

  @Test("one word under the word threshold is empty, however much speech there was")
  func oneWordUnder() {
    #expect(Self.defaults.verdict(wordCount: 9, speechSeconds: 600).isEmpty)
  }

  @Test("a fraction under the speech threshold is empty, however many words there were")
  func speechJustUnder() {
    #expect(Self.defaults.verdict(wordCount: 5_000, speechSeconds: 4.999).isEmpty)
  }

  @Test("either half alone is enough to call it empty")
  func eitherHalfTrips() {
    // Words fine, speech short.
    #expect(Self.defaults.verdict(wordCount: 40, speechSeconds: 1).isEmpty)
    // Speech fine, words short.
    #expect(Self.defaults.verdict(wordCount: 3, speechSeconds: 90).isEmpty)
  }

  // MARK: - disabling

  @Test("both thresholds at 0 make every transcript substantive")
  func bothHalvesDisabled() {
    let off = TranscriptEmptinessPolicy(minWords: 0, minSpeechSeconds: 0)
    #expect(!off.isEnabled)
    #expect(!off.verdict(wordCount: 0, speechSeconds: 0).isEmpty)
  }

  @Test("min_words = 0 disables only the word half")
  func wordHalfDisabled() {
    let policy = TranscriptEmptinessPolicy(minWords: 0, minSpeechSeconds: 5)
    #expect(policy.isEnabled)
    // No words at all, but plenty of speech: a transcript the word half would
    // have condemned survives.
    #expect(!policy.verdict(wordCount: 0, speechSeconds: 90).isEmpty)
    #expect(policy.verdict(wordCount: 500, speechSeconds: 2).isEmpty)
  }

  @Test("min_speech_seconds = 0 disables only the speech half")
  func speechHalfDisabled() {
    let policy = TranscriptEmptinessPolicy(minWords: 10, minSpeechSeconds: 0)
    #expect(policy.isEnabled)
    #expect(!policy.verdict(wordCount: 40, speechSeconds: 0).isEmpty)
    #expect(policy.verdict(wordCount: 3, speechSeconds: 900).isEmpty)
  }

  // MARK: - the sessions that prompted the gate

  @Test("the 605s/1-word session reads as empty under the defaults")
  func oneWordSessionIsEmpty() throws {
    let frontmatter = try TranscriptParser.parseFrontmatter(EmptySessionTranscripts.oneWord)
    #expect(frontmatter.wordCount == 1)
    #expect(frontmatter.speechSeconds == 0.556)
    #expect(Self.defaults.verdict(frontmatter: frontmatter).isEmpty)
  }

  @Test("the 4s/0-word session reads as empty under the defaults")
  func silentSessionIsEmpty() throws {
    let frontmatter = try TranscriptParser.parseFrontmatter(EmptySessionTranscripts.silent)
    #expect(frontmatter.wordCount == 0)
    #expect(frontmatter.speechSeconds == 0)
    #expect(Self.defaults.verdict(frontmatter: frontmatter).isEmpty)
  }

  @Test("a genuine short exchange is left alone")
  func substantiveSessionSurvives() throws {
    let frontmatter = try TranscriptParser.parseFrontmatter(EmptySessionTranscripts.substantive)
    #expect(!Self.defaults.verdict(frontmatter: frontmatter).isEmpty)
  }

  @Test("both sessions run everything again with the thresholds at 0")
  func disabledPolicyRestoresOldBehaviour() throws {
    let off = TranscriptEmptinessPolicy(minWords: 0, minSpeechSeconds: 0)
    for markdown in [EmptySessionTranscripts.oneWord, EmptySessionTranscripts.silent] {
      let frontmatter = try TranscriptParser.parseFrontmatter(markdown)
      #expect(!off.verdict(frontmatter: frontmatter).isEmpty)
    }
  }

  // MARK: - the log line's numbers

  @Test("the summary names the measurements and the thresholds that tripped")
  func summaryNamesTheNumbers() {
    let verdict = Self.defaults.verdict(wordCount: 1, speechSeconds: 0.556)
    #expect(verdict.summary == "1 word, 0.6s speech; thresholds 10 words / 5.0s")
  }

  @Test("a wordless transcript's summary pluralises correctly")
  func summaryPluralises() {
    let verdict = Self.defaults.verdict(wordCount: 0, speechSeconds: 0)
    #expect(verdict.summary == "0 words, 0.0s speech; thresholds 10 words / 5.0s")
  }
}
