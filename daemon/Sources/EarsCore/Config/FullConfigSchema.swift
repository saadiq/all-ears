/// The whole configuration surface, every tool's slice composed into one
/// schema and one defaults tree: ``Phase0ConfigSchema`` (shared keys) unioned
/// with ``EarsdConfigSchema``, ``LLMStagesConfigSchema``, and
/// ``TranscribeConfigSchema``. No single tool validates against this — each
/// validates only its own slice — but `ears config describe` renders it so a
/// user sees every setting across the suite in one place, regardless of which
/// tool owns it.
public enum FullConfigSchema {
  public static let schema =
    EarsdConfigSchema.effectiveSchema
    .union(LLMStagesConfigSchema.schema)
    .union(TranscribeConfigSchema.schema)

  public static let defaults: ConfigValue = mergeConfigLayers([
    EarsdConfigSchema.effectiveDefaults,
    LLMStagesConfigSchema.defaults,
    TranscribeConfigSchema.defaults,
  ])
}
