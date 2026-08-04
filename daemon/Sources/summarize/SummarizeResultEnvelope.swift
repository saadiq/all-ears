import Foundation

/// `summarize`'s `--json` result envelope (issue #63), schema
/// `allears.summarize/v1` — the result surface summarize never had in plain
/// mode (its pinned plain success behavior is byte-empty stdout).
///
/// - Success (exit 0, every preset succeeded): stdout is exactly this one
///   JSON document, emitted through `EarsCLISupport.ResultChannel`. `output`
///   is present only when exactly one preset ran (the single primary
///   artifact); `outputs` always carries one `{preset, path, ok}` entry per
///   preset.
/// - Failure (non-zero exit): stdout stays byte-empty; the **last line of
///   stderr** is the error variant (`ok: false`, `exit_class` carrying the
///   issue-#61 taxonomy label, `message`) — still carrying `outputs`, so
///   partial success ("2 of 3 presets") is finally expressible: exit 0 only
///   when all presets succeeded, but the per-preset entries name which files
///   were still written.
///
/// The wire contract is the checked-in JSON Schema
/// (`shared/stage-envelopes/summarize.v1.schema.json`); this struct is the
/// tool-local `Codable` twin (see `TranscribeResultEnvelope` for why it is
/// not a shared Swift type).
struct SummarizeResultEnvelope: Codable, Sendable, Equatable {
  /// The frozen schema identifier every v1 envelope carries.
  static let schemaID = "allears.summarize/v1"

  var schema: String
  var ok: Bool
  /// The primary artifact's absolute path — present only when exactly one
  /// preset ran and succeeded (single-preset runs; never `--all-presets`
  /// over several presets).
  var output: String? = nil
  /// One entry per selected preset, in run order — the per-preset result
  /// surface that makes partial success expressible.
  var outputs: [SummarizePipeline.PresetResult]? = nil
  /// Success only: non-fatal notes. Starts empty; additive keys are free.
  var warnings: [String]? = nil
  /// Success only: headline counts, mirroring what `run.summary` computes.
  var stats: Stats? = nil
  /// Failure only: the exit-code taxonomy label (issue #61).
  var exitClass: String? = nil
  /// Failure only: the human-readable error that ended the run.
  var message: String? = nil

  struct Stats: Codable, Sendable, Equatable {
    var presets: Int
  }

  enum CodingKeys: String, CodingKey {
    case schema, ok, output, outputs, warnings, stats, message
    case exitClass = "exit_class"
  }

  static func success(results: [SummarizePipeline.PresetResult]) -> Self {
    Self(
      schema: schemaID,
      ok: true,
      output: results.count == 1 ? results[0].path : nil,
      outputs: results,
      warnings: [],
      stats: Stats(presets: results.count))
  }

  static func failure(
    exitClass: String, message: String, results: [SummarizePipeline.PresetResult]
  ) -> Self {
    Self(
      schema: schemaID,
      ok: false,
      outputs: results.isEmpty ? nil : results,
      exitClass: exitClass,
      message: message)
  }
}
