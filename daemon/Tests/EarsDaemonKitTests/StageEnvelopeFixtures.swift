import Foundation

/// Recorded `--json` result-envelope documents for the on-end runner tests
/// (issue #64) — the daemon-side twins of the producer examples checked in at
/// `shared/stage-envelopes/<tool>.v1.examples.json`.
///
/// Each fixture is one line of JSON in the exact wire shape the stages emit
/// (issue #63: `StageEnvelopeJSON.encodeLine` — single line, `.sortedKeys`,
/// `.withoutEscapingSlashes`), with the artifact paths parameterised so a test
/// can splice in files that really exist on disk and survive the runner's
/// existence check.
enum StageEnvelopeFixtures {
  // MARK: - transcribe

  /// `transcribe --json` success: `output` is the `.transcript.md`, `outputs`
  /// adds the `.transcript.json` sidecar.
  static func transcribeSuccess(output: String) -> String {
    #"{"ok":true,"output":"\#(output)","outputs":["\#(output)","\#(output).json"],"#
      + #""schema":"allears.transcribe/v1","#
      + #""stats":{"duration_s":412.5,"segments":87,"words":1042},"warnings":[]}"# + "\n"
  }

  /// A *newer-minor* v1 envelope: same required keys plus additive unknown
  /// keys (`asr_model`, `confidence`, an extra `stats` count). The consumer's
  /// minor policy is that these decode fine — `Codable` ignores unknown keys
  /// by construction.
  static func transcribeSuccessWithUnknownKeys(output: String) -> String {
    #"{"asr_model":"parakeet-tdt-v3","confidence":0.97,"ok":true,"#
      + #""output":"\#(output)","outputs":["\#(output)"],"#
      + #""schema":"allears.transcribe/v1","#
      + #""stats":{"duration_s":412.5,"segments":87,"speaker_turns":12,"words":1042},"#
      + #""warnings":["diarization skipped"]}"# + "\n"
  }

  /// A hypothetical *breaking-major* envelope (`allears.transcribe/v2`): the
  /// consumer must refuse it, naming both the expected and the received
  /// schema.
  static func transcribeWrongMajor(output: String) -> String {
    #"{"ok":true,"output":"\#(output)","outputs":["\#(output)"],"#
      + #""schema":"allears.transcribe/v2","stats":{},"warnings":[]}"# + "\n"
  }

  /// `transcribe --json` failure: the error envelope a failing stage writes
  /// as its *last stderr line* (stdout stays byte-empty).
  static func transcribeError(exitClass: String, message: String) -> String {
    #"{"exit_class":"\#(exitClass)","message":"\#(message)","ok":false,"#
      + #""schema":"allears.transcribe/v1"}"#
  }

  // MARK: - cleanup

  /// `cleanup --json` success: `output` is the `.clean.md`, `outputs` adds
  /// the `.clean.json` sidecar.
  static func cleanupSuccess(output: String) -> String {
    #"{"ok":true,"output":"\#(output)","outputs":["\#(output)","\#(output).json"],"#
      + #""schema":"allears.cleanup/v1","#
      + #""stats":{"accepted":80,"fallback":5,"segments":87,"skipped":2},"warnings":[]}"# + "\n"
  }

  /// `cleanup --json` failure: the error envelope on the last stderr line.
  static func cleanupError(exitClass: String, message: String) -> String {
    #"{"exit_class":"\#(exitClass)","message":"\#(message)","ok":false,"#
      + #""schema":"allears.cleanup/v1"}"#
  }

  // MARK: - summarize

  /// `summarize --all-presets --json` success: exit 0 means every preset
  /// succeeded; `outputs` carries one `{preset, path, ok}` entry per preset
  /// (`output` absent — several primaries, no single one).
  static func summarizeAllPresetsSuccess(presets: [(preset: String, path: String)]) -> String {
    let outputs = presets.map {
      #"{"ok":true,"path":"\#($0.path)","preset":"\#($0.preset)"}"#
    }.joined(separator: ",")
    return #"{"ok":true,"outputs":[\#(outputs)],"schema":"allears.summarize/v1","#
      + #""stats":{"presets":\#(presets.count)},"warnings":[]}"# + "\n"
  }

  /// `summarize --all-presets --json` partial success: a non-zero exit whose
  /// last-stderr-line error envelope still carries per-preset `outputs`, so
  /// "wrote 2 of 3 presets" is expressible. Mirrors the
  /// `partial_failure_error` example in
  /// `shared/stage-envelopes/summarize.v1.examples.json`: `brief` and
  /// `decisions` written, `actions` failed.
  static func summarizePartialFailureError(briefPath: String, decisionsPath: String) -> String {
    #"{"exit_class":"stage-failed","#
      + #""message":"error: LLM call failed for preset 'actions': model process exited 1","#
      + #""ok":false,"outputs":["#
      + #"{"ok":true,"path":"\#(briefPath)","preset":"brief"},"#
      + #"{"ok":false,"preset":"actions"},"#
      + #"{"ok":true,"path":"\#(decisionsPath)","preset":"decisions"}"#
      + #"],"schema":"allears.summarize/v1"}"#
  }
}
