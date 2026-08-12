import EarsCLISupport
import EarsConfig
import EarsCore
import EarsDataStore
import EarsLLMKit
import Foundation
import Synchronization

/// Thread-safe collector for ``SummarizePipeline``'s per-preset outcomes,
/// shared between the runtime (which builds the `--json` success envelope
/// from it) and the command entry point (which builds the failure envelope's
/// `outputs[]` from it after a non-zero exit) — the same
/// `Mutex`-behind-a-class shape as `EarsCLISupport.RunDiagnostics`, and for
/// the same reason: genuinely `Sendable` without `@unchecked`.
final class PresetResultLog: Sendable {
  private let state = Mutex<[SummarizePipeline.PresetResult]>([])

  func record(_ result: SummarizePipeline.PresetResult) {
    state.withLock { $0.append(result) }
  }

  var results: [SummarizePipeline.PresetResult] { state.withLock { $0 } }
}

/// `summarize`'s CLI inputs beyond the shared day-one flags, per
/// `docs/specs/llm-stages.md`'s
/// `summarize <transcript.md> [more...] [--preset ...] [--all-presets] [--out] [--model]`.
struct SummarizeCLIInputs: Sendable {
  var transcriptPaths: [String]
  /// `--session <id>`: summarize the session's *cleaned* transcript, falling
  /// back to its raw one when no clean has been published.
  var sessionID: String?
  var presetNames: [String]
  var allPresets: Bool
  var out: String?
  /// `--notes <path>`: an ad-hoc companion notes file (single-preset runs).
  var notes: String?
  var model: String?
}

/// `summarize`'s real, normal-run entry point: loads config against
/// ``LLMStagesConfigSchema``, resolves the LLM backend and the requested
/// `[[summarize.preset]]` entries (reading each preset's `prompt_file`
/// relative to `data_root`), then delegates to ``SummarizePipeline``.
/// Mirrors `cleanup`'s `CleanupRuntime`/`CleanupPipeline` split.
enum SummarizeRuntime {
  static func run(
    arguments: EarsCLI.Arguments, inputs: SummarizeCLIInputs,
    diagnostics: RunDiagnostics = RunDiagnostics(),
    presetResults: PresetResultLog = PresetResultLog(),
    emitJSONEnvelope: Bool = false
  ) async -> RunOutcome {
    // In plain mode `summarize` emits no result line, but batch stdout still
    // carries nothing else — the channel is active either way so a stray
    // dependency `print` lands on stderr instead of stdout. With `--json`
    // (issue #63) the channel is also the success envelope's only route to
    // the real stdout.
    let resultChannel = ResultChannel.activate()
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    let loadInputs: ConfigLoadInputs
    switch EarsCLI.resolveLoadInputs(
      arguments, environment: environment, homeDirectory: homeDirectory)
    {
    case .success(let value): loadInputs = value
    case .failure(let error):
      writeStderr(error.message)
      diagnostics.recordError(error.message)
      return RunOutcome(class: .usage, error: error.message)
    }

    let loaded: LoadedConfig
    switch loadConfig(
      loadInputs,
      defaults: LLMStagesConfigSchema.effectiveDefaults,
      schema: LLMStagesConfigSchema.effectiveSchema
    ) {
    case .success(let value): loaded = value
    case .failure(let error):
      let message = describe(error)
      writeStderr(message)
      diagnostics.recordError(message)
      // Unusable config is a stage failure (exit-code taxonomy, issue #61).
      return RunOutcome(class: .stageFailed, error: message)
    }

    let root = loaded.value
    let dataRootPath = stringValue(root, ["data_root"])
    let dataRoot = URL(fileURLWithPath: dataRootPath.isEmpty ? "." : dataRootPath)
    let outputRoot = stringValue(root, ["output_root"])
    let weekNumbering = WeekNumbering(configValue: stringValue(root, ["week_numbering"]))
    let cleanupOutput = PathTemplate(
      stringValue(root, ["cleanup", "output"], default: LLMStagesConfigSchema.defaultCleanupOutput))

    let transcriptPaths: [String]
    if let sessionID = inputs.sessionID {
      switch sessionTranscriptPath(
        sessionID: sessionID, dataRoot: dataRoot, outputRoot: outputRoot,
        weekNumbering: weekNumbering, cleanupOutput: cleanupOutput)
      {
      case .success(let path): transcriptPaths = [path]
      case .failure(let failure):
        writeStderr(failure.message)
        diagnostics.recordError(failure.message)
        return RunOutcome(class: .inputMissing, error: failure.message)
      }
    } else {
      transcriptPaths = inputs.transcriptPaths
    }

    let backend = stringValue(root, ["llm", "backend"], default: "llm-cli")
    let model = inputs.model ?? stringValue(root, ["llm", "model"])
    let configuredCommand = stringValue(root, ["llm", "command"])
    let command =
      backend == "command" ? configuredCommand : "llm" + (model.isEmpty ? "" : " -m \(model)")
    guard !command.isEmpty else {
      let message = "error: no [llm] command resolved (backend=\(backend), model='\(model)')"
      writeStderr(message)
      diagnostics.recordError(message)
      return RunOutcome(class: .stageFailed, error: message)
    }
    let llmBackend = CommandLLMBackend(
      info: LLMBackendInfo(name: backend, model: model.isEmpty ? nil : model), command: command)

    let configuredPresets = presetEntries(root)
    let selected: [ConfigPreset]
    if inputs.allPresets {
      selected = configuredPresets
    } else if !inputs.presetNames.isEmpty {
      selected = configuredPresets.filter { inputs.presetNames.contains($0.name) }
      let missing = Set(inputs.presetNames).subtracting(selected.map(\.name))
      guard missing.isEmpty else {
        // Like an unknown --session id: the named input doesn't resolve.
        let message = "error: unknown preset(s): \(missing.sorted().joined(separator: ", "))"
        writeStderr(message)
        diagnostics.recordError(message)
        return RunOutcome(class: .inputMissing, error: message)
      }
    } else {
      let message = "error: at least one --preset is required (or pass --all-presets)"
      writeStderr(message)
      diagnostics.recordError(message)
      return RunOutcome(class: .usage, error: message)
    }
    guard !selected.isEmpty else {
      // `--all-presets` against a config with no presets: unusable config.
      let message = "error: no [[summarize.preset]] entries are configured"
      writeStderr(message)
      diagnostics.recordError(message)
      return RunOutcome(class: .stageFailed, error: message)
    }

    // `--notes` names one companion file, so it can only mean something for
    // one preset — a precise error rather than silently applying it to all.
    guard inputs.notes == nil || selected.count == 1 else {
      let message = "error: --notes applies to a single preset; \(selected.count) were selected"
      writeStderr(message)
      diagnostics.recordError(message)
      return RunOutcome(class: .usage, error: message)
    }

    let presets = selected.map { preset in
      SummarizePipeline.Preset(
        name: preset.name,
        promptContent: readPromptFile(preset.promptFile, dataRoot: dataRoot),
        notes: preset.notes.map(PathTemplate.init),
        out: preset.out.map(PathTemplate.init),
        frontmatter: preset.frontmatter)
    }

    var dependencies = SummarizePipeline.Dependencies.production(
      llmBackend: llmBackend, onError: { diagnostics.recordError($0) })
    // Collected for the `--json` envelope in both dispositions: the success
    // envelope here, the failure envelope's `outputs[]` in `Summarize.run()`.
    dependencies.onPresetResult = { presetResults.record($0) }

    let code = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: transcriptPaths, presets: presets, out: inputs.out,
        notes: inputs.notes, outputRoot: outputRoot, weekNumbering: weekNumbering),
      dependencies: dependencies
    )

    // The `--json` success envelope (issue #63): exactly one JSON document,
    // through the guarded channel — the only remaining route to real stdout.
    // On any non-zero exit stdout stays byte-empty; the error envelope is the
    // command entry point's job (it must land *after* the failed run's
    // `run.summary` stderr echo, as the last line of stderr).
    if emitJSONEnvelope, code == 0,
      let line = StageEnvelopeJSON.encodeLine(
        SummarizeResultEnvelope.success(results: presetResults.results))
    {
      resultChannel.emitResult(line)
    }
    return diagnostics.outcome(exitCode: code)
  }

  /// Resolves what `--session <id>` summarizes: the session's **cleaned**
  /// transcript, which is wherever `[cleanup] output`'s template put it —
  /// re-expanded here against the stored raw transcript's own frontmatter,
  /// the same context `cleanup` published by, so no extra bookkeeping is
  /// needed to find it. With no clean published (cleanup not run, or run
  /// under a different template) the raw transcript stands in, so the
  /// command still does something useful.
  private static func sessionTranscriptPath(
    sessionID: String, dataRoot: URL, outputRoot: String, weekNumbering: WeekNumbering,
    cleanupOutput: PathTemplate
  ) -> Result<String, ResolutionFailure> {
    let rawURL = DataStoreLayout.sessionTranscriptFile(dataRoot: dataRoot, sessionID: sessionID)
    guard let markdown = try? String(contentsOf: rawURL, encoding: .utf8),
      let frontmatter = try? TranscriptParser.parseFrontmatter(markdown)
    else {
      return .failure(
        ResolutionFailure(
          message: "error: session '\(sessionID)' has no readable transcript at \(rawURL.path) "
            + "(run `transcribe --session \(sessionID)` first)"))
    }
    let cleanPath = cleanupOutput.expand(
      PathTemplate.Context(
        outputRoot: outputRoot,
        start: frontmatter.started ?? frontmatter.range.start,
        weekNumbering: weekNumbering,
        session: frontmatter.session,
        slug: frontmatter.sources.map(\.pathSafe).joined(separator: "_"),
        title: frontmatter.title,
        fallbackName: rawURL.deletingPathExtension().lastPathComponent))
    return .success(
      FileManager.default.fileExists(atPath: cleanPath) ? cleanPath : rawURL.path)
  }

  /// A resolution failure carrying its own already-formatted message.
  private struct ResolutionFailure: Error {
    var message: String
  }

  private struct ConfigPreset {
    var name: String
    var promptFile: String
    var notes: String?
    var out: String?
    var frontmatter: Bool
  }

  private static func presetEntries(_ root: ConfigValue) -> [ConfigPreset] {
    guard case .table(let rootTable) = root,
      case .table(let summarizeTable)? = rootTable["summarize"],
      case .array(let entries)? = summarizeTable["preset"]
    else { return [] }
    return entries.compactMap { entry -> ConfigPreset? in
      guard case .table(let fields) = entry,
        case .string(let name)? = fields["name"]
      else { return nil }
      func string(_ key: String) -> String? {
        guard case .string(let value)? = fields[key], !value.isEmpty else { return nil }
        return value
      }
      var frontmatter = true
      if case .bool(let value)? = fields["frontmatter"] { frontmatter = value }
      return ConfigPreset(
        name: name, promptFile: string("prompt_file") ?? "",
        notes: string("notes"), out: string("out"), frontmatter: frontmatter)
    }
  }

  /// An unset/unreadable prompt file yields empty content — a preset with no
  /// prompt still runs (see ``SummarizePipeline/Preset``'s doc comment).
  private static func readPromptFile(_ path: String, dataRoot: URL) -> String {
    guard !path.isEmpty else { return "" }
    let url =
      path.hasPrefix("/") ? URL(fileURLWithPath: path) : dataRoot.appendingPathComponent(path)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  private static func describe(_ error: ConfigLoadError) -> String {
    switch error {
    case .fileReadFailed(let path, let message):
      return "error: could not read config file at \(path): \(message)"
    case .tomlParseFailed(let path, let message):
      return "error: invalid TOML in config file at \(path): \(message)"
    case .validation(let errors):
      let details = errors.map { "  - \($0.message)" }.joined(separator: "\n")
      return "error: invalid config:\n\(details)"
    }
  }

  private static func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  private static func stringValue(
    _ config: ConfigValue, _ path: [String], default defaultValue: String = ""
  ) -> String {
    guard case .string(let value) = walk(config, path) else { return defaultValue }
    return value
  }

  private static func walk(_ config: ConfigValue, _ path: [String]) -> ConfigValue? {
    var current = config
    for key in path {
      guard case .table(let table) = current, let next = table[key] else { return nil }
      current = next
    }
    return current
  }
}
