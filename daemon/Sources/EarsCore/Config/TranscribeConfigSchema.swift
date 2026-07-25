/// Built-in defaults and declared schema for `transcribe`'s own config slice:
/// the `[transcribe]` ASR table and the opt-in `[diarize]` table. Values match
/// the reference config in `docs/configuration.md` exactly.
///
/// Until now these two tables were passthrough keys (accepted but unvalidated),
/// with their defaults living inline as `stringValue(..., default:)` fallbacks
/// duplicated across `TranscribeRuntime`/`FollowRuntime`. Declaring the slice
/// here gives `--set transcribe.backend=…`/`--set diarize.backend=…` real
/// validation (a typo'd key or a wrong type is rejected, not silently ignored),
/// and — via each field's `description` — lets these settings show up in
/// `ears config describe` alongside every other documented key.
///
/// Like ``EarsdConfigSchema``, this schema declares only its own slice; the
/// shared keys every tool needs (`data_root`, `output_root`, `[log]`, …) are
/// ``Phase0ConfigSchema``'s concern. ``effectiveSchema``/``effectiveDefaults``
/// compose the two via ``ConfigSchema/union(_:)`` into what `transcribe`
/// actually validates against.
public enum TranscribeConfigSchema {
  public static let defaults: ConfigValue = .table([
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

  public static let schema = ConfigSchema(
    fields: [
      "transcribe": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "backend": ConfigSchema.Field(
              type: .string, description: "ASR backend (e.g. \"fluidaudio\")."),
            "model": ConfigSchema.Field(
              type: .string,
              description:
                "Optional model id (e.g. \"parakeet-tdt-v3\"); empty means the backend default."),
            "compute": ConfigSchema.Field(
              type: .string,
              description: "Compute unit: \"ane\", \"gpu\", \"cpu\", or \"automatic\"."),
          ]
        ),
        description: "Transcription (ASR) backend, model, and compute placement."),
      "diarize": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "backend": ConfigSchema.Field(
              type: .string,
              description:
                "Speaker-diarization backend: \"none\" (default, off) or \"sortformer\"."),
            "model": ConfigSchema.Field(
              type: .string,
              description: "Optional model id override; empty means the backend default."),
            "compute": ConfigSchema.Field(
              type: .string,
              description: "Compute unit: \"ane\", \"gpu\", \"cpu\", or \"automatic\"."),
          ]
        ),
        description:
          "Opt-in speaker diarization: splits a multi-speaker source into Speaker N. Off by default."
      ),
    ]
  )

  /// ``defaults`` merged with ``Phase0ConfigSchema/defaults``: the full set of
  /// built-in defaults a `transcribe` caller needs.
  public static let effectiveDefaults: ConfigValue = mergeConfigValues(
    base: Phase0ConfigSchema.defaults,
    overlay: defaults
  )

  /// ``schema`` composed with ``Phase0ConfigSchema/schema`` via
  /// ``ConfigSchema/union(_:)``: what `transcribe` actually validates its
  /// merged config against.
  public static let effectiveSchema = Phase0ConfigSchema.schema.union(schema)
}
