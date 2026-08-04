import EarsCLISupport
import EarsConfig
import EarsCore
import EarsLogging
import Foundation

/// `transcribe`'s real, normal-run (no `--print-config`/`--config-path`)
/// entry point: loads config against the shared `Phase0ConfigSchema` (the
/// same schema `EarsCLI.run` already validated once for the day-one
/// contract -- this is a second, `transcribe`-scoped load, exactly the
/// pattern `EarsdRuntime`'s own doc comment describes and `loadConfig`'s
/// invites), resolves `data_root`/`output_root`/`[transcribe]`'s
/// `backend`/`model`/`compute`, and delegates to ``TranscribePipeline`` for
/// the actual behaviour.
///
/// This is deliberately thin: real environment/home-directory/config-file
/// reads live here and nowhere else, so ``TranscribePipeline`` -- almost
/// all of `transcribe`'s actual logic -- never needs a real environment or
/// config file to be unit tested. Mirrors `earsd`'s
/// `EarsdRuntime`/`DaemonConfigResolution` split.
enum TranscribeRuntime {
  static func run(
    arguments: EarsCLI.Arguments, inputs: TranscribePipeline.Inputs,
    diagnostics: RunDiagnostics = RunDiagnostics(),
    spans: StageSpans? = nil
  ) async -> RunOutcome {
    // Guard the stdout path contract before anything else runs: after this,
    // only `resultChannel.emitResult` can reach the real stdout — a stray
    // `print` (ours or a dependency's) lands on stderr instead of forging a
    // plausible-looking result line.
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
      return RunOutcome(class: .usage, error: error.message)
    }

    let loaded: LoadedConfig
    switch loadConfig(
      loadInputs,
      defaults: TranscribeConfigSchema.effectiveDefaults,
      schema: TranscribeConfigSchema.effectiveSchema
    ) {
    case .success(let value): loaded = value
    case .failure(let error):
      let message = describe(error)
      writeStderr(message)
      // Unusable config is a stage failure (exit-code taxonomy, issue #61).
      return RunOutcome(class: .stageFailed, error: message)
    }

    let root = loaded.value
    let dataRootPath = stringValue(root, ["data_root"])
    let configuredSocketPath = stringValue(root, ["socket_path"])
    guard !dataRootPath.isEmpty else {
      let message = "error: data_root is not configured"
      writeStderr(message)
      return RunOutcome(class: .stageFailed, error: message)
    }
    let outputRootPath = stringValue(root, ["output_root"])
    let backendName = stringValue(root, ["transcribe", "backend"], default: "fluidaudio")
    let modelIdentifier = stringValue(root, ["transcribe", "model"])
    let compute = computePreference(
      stringValue(root, ["transcribe", "compute"], default: "automatic"))

    // Diarization is opt-in (`[diarize].backend`, default "none"): it downloads
    // a model and costs ANE time, so off by default per the zero-config rule.
    let diarizeBackend = stringValue(root, ["diarize", "backend"], default: "none")
    let diarizeModel = stringValue(root, ["diarize", "model"])
    let diarizeCompute = computePreference(
      stringValue(root, ["diarize", "compute"], default: "automatic"))

    // Same precedence and default as `ears`/`earsd` — for the best-effort
    // `job.publish` progress feed a `--session` run reports through.
    let socketPath =
      configuredSocketPath.isEmpty
      ? DefaultSocketPath.resolve(dataRoot: dataRootPath) : configuredSocketPath

    var dependencies = TranscribePipeline.Dependencies.production(
      loadOptions: LoadOptions(
        modelIdentifier: modelIdentifier.isEmpty ? nil : modelIdentifier,
        compute: compute),
      diarizeBackendName: diarizeBackend,
      diarizerLoadOptions: LoadOptions(
        modelIdentifier: diarizeModel.isEmpty ? nil : diarizeModel,
        compute: diarizeCompute),
      onError: { diagnostics.recordError($0) },
      onSummary: { diagnostics.recordSummary($0) },
      spans: spans)
    // The result-line contract's only route to the real stdout.
    dependencies.writeStdout = { line in resultChannel.emitResult(line) }
    // Test-only: `ALLEARS_TRANSCRIBE_BACKEND=null` swaps the ASR backend for
    // a NullTranscriber so smoke tests can drive a real successful run — see
    // NullTranscriberOverride.swift. A no-op unless a harness set the var.
    applyNullTranscriberOverrideIfRequested(&dependencies)

    let code = await TranscribePipeline.run(
      inputs: inputs,
      dataRoot: URL(fileURLWithPath: dataRootPath),
      outputRoot: URL(fileURLWithPath: outputRootPath.isEmpty ? "." : outputRootPath),
      backendName: backendName,
      socketPath: socketPath,
      dependencies: dependencies
    )
    return diagnostics.outcome(exitCode: code)
  }

  /// `transcribe --file`'s entry point: the file path needs only the model
  /// selection config (`[transcribe]`'s `backend`/`model`/`compute`), never
  /// `data_root`/`output_root`, so this resolves that much and delegates to
  /// ``TranscribeFilePipeline``. Kept here beside ``run(arguments:inputs:)`` so
  /// both share the same private config readers rather than duplicating them.
  static func runFiles(
    arguments: EarsCLI.Arguments, inputs: TranscribeFilePipeline.Inputs,
    diagnostics: RunDiagnostics = RunDiagnostics()
  ) async -> RunOutcome {
    // A `--file` run emits no result line, but batch stdout still carries
    // nothing else — activate the channel so a stray dependency `print`
    // lands on stderr instead of stdout.
    _ = ResultChannel.activate()
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    let loadInputs: ConfigLoadInputs
    switch EarsCLI.resolveLoadInputs(
      arguments, environment: environment, homeDirectory: homeDirectory)
    {
    case .success(let value): loadInputs = value
    case .failure(let error):
      writeStderr(error.message)
      return RunOutcome(class: .usage, error: error.message)
    }

    let loaded: LoadedConfig
    switch loadConfig(
      loadInputs,
      defaults: TranscribeConfigSchema.effectiveDefaults,
      schema: TranscribeConfigSchema.effectiveSchema
    ) {
    case .success(let value): loaded = value
    case .failure(let error):
      let message = describe(error)
      writeStderr(message)
      // Unusable config is a stage failure (exit-code taxonomy, issue #61).
      return RunOutcome(class: .stageFailed, error: message)
    }

    let root = loaded.value
    let backendName = stringValue(root, ["transcribe", "backend"], default: "fluidaudio")
    let modelIdentifier = stringValue(root, ["transcribe", "model"])
    let compute = computePreference(
      stringValue(root, ["transcribe", "compute"], default: "automatic"))

    // Same `[diarize]` resolution as `run(arguments:inputs:)` — a standalone
    // file diarizes too when `[diarize].backend = "sortformer"`.
    let diarizeBackend = stringValue(root, ["diarize", "backend"], default: "none")
    let diarizeModel = stringValue(root, ["diarize", "model"])
    let diarizeCompute = computePreference(
      stringValue(root, ["diarize", "compute"], default: "automatic"))

    let code = await TranscribeFilePipeline.run(
      inputs: inputs,
      backendName: backendName,
      dependencies: .production(
        loadOptions: LoadOptions(
          modelIdentifier: modelIdentifier.isEmpty ? nil : modelIdentifier,
          compute: compute),
        diarizeBackendName: diarizeBackend,
        diarizerLoadOptions: LoadOptions(
          modelIdentifier: diarizeModel.isEmpty ? nil : diarizeModel,
          compute: diarizeCompute),
        onError: { diagnostics.recordError($0) },
        onSummary: { diagnostics.recordSummary($0) }))
    return diagnostics.outcome(exitCode: code)
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

  /// Maps `[transcribe].compute`'s documented values (`docs/configuration.md`:
  /// `"ane" | "gpu" | "cpu"`) to the backend-agnostic ``ComputePreference``
  /// FluidAudio's shim (``resolveComputeUnits(for:)``) already understands.
  /// Anything else (including the unset default) is `.automatic`, letting
  /// the backend choose -- never a silent, wrong-but-plausible guess.
  /// Internal (not private) so ``FollowRuntime`` resolves the same key the
  /// same way instead of duplicating the mapping.
  static func computePreference(_ raw: String) -> ComputePreference {
    switch raw {
    case "ane": return .neuralEngine
    case "gpu": return .gpu
    case "cpu": return .cpu
    default: return .automatic
    }
  }

  // MARK: - Small ConfigValue readers (mirrors EarsCLI's own private helpers)

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
