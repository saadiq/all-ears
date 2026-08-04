import Foundation

/// The daemon-side decode of a pipeline stage's `--json` result envelope —
/// the consumer half (issue #64) of the producer contract the stages ship
/// (issue #63; wire shape frozen in
/// `shared/stage-envelopes/<tool>.v1.schema.json`).
///
/// One deliberately lenient `Decodable` type covers all three tools:
///
/// - `outputs` is the only key whose shape is per-tool (`transcribe`/`cleanup`
///   carry plain path strings, `summarize` carries `{preset, path, ok}`
///   objects). The daemon only ever consumes the preset form — path-stage
///   chaining uses `output` — so ``presetOutputs`` decodes best-effort and is
///   `nil` for the string form.
/// - Unknown extra keys are ignored by `Codable` by construction. That *is*
///   the minor-version policy: a newer v1 envelope with additive keys must
///   decode fine, warn-free, with no machinery.
///
/// The major-version rule is strict the other way: ``validated(tool:)``
/// refuses any `schema` other than `allears.<tool>/v1`, naming both the
/// expected and the received identifier, so a breaking v2 producer fails the
/// stage loudly instead of being half-consumed.
public struct StageResultEnvelope: Sendable, Equatable {
  /// The one major this consumer speaks. Bumping it is a deliberate,
  /// breaking, both-sides change.
  public static let supportedMajor = 1

  /// The versioned schema identifier, `allears.<tool>/v<major>`.
  public var schema: String
  public var ok: Bool
  /// The primary artifact's absolute path — what a path stage's successor
  /// consumes. Present on `transcribe`/`cleanup` success; on `summarize` only
  /// when exactly one preset ran.
  public var output: String?
  /// `summarize`'s per-preset results, in run order — present on success and
  /// (partial-success expressible) on failure. `nil` for the other tools'
  /// string-array `outputs`.
  public var presetOutputs: [PresetResult]?
  /// Failure only: the exit-code taxonomy label (issue #61).
  public var exitClass: String?
  /// Failure only: the human-readable error that ended the run.
  public var message: String?

  /// One `summarize` preset's result: `path` is present iff the preset's
  /// summary file was written.
  public struct PresetResult: Decodable, Sendable, Equatable {
    public var preset: String
    public var path: String?
    public var ok: Bool
  }

  /// A breach of the `--json` result-envelope contract, carrying a
  /// ready-to-log description.
  public struct ContractViolation: Error, Equatable {
    public var message: String
  }

  /// The expected schema identifier for `tool`, e.g. `allears.transcribe/v1`.
  public static func expectedSchema(tool: String) -> String {
    "allears.\(tool)/v\(supportedMajor)"
  }

  /// Decodes the single JSON document a `--json` success run puts on stdout.
  ///
  /// Strict on purpose — this parse is where stdout pollution dies:
  /// - anything that is not one decodable JSON envelope document (empty
  ///   stdout, a bare path line, log noise around the JSON) is a
  ///   ``ContractViolation`` quoting the offending stdout (bounded);
  /// - a schema other than `allears.<tool>/v1` is a violation naming both
  ///   identifiers (the major-version rule);
  /// - `ok: false` despite exit 0 is a violation — a stage may not fail and
  ///   report success via its exit code.
  public static func decodeSuccessDocument(
    stdout: String, tool: String
  ) -> Result<StageResultEnvelope, ContractViolation> {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let envelope = try? JSONDecoder().decode(Self.self, from: Data(trimmed.utf8)) else {
      return .failure(
        ContractViolation(
          message:
            "result-envelope contract violated: stdout is not one JSON envelope document; "
            + OnClosePipelineRunner.stdoutNote(stdout)))
    }
    if case .failure(let violation) = envelope.validated(tool: tool) {
      return .failure(violation)
    }
    guard envelope.ok else {
      return .failure(
        ContractViolation(
          message: "result envelope reports ok=false despite exit 0"
            + (envelope.message.map { ": \($0)" } ?? "")))
    }
    return .success(envelope)
  }

  /// Best-effort decode of the error envelope a failing `--json` run writes
  /// as its last stderr line. `nil` when the line is not a decodable
  /// `ok: false` envelope — the caller then falls back to raw-stderr-only
  /// logging; the envelope augments, never replaces, the issue-#21 capture.
  public static func decodeErrorEnvelope(stderr: String) -> StageResultEnvelope? {
    guard
      let lastLine =
        stderr
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .last(where: { !$0.isEmpty })
    else { return nil }
    guard let envelope = try? JSONDecoder().decode(Self.self, from: Data(lastLine.utf8)),
      !envelope.ok
    else { return nil }
    return envelope
  }

  /// Enforces the major-version rule: the envelope's `schema` must be exactly
  /// `allears.<tool>/v1` (the identifier carries only the major; minors are
  /// additive keys, invisible here). Anything else — wrong tool, wrong major,
  /// a malformed identifier — fails, naming expected and received.
  public func validated(tool: String) -> Result<Void, ContractViolation> {
    let expected = Self.expectedSchema(tool: tool)
    guard schema == expected else {
      return .failure(
        ContractViolation(
          message: "result envelope schema mismatch: expected \(expected), got \(schema)"))
    }
    return .success(())
  }
}

extension StageResultEnvelope: Decodable {
  private enum CodingKeys: String, CodingKey {
    case schema, ok, output, outputs, message
    case exitClass = "exit_class"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(String.self, forKey: .schema)
    ok = try container.decode(Bool.self, forKey: .ok)
    output = try container.decodeIfPresent(String.self, forKey: .output)
    // Best-effort: `nil` (not an error) for transcribe/cleanup's string-array
    // form — see the type doc.
    presetOutputs = try? container.decodeIfPresent([PresetResult].self, forKey: .outputs)
    exitClass = try container.decodeIfPresent(String.self, forKey: .exitClass)
    message = try container.decodeIfPresent(String.self, forKey: .message)
  }
}
