import ArgumentParser
import EarsCLISupport
import Foundation

/// Reads one or more transcripts and writes summaries from configured prompts.
/// See `docs/specs/llm-stages.md`.
///
/// Every invocation runs through `EarsCLI.run(tool:version:arguments:work:)` --
/// the day-one config/logging contract every tool satisfies. The real work is
/// the call's `work` closure, so the final `run.summary` is logged after it
/// completes and reflects its true outcome, never a premature `status=ok`
/// (issue #25). A normal invocation (neither `--print-config` nor
/// `--config-path`) runs ``SummarizeRuntime``: it resolves the LLM backend and
/// the requested `[[summarize.preset]]` entries, and summarizes `transcripts`.
@main
struct Summarize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "summarize",
    // The frozen plain-mode stdout contract (issue #62) and the shared
    // exit-code taxonomy (issue #61), documented where an operator will
    // actually look for them.
    discussion: PlainModeContract.helpEpilogue + "\n\n" + ExitClass.helpEpilogue
  )

  // Optional, not required: `--print-config`/`--config-path` must work with
  // no positional arguments at all -- checked as a normal-run requirement
  // below, not enforced by ArgumentParser itself.
  @Argument(help: "Path(s) to the transcript(s) to summarize.")
  var transcripts: [String] = []

  @Option(name: .customLong("config"), help: "Path to a TOML config file.")
  var config: String?

  @Flag(
    name: .customLong("print-config"), help: "Print the resolved, merged config as TOML and exit.")
  var printConfig = false

  @Flag(
    name: .customLong("config-path"),
    help: "Print which config file would be loaded (or that none was found) and exit."
  )
  var configPath = false

  @Option(
    name: .customLong("log-level"),
    help: "Override the effective log level (debug|info|notice|error).")
  var logLevel: String?

  @Option(name: .customLong("log-file"), help: "Override the JSON Lines log file path.")
  var logFile: String?

  @Flag(
    name: [.customShort("v"), .customLong("verbose")],
    help:
      "Verbose diagnostics (shorthand for --log-level debug). Diagnostics go to stderr only; stdout keeps the plain-mode contract."
  )
  var verbose = false

  @Option(name: .customLong("preset"), help: "Preset(s) to run; repeatable.")
  var preset: [String] = []

  @Flag(name: .customLong("all-presets"), help: "Run every configured preset.")
  var allPresets = false

  @Option(name: .customLong("out"), help: "Override the output path (single-preset runs only).")
  var out: String?

  @Option(name: .customLong("model"), help: "Override the LLM model for this run.")
  var model: String?

  @Flag(
    name: .customLong("json"),
    help:
      "Emit a versioned JSON result envelope (allears.summarize/v1) as the only stdout document on success; on failure stdout stays empty and the last stderr line is the error envelope."
  )
  var json = false

  @Option(
    name: .customLong("set"),
    help:
      "Override any config setting: --set path.to.key=value (repeatable). Values are typed (true/false, ints, floats); use --set-string to force a string."
  )
  var set: [String] = []

  @Option(
    name: .customLong("set-string"),
    help:
      "Like --set but the value is always a string: --set-string path.to.key=value (repeatable)."
  )
  var setString: [String] = []

  func run() async throws {
    let arguments = EarsCLI.Arguments(
      config: config,
      printConfig: printConfig,
      configPath: configPath,
      // `--verbose` is shorthand for `--log-level debug`; an explicit
      // `--log-level` wins so the two spellings never fight. It only widens
      // what reaches stderr and the log file — stdout is untouched, per the
      // plain-mode contract (issue #62).
      logLevel: logLevel ?? (verbose ? "debug" : nil),
      logFile: logFile,
      set: set,
      setString: setString
    )

    // Snapshot the flags into locals the `@Sendable` work closure captures.
    let transcripts = self.transcripts
    let preset = self.preset
    let allPresets = self.allPresets
    let out = self.out
    let model = self.model
    let json = self.json

    // The real run happens inside `work`, between `run.start` and
    // `run.summary`; the summary reflects the outcome we return here, never a
    // premature `status=ok` (issue #25). The `--print-config`/`--config-path`
    // fast paths return before `work` runs.
    let diagnostics = RunDiagnostics()
    let presetResults = PresetResultLog()
    let exitCode = await EarsCLI.run(
      tool: "summarize", version: "0.1.0", arguments: arguments
    ) { _ in
      guard !transcripts.isEmpty else {
        // A usage error, but checked here (not by ArgumentParser) because
        // `--print-config`/`--config-path` must work with no positional at
        // all — so it adopts the same EX_USAGE code ArgumentParser exits with.
        let message = "error: at least one transcript path is required"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        diagnostics.recordError(message)
        return RunOutcome(class: .usage, error: message)
      }
      return await SummarizeRuntime.run(
        arguments: arguments,
        inputs: SummarizeCLIInputs(
          transcriptPaths: transcripts,
          presetNames: preset,
          allPresets: allPresets,
          out: out,
          model: model
        ),
        diagnostics: diagnostics,
        presetResults: presetResults,
        emitJSONEnvelope: json
      )
    }
    // The `--json` failure contract (issue #63): stdout stays byte-empty
    // (the runtime never emitted a success envelope) and the *last line of
    // stderr* is the error envelope — written here, after `EarsCLI.run` has
    // already echoed the failed run's `run.summary` to stderr, so nothing
    // can land after it. `outputs[]` still carries any per-preset results,
    // making partial success ("2 of 3 presets") expressible.
    if exitCode != 0, json {
      let envelope = SummarizeResultEnvelope.failure(
        exitClass: ExitClass.label(forCode: exitCode),
        message: diagnostics.lastError ?? "error: summarize failed (exit \(exitCode))",
        results: presetResults.results)
      if let line = StageEnvelopeJSON.encodeLine(envelope) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
      }
    }
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }
}
