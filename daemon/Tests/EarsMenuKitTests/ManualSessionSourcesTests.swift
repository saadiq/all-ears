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

  @Test("an entry earsd will not capture is not named, so the menu cannot start a silent session")
  func uncapturableEntriesDropped() {
    // Each of these passes an id-and-enabled-only reading but is skipped by
    // `earsd` at config resolution, so a session naming it captures nothing.
    let uncapturable: [ConfigValue] = [
      .table(["id": .string("mic")]),  // no class
      .table(["id": .string("mic"), "class": .string("microphone")]),  // unknown class
      .table(["id": .string("system:0"), "class": .string("system")]),  // id must be `system`
      .table(["id": .string("app:"), "class": .string("app")]),  // no bundle id
      .table(["id": .string("browser:tab"), "class": .string("browser")]),  // unsupported
      .table(["id": .string("device:x"), "class": .string("device")]),  // unsupported
    ]
    for entry in uncapturable {
      #expect(ManualSessionSources.resolve(from: config([entry])).isEmpty)
    }
    // …and a config of nothing but those resolves empty, which is what the
    // caller turns into "No capture sources are configured".
    #expect(ManualSessionSources.resolve(from: config(uncapturable)).isEmpty)
  }
}
