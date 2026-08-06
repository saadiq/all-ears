import Foundation

/// `cleanup`'s `--json` result envelope (issue #63), schema
/// `allears.cleanup/v1` — the versioned, additive-friendly result surface
/// that grows while the plain one-line contract stays frozen.
///
/// - Success (exit 0): stdout is exactly this one JSON document, emitted
///   through `EarsCLISupport.ResultChannel`. `output` is the primary artifact
///   (the `.clean.md`); `outputs` lists every written artifact (the markdown
///   plus its `.clean.json` sidecar).
/// - Failure (non-zero exit): stdout stays byte-empty; the **last line of
///   stderr** is the error variant (`ok: false`, `exit_class` carrying the
///   issue-#61 taxonomy label, `message`). "Empty stdout ⇒ no result" holds
///   in both modes.
///
/// The wire contract is the checked-in JSON Schema
/// (`shared/stage-envelopes/cleanup.v1.schema.json`); this struct is the
/// tool-local `Codable` twin (see `TranscribeResultEnvelope` for why it is
/// not a shared Swift type).
struct CleanupResultEnvelope: Codable, Sendable, Equatable {
  /// The frozen schema identifier every v1 envelope carries.
  static let schemaID = "allears.cleanup/v1"

  var schema: String
  var ok: Bool
  /// Success only: the primary artifact's absolute path (`.clean.md`).
  var output: String? = nil
  /// Success only: every written artifact, primary first.
  var outputs: [String]? = nil
  /// Success only: non-fatal notes. Starts empty; additive keys are free.
  var warnings: [String]? = nil
  /// Success only: headline counts, mirroring what `run.summary` computes.
  var stats: Stats? = nil
  /// Failure only: the exit-code taxonomy label (issue #61).
  var exitClass: String? = nil
  /// Failure only: the human-readable error that ended the run.
  var message: String? = nil

  struct Stats: Codable, Sendable, Equatable {
    var segments: Int
    var accepted: Int
    var fallback: Int
    var skipped: Int
    /// LLM calls the run made — turns are batched by `[cleanup] chunk_seconds`,
    /// so this is what a slow run's duration divides by, not `segments`.
    var chunks: Int
  }

  enum CodingKeys: String, CodingKey {
    case schema, ok, output, outputs, warnings, stats, message
    case exitClass = "exit_class"
  }

  static func success(output: String, outputs: [String], stats: Stats) -> Self {
    Self(
      schema: schemaID, ok: true, output: output, outputs: outputs, warnings: [], stats: stats)
  }

  static func failure(exitClass: String, message: String) -> Self {
    Self(schema: schemaID, ok: false, exitClass: exitClass, message: message)
  }
}
