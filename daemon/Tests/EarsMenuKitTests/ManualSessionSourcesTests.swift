import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("ManualSessionSources")
struct ManualSessionSourcesTests {
  func config(_ entries: [ConfigValue]) -> ConfigValue {
    .table(["earsd": .table(["source": .array(entries)])])
  }

  @Test("the built-in default config yields the one enabled mic source")
  func defaultConfigYieldsMic() {
    #expect(
      ManualSessionSources.resolve(from: EarsdConfigSchema.effectiveDefaults) == [SourceID("mic")])
  }

  @Test("every enabled source is named, in declaration order")
  func enabledSourcesInOrder() {
    let resolved = ManualSessionSources.resolve(
      from: config([
        .table(["id": .string("mic"), "class": .string("mic")]),
        .table(["id": .string("system"), "class": .string("system"), "enabled": .bool(true)]),
      ]))
    #expect(resolved == [SourceID("mic"), SourceID("system")])
  }

  @Test("a disabled source is not recorded, so it is not named")
  func disabledSourceDropped() {
    let resolved = ManualSessionSources.resolve(
      from: config([
        .table(["id": .string("mic"), "class": .string("mic")]),
        .table(["id": .string("system"), "class": .string("system"), "enabled": .bool(false)]),
      ]))
    #expect(resolved == [SourceID("mic")])
  }

  @Test("malformed entries and a sourceless config resolve to nothing, never a guess")
  func malformedYieldsEmpty() {
    #expect(
      ManualSessionSources.resolve(
        from: config([.table(["class": .string("mic")]), .table(["id": .string("")]), .int(3)])
      ).isEmpty)
    #expect(ManualSessionSources.resolve(from: .table([:])).isEmpty)
  }
}
