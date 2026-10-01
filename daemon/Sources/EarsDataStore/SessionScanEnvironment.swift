import EarsConfig
import EarsCore
import Foundation

/// The config-derived facts a disk scan needs: where the data root is, how
/// `cleanup` resolves its published path, and the on-end chain an undeclared
/// session inherits. Resolved once and shared by every session a reader
/// scans, so each read-only surface answers "what happened to this session"
/// from the same resolution.
public struct SessionScanEnvironment: Sendable {
  public var dataRoot: URL
  public var cleanupTemplate: PathTemplate
  public var outputRoot: String
  public var weekNumbering: WeekNumbering
  public var onEndChain: [OnEndStage]
  /// `[earsd.sessions] min_words` / `min_speech_seconds` as the daemon
  /// resolved them, so the pipeline view names a stopped chain for what it is
  /// (`skipped (empty transcript)`) instead of reporting absent artifacts.
  public var emptiness: TranscriptEmptinessPolicy
  /// Each `[[summarize.preset]]`'s own `out` template, for the presets that
  /// name one — the summaries a sibling sweep beside the cleaned transcript
  /// cannot find. `{notes}` is already replaced by the preset's `notes`
  /// template, which is what `summarize` expands it to.
  public var summaryOutputs: [PathTemplate]

  public init(
    dataRoot: URL, cleanupTemplate: PathTemplate, outputRoot: String,
    weekNumbering: WeekNumbering, onEndChain: [OnEndStage],
    emptiness: TranscriptEmptinessPolicy = .defaults, summaryOutputs: [PathTemplate] = []
  ) {
    self.dataRoot = dataRoot
    self.cleanupTemplate = cleanupTemplate
    self.outputRoot = outputRoot
    self.weekNumbering = weekNumbering
    self.onEndChain = onEndChain
    self.emptiness = emptiness
    self.summaryOutputs = summaryOutputs
  }

  /// Loads the same layered config every tool reads and resolves the scan
  /// environment from it.
  public static func load(configFlag: String?) -> Result<
    SessionScanEnvironment, SessionScanConfigError
  > {
    let inputs = ConfigLoadInputs(
      configFlag: configFlag,
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    switch loadConfig(inputs) {
    case .failure(let error):
      return .failure(
        SessionScanConfigError(description: "error: could not load config: \(error)"))
    case .success(let loaded):
      return .success(resolve(from: loaded.value))
    }
  }

  /// Resolves the environment from an already-loaded config.
  /// `[cleanup] output`, `output_root`, and `week_numbering` mirror exactly
  /// what `CleanupRuntime` resolves, so the reconstructed published path can
  /// only agree with the writer's.
  public static func resolve(from config: ConfigValue) -> SessionScanEnvironment {
    let dataRoot = stringValue(config, ["data_root"])
    let template = stringValue(config, ["cleanup", "output"])
    return SessionScanEnvironment(
      dataRoot: URL(fileURLWithPath: dataRoot.isEmpty ? "." : dataRoot),
      cleanupTemplate: PathTemplate(
        template.isEmpty ? LLMStagesConfigSchema.defaultCleanupOutput : template),
      outputRoot: stringValue(config, ["output_root"]),
      weekNumbering: WeekNumbering(configValue: stringValue(config, ["week_numbering"])),
      onEndChain: onEndChain(config),
      emptiness: emptinessPolicy(config),
      summaryOutputs: summaryOutputs(config))
  }

  /// `[[summarize.preset]]` `out` templates. A preset's `{notes}` names the
  /// file its `notes` template resolves to, so the two compose textually; an
  /// `out` that uses `{notes}` on a preset with no `notes` names no file and
  /// is dropped. (`summarize` may also *locate* a note near the templated
  /// path; that file is found through the cleaned copy's `note:` link.)
  private static func summaryOutputs(_ config: ConfigValue) -> [PathTemplate] {
    guard case .array(let presets)? = nestedValue(config, ["summarize", "preset"]) else {
      return []
    }
    return presets.compactMap { preset in
      let out = stringValue(preset, ["out"])
      guard !out.isEmpty else { return nil }
      guard out.contains("{notes}") else { return PathTemplate(out) }
      let notes = stringValue(preset, ["notes"])
      guard !notes.isEmpty else { return nil }
      return PathTemplate(out.replacingOccurrences(of: "{notes}", with: notes))
    }
  }

  /// The resolved `[earsd.sessions] on_end_stages` — see
  /// ``OnEndChainPolicy/configured(fromRaw:)`` for how an absent key, an
  /// explicit list, and `[]` differ.
  private static func onEndChain(_ config: ConfigValue) -> [OnEndStage] {
    OnEndChainPolicy.configured(
      fromRaw: stringArray(config, ["earsd", "sessions", "on_end_stages"]))
  }

  /// `[earsd.sessions]`'s two emptiness thresholds, each falling back to the
  /// shipped default when unset — the same resolution
  /// `DaemonConfigResolution` does for the daemon, so both ends agree on
  /// which transcripts are empty.
  private static func emptinessPolicy(_ value: ConfigValue) -> TranscriptEmptinessPolicy {
    var policy = TranscriptEmptinessPolicy.defaults
    if case .int(let words)? = nestedValue(value, ["earsd", "sessions", "min_words"]) {
      policy.minWords = words
    }
    // `.int` as well as `.double`: TOML's `5` and `5.0` are different
    // literals, and the schema accepts either (`ConfigValueKind.satisfies`).
    switch nestedValue(value, ["earsd", "sessions", "min_speech_seconds"]) {
    case .double(let seconds)?: policy.minSpeechSeconds = seconds
    case .int(let seconds)?: policy.minSpeechSeconds = Double(seconds)
    default: break
    }
    return policy
  }

  private static func stringValue(_ config: ConfigValue, _ path: [String]) -> String {
    guard case .string(let value)? = nestedValue(config, path) else { return "" }
    return value
  }

  /// `nil` when the key is absent — a distinction the caller needs, since an
  /// explicit `[]` means something different from no key at all.
  private static func stringArray(_ config: ConfigValue, _ path: [String]) -> [String]? {
    guard case .array(let entries)? = nestedValue(config, path) else { return nil }
    return entries.compactMap { entry in
      guard case .string(let value) = entry else { return nil }
      return value
    }
  }

  /// The value at a dotted config path, or `nil` when any segment is absent
  /// or isn't a table.
  private static func nestedValue(_ config: ConfigValue, _ path: [String]) -> ConfigValue? {
    var current = config
    for key in path {
      guard case .table(let table) = current, let next = table[key] else { return nil }
      current = next
    }
    return current
  }
}

/// The config could not be loaded, so no scan environment exists.
public struct SessionScanConfigError: Error, Sendable, CustomStringConvertible {
  public var description: String

  public init(description: String) {
    self.description = description
  }
}
