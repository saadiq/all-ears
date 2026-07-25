import Testing

@testable import EarsConfig
@testable import EarsCore

/// Covers ``configLayer(fromCLIOverrides:stringOverrides:)``: the generic
/// `--set`/`--set-string` override layer, the CLI-side twin of the `EARS_*`
/// environment layer, occupying the highest-precedence flags layer in
/// `docs/configuration.md`'s model.
@Suite("CLI --set overrides layer")
struct CLIOverridesLayerTests {
  private func layer(_ overrides: [String], strings: [String] = []) -> ConfigValue {
    switch configLayer(fromCLIOverrides: overrides, stringOverrides: strings) {
    case .success(let value): return value
    case .failure(let error):
      Issue.record("unexpected parse failure: \(error)")
      return .table([:])
    }
  }

  @Test("no overrides yields an empty table, so lower layers are untouched")
  func noOverrides() {
    #expect(layer([]) == .table([:]))
  }

  @Test("a single-segment key becomes a top-level entry")
  func singleSegmentKey() {
    #expect(layer(["data_root=/custom/root"]) == .table(["data_root": .string("/custom/root")]))
  }

  @Test("a dotted key nests into tables")
  func dottedKeyNests() {
    #expect(layer(["log.level=debug"]) == .table(["log": .table(["level": .string("debug")])]))
  }

  @Test("a deeply nested key builds every intermediate table")
  func deeplyNested() {
    #expect(
      layer(["earsd.vad.min_silence_ms=500"])
        == .table([
          "earsd": .table(["vad": .table(["min_silence_ms": .int(500)])])
        ]))
  }

  @Test("sibling keys under the same table merge together")
  func siblingsMerge() {
    #expect(
      layer(["log.level=error", "log.file=/tmp/x.jsonl"])
        == .table([
          "log": .table([
            "level": .string("error"),
            "file": .string("/tmp/x.jsonl"),
          ])
        ]))
  }

  @Test("values coerce to bool/int/double like the environment layer")
  func coercesScalars() {
    #expect(
      layer(["earsd.store_native=false"])
        == .table(["earsd": .table(["store_native": .bool(false)])]))
    #expect(layer(["earsd.channels=2"]) == .table(["earsd": .table(["channels": .int(2)])]))
    #expect(layer(["x.ratio=3.5"]) == .table(["x": .table(["ratio": .double(3.5)])]))
    #expect(
      layer(["transcribe.backend=parakeet"])
        == .table(["transcribe": .table(["backend": .string("parakeet")])]))
  }

  @Test("--set-string forces a literal string, never coerced")
  func setStringForcesString() {
    #expect(
      layer([], strings: ["llm.model=1.0"])
        == .table(["llm": .table(["model": .string("1.0")])]))
  }

  @Test("--set-string wins over --set for the same key")
  func setStringWins() {
    #expect(
      layer(["llm.model=123"], strings: ["llm.model=123"])
        == .table(["llm": .table(["model": .string("123")])]))
  }

  @Test("the last occurrence wins within --set")
  func lastWins() {
    #expect(
      layer(["log.level=debug", "log.level=error"])
        == .table(["log": .table(["level": .string("error")])]))
  }

  @Test("only the first = splits key from value, so the value may contain =")
  func valueMayContainEquals() {
    #expect(
      layer(["llm.command=llm -m gpt --flag=x"])
        == .table(["llm": .table(["command": .string("llm -m gpt --flag=x")])]))
  }

  @Test("an empty value becomes an empty string")
  func emptyValue() {
    #expect(layer(["vocab.global="]) == .table(["vocab": .table(["global": .string("")])]))
  }

  @Test("an argument with no = is reported as invalid")
  func missingEquals() {
    let result = configLayer(fromCLIOverrides: ["log.level"])
    #expect(result == .failure(CLIOverrideError(invalidArguments: ["log.level"])))
  }

  @Test("an empty key or empty path segment is reported as invalid")
  func emptyKeyOrSegment() {
    #expect(
      configLayer(fromCLIOverrides: ["=value"])
        == .failure(CLIOverrideError(invalidArguments: ["=value"])))
    #expect(
      configLayer(fromCLIOverrides: ["a..b=value"])
        == .failure(CLIOverrideError(invalidArguments: ["a..b=value"])))
  }

  @Test("every malformed argument is collected, not just the first")
  func collectsAllInvalid() {
    #expect(
      configLayer(fromCLIOverrides: ["good.key=1", "bad", "alsobad"])
        == .failure(CLIOverrideError(invalidArguments: ["bad", "alsobad"])))
  }
}
