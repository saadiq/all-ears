/// Built-in defaults and declared schema for the LLM-stage config slices
/// `docs/configuration.md` documents: `[llm]` (the shared backend `cleanup`/
/// `summarize` both use), `[cleanup]`, `[[summarize.preset]]`, and `[vocab]`
/// (the global vocabulary list `cleanup` merges in as a correction backstop).
/// Values match the reference config exactly.
///
/// Like ``EarsdConfigSchema``, this schema only declares its own slices; the
/// shared keys every tool needs (`data_root`, `output_root`, `[log]`, ...)
/// are ``Phase0ConfigSchema``'s concern. ``effectiveSchema``/
/// ``effectiveDefaults`` compose the two via ``ConfigSchema/union(_:)`` into
/// what `cleanup`/`summarize` actually validate against.
public enum LLMStagesConfigSchema {
  /// The smart default for `[cleanup] output` — a date-foldered
  /// `<date> - <title>.md` under `output_root`. Named here so the schema's
  /// defaults and `cleanup`'s own fallback can never drift apart.
  public static let defaultCleanupOutput = "{output_root}/{year}/{month}/{day}/{date} - {title}.md"

  public static let defaults: ConfigValue = .table([
    "llm": .table([
      // "llm-cli" | "command"; see docs/configuration.md's [llm] table.
      "backend": .string("llm-cli"),
      "model": .string(""),
      // Only consulted when backend == "command": a full shell command
      // template taking the prompt on stdin, completion on stdout.
      "command": .string(""),
    ]),
    "cleanup": .table([
      // Empty => the built-in cleanup prompt (CleanupPromptBuilder's default).
      "prompt_file": .string(""),
      "use_vocab": .bool(true),
      // The smart default for the *published* cleaned transcript: a
      // date-foldered `<date> - <title>.md` under `output_root`. Raw
      // transcripts never land here — they stay in the data store.
      "output": .string(defaultCleanupOutput),
    ]),
    "summarize": .table([
      "preset": .array([])
    ]),
    "vocab": .table([
      // Relative to data_root; empty => no global vocabulary list.
      "global": .string("")
    ]),
  ])

  /// Schema for a single `[[summarize.preset]]` element.
  private static let presetElementSchema = ConfigSchema(
    fields: [
      "name": ConfigSchema.Field(type: .string, description: "Preset name, selected via --preset."),
      "prompt_file": ConfigSchema.Field(
        type: .string, description: "Path to this preset's summary prompt."),
      "notes": ConfigSchema.Field(
        type: .string,
        description:
          "Path template for a companion notes file, read as plain Markdown alongside the transcript.",
        pathTemplateTokens: PathTemplate.publishedTokens),
      "out": ConfigSchema.Field(
        type: .string,
        description:
          "Path template for this preset's output; {notes} writes back over the notes file.",
        pathTemplateTokens: PathTemplate.presetOutTokens),
      "frontmatter": ConfigSchema.Field(
        type: .bool,
        description: "Emit the ears YAML frontmatter block; false writes the summary body alone."),
    ]
  )

  public static let schema = ConfigSchema(
    fields: [
      "llm": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "backend": ConfigSchema.Field(
              type: .string, description: "LLM backend: \"llm-cli\" or \"command\"."),
            "model": ConfigSchema.Field(
              type: .string, description: "Model id passed to the backend; empty uses its default."),
            "command": ConfigSchema.Field(
              type: .string,
              description:
                "Shell command template (backend=\"command\" only): prompt on stdin, completion on stdout."
            ),
          ]
        ),
        description: "Shared LLM backend used by cleanup and summarize."),
      "cleanup": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "prompt_file": ConfigSchema.Field(
              type: .string,
              description: "Path to a custom cleanup system prompt; empty uses the built-in prompt."
            ),
            "use_vocab": ConfigSchema.Field(
              type: .bool, description: "Apply the vocabulary list as a correction backstop."),
            "output": ConfigSchema.Field(
              type: .string,
              description: "Path template for the published cleaned transcript.",
              pathTemplateTokens: PathTemplate.publishedTokens),
          ]
        ),
        description: "Transcript-cleanup stage settings."),
      "summarize": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "preset": ConfigSchema.Field(
              type: .array, elementSchema: presetElementSchema,
              description:
                "Named summary presets: a name, a prompt_file, and optional notes/out/frontmatter."
            )
          ]
        ),
        description: "Summary stage settings."),
      "vocab": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "global": ConfigSchema.Field(
              type: .string,
              description: "Global vocabulary list, relative to data_root; empty means none.")
          ]
        ),
        description: "Vocabulary lists that back transcript correction."),
    ]
  )

  /// ``defaults`` merged with ``Phase0ConfigSchema/defaults``: the full set of
  /// built-in defaults a `cleanup`/`summarize` caller needs.
  public static let effectiveDefaults: ConfigValue = mergeConfigValues(
    base: Phase0ConfigSchema.defaults,
    overlay: defaults
  )

  /// ``schema`` composed with ``Phase0ConfigSchema/schema`` via
  /// ``ConfigSchema/union(_:)``: what `cleanup`/`summarize` actually validate
  /// their merged config against.
  public static let effectiveSchema = Phase0ConfigSchema.schema.union(schema)
}
