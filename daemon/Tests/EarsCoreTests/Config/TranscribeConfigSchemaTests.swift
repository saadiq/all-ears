import Testing

@testable import EarsCore

/// Covers `TranscribeConfigSchema`'s declared `[transcribe]`/`[diarize]`
/// slices — previously bare, unvalidated passthrough keys with inline defaults
/// in `TranscribeRuntime` — and their composition into one effective schema
/// for `transcribe`.
@Suite("TranscribeConfigSchema")
struct TranscribeConfigSchemaTests {
  @Test("the built-in defaults validate cleanly against the schema")
  func defaultsAreValid() {
    let errors = validateConfig(
      TranscribeConfigSchema.defaults, against: TranscribeConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("defaults match the inline runtime defaults and docs/configuration.md")
  func defaultsMatchReferenceConfig() {
    let expected: ConfigValue = .table([
      "transcribe": .table([
        "backend": .string("fluidaudio"),
        "model": .string(""),
        "compute": .string("automatic"),
      ]),
      "diarize": .table([
        "backend": .string("none"),
        "model": .string(""),
        "compute": .string("automatic"),
      ]),
    ])
    #expect(TranscribeConfigSchema.defaults == expected)
  }

  @Test("the doc's [transcribe]/[diarize] reference example validates cleanly")
  func fullReferenceExampleValidates() {
    let value = mergeConfigLayers([
      TranscribeConfigSchema.defaults,
      .table([
        "transcribe": .table([
          "backend": .string("fluidaudio"),
          "model": .string("parakeet-tdt-v3"),
          "compute": .string("ane"),
        ]),
        "diarize": .table([
          "backend": .string("sortformer")
        ]),
      ]),
    ])

    let errors = validateConfig(value, against: TranscribeConfigSchema.schema)
    #expect(errors.isEmpty)
  }

  @Test("a typo'd key under [transcribe] is now rejected, not silently passed through")
  func unknownTranscribeKey() {
    let value = mergeConfigLayers([
      TranscribeConfigSchema.defaults,
      .table(["transcribe": .table(["backends": .string("fluidaudio")])]),
    ])

    let errors = validateConfig(value, against: TranscribeConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "transcribe.backends")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("a wrong-typed [diarize] value is reported")
  func wrongTypedDiarizeValue() {
    let value = mergeConfigLayers([
      TranscribeConfigSchema.defaults,
      .table(["diarize": .table(["backend": .int(1)])]),
    ])

    let errors = validateConfig(value, against: TranscribeConfigSchema.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "diarize.backend")
    #expect(errors.first?.reason == .typeMismatch(expected: .string, got: .int))
  }

  @Test("effectiveSchema composes Phase0's shared keys with this schema's own slices")
  func effectiveSchemaComposesPhase0() {
    let value = mergeConfigLayers([
      TranscribeConfigSchema.effectiveDefaults,
      .table(["data_root": .string("/custom/data")]),
    ])

    let errors = validateConfig(value, against: TranscribeConfigSchema.effectiveSchema)
    #expect(errors.isEmpty)
  }

  @Test("effectiveDefaults includes both the shared Phase0 keys and this schema's slices")
  func effectiveDefaultsIncludesBoth() {
    guard case .table(let root) = TranscribeConfigSchema.effectiveDefaults else {
      Issue.record("expected a table root")
      return
    }
    #expect(root["data_root"] == .string("~/Library/Application Support/ears"))
    #expect(root["transcribe"] != nil)
    #expect(root["diarize"] != nil)
    #expect(root["log"] != nil)
  }
}
