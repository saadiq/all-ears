import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("ConfiguredEmptiness")
struct ConfiguredEmptinessTests {
  private func config(_ sessions: [String: ConfigValue]) -> ConfigValue {
    .table(["earsd": .table(["sessions": .table(sessions)])])
  }

  @Test("an unset key inherits the shipped thresholds")
  func absentInheritsDefaults() {
    #expect(ConfiguredEmptiness.resolve(from: .table([:])) == .defaults)
    #expect(ConfiguredEmptiness.resolve(from: config([:])) == .defaults)
  }

  @Test("explicit thresholds win, and each half resolves on its own")
  func explicitThresholds() {
    let both = ConfiguredEmptiness.resolve(
      from: config(["min_words": .int(40), "min_speech_seconds": .double(12.5)]))
    #expect(both.minWords == 40)
    #expect(both.minSpeechSeconds == 12.5)

    let wordsOnly = ConfiguredEmptiness.resolve(from: config(["min_words": .int(40)]))
    #expect(wordsOnly.minWords == 40)
    #expect(wordsOnly.minSpeechSeconds == TranscriptEmptinessPolicy.defaults.minSpeechSeconds)
  }

  @Test("min_speech_seconds accepts a TOML integer as well as a float")
  func speechAcceptsInteger() {
    let resolved = ConfiguredEmptiness.resolve(from: config(["min_speech_seconds": .int(8)]))
    #expect(resolved.minSpeechSeconds == 8)
  }

  @Test("both thresholds at 0 disables the gate, exactly as the daemon reads it")
  func zeroDisables() {
    let off = ConfiguredEmptiness.resolve(
      from: config(["min_words": .int(0), "min_speech_seconds": .int(0)]))
    #expect(!off.isEnabled)
  }

  /// The menu's whole reason for reading these: it must agree with the daemon
  /// about which transcripts are empty, or it renders a gap the daemon
  /// deliberately created as a pipeline that stalled.
  @Test("the resolved policy judges the 2026-08-20 empty session empty")
  func agreesWithTheDaemonOnTheSessionThatPromptedTheGate() {
    let policy = ConfiguredEmptiness.resolve(from: .table([:]))
    #expect(policy.verdict(wordCount: 1, speechSeconds: 0.556).isEmpty)
    #expect(!policy.verdict(wordCount: 420, speechSeconds: 610).isEmpty)
  }
}
