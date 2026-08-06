import Testing

@testable import EarsCore

@Suite("CaptureSourceEntry")
struct CaptureSourceEntryTests {
  @Test("a well-formed enabled entry is capturable")
  func capturableEntries() {
    #expect(
      CaptureSourceEntry.resolve(.table(["id": .string("mic"), "class": .string("mic")]))
        == .capturable(id: SourceID("mic"), sourceClass: .mic))
    #expect(
      CaptureSourceEntry.resolve(
        .table(["id": .string("system"), "class": .string("system"), "enabled": .bool(true)]))
        == .capturable(id: SourceID("system"), sourceClass: .system))
    #expect(
      CaptureSourceEntry.resolve(
        .table(["id": .string("app:us.zoom.xos"), "class": .string("app")]))
        == .capturable(id: SourceID("app:us.zoom.xos"), sourceClass: .app))
  }

  @Test("an entry the daemon will not capture is skipped, with the reason it logs")
  func skippedEntries() {
    let cases: [(ConfigValue, String)] = [
      (.int(3), "?"),
      (.table(["class": .string("mic")]), "?"),
      (.table(["id": .string(""), "class": .string("mic")]), "?"),
      (.table(["id": .string("mic")]), "mic"),
      (.table(["id": .string("mic"), "class": .string("microphone")]), "mic"),
      (.table(["id": .string("mic"), "class": .string("mic"), "enabled": .bool(false)]), "mic"),
      (.table(["id": .string("system:0"), "class": .string("system")]), "system:0"),
      (.table(["id": .string("app:"), "class": .string("app")]), "app:"),
      (.table(["id": .string("browser:tab"), "class": .string("browser")]), "browser:tab"),
      (.table(["id": .string("device:x"), "class": .string("device")]), "device:x"),
    ]
    for (entry, expectedID) in cases {
      guard case .skipped(let id, let reason) = CaptureSourceEntry.resolve(entry) else {
        Issue.record("expected \(entry) to be skipped")
        continue
      }
      #expect(id == expectedID)
      #expect(!reason.isEmpty)
    }
  }

  @Test("capturableIDs keeps declaration order and drops everything else")
  func capturableIDsInOrder() {
    let entries: [ConfigValue] = [
      .table(["id": .string("system"), "class": .string("system")]),
      .table(["id": .string("device:x"), "class": .string("device")]),
      .table(["id": .string("mic"), "class": .string("mic")]),
      .table(["id": .string("app:us.zoom.xos"), "class": .string("app"), "enabled": .bool(false)]),
    ]
    #expect(
      CaptureSourceEntry.capturableIDs(in: entries) == [SourceID("system"), SourceID("mic")])
  }

  @Test("the built-in default config yields the one enabled mic source")
  func defaultConfigYieldsMic() {
    guard case .table(let root) = EarsdConfigSchema.effectiveDefaults,
      case .table(let earsd)? = root["earsd"], case .array(let entries)? = earsd["source"]
    else {
      Issue.record("the earsd defaults no longer carry an [[earsd.source]] array")
      return
    }
    #expect(CaptureSourceEntry.capturableIDs(in: entries) == [SourceID("mic")])
  }
}
