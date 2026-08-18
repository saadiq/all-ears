import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("ConfiguredOnEndChain")
struct ConfiguredOnEndChainTests {
  private func config(_ stages: [ConfigValue]?) -> ConfigValue {
    guard let stages else { return .table(["earsd": .table(["sessions": .table([:])])]) }
    return .table(["earsd": .table(["sessions": .table(["on_end_stages": .array(stages)])])])
  }

  /// The two absences the menu must tell apart: a config that never mentions
  /// the key inherits the daemon's full chain, while one that sets `[]` has
  /// turned the chain off — and a session on that machine is finished, not
  /// missing its transcript.
  @Test("an absent key means the full chain, an explicit empty list means none")
  func absentDiffersFromEmpty() {
    #expect(ConfiguredOnEndChain.resolve(from: config(nil)) == OnEndStage.allCases)
    #expect(ConfiguredOnEndChain.resolve(from: .table([:])) == OnEndStage.allCases)
    #expect(ConfiguredOnEndChain.resolve(from: config([])).isEmpty)
  }

  @Test("a configured list resolves in chain order, dropping what the daemon drops")
  func resolvesLeniently() {
    #expect(
      ConfiguredOnEndChain.resolve(from: config([.string("summarize"), .string("transcribe")]))
        == [.transcribe, .summarize])
    #expect(
      ConfiguredOnEndChain.resolve(from: config([.string("transcribe"), .string("nonsense")]))
        == [.transcribe])
  }
}
