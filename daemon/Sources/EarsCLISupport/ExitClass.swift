import EarsCore

/// The shared exit-code taxonomy every pipeline stage (`transcribe`,
/// `cleanup`, `summarize`) exits with, per issue #61 — so the daemon (and a
/// future retry policy) can tell "unknown session" from "LLM timed out" from
/// "model crashed" by exit code alone, with no re-plumbing:
///
/// - ``success`` (0)
/// - ``inputMissing`` (3): the run's named input doesn't resolve — an unknown
///   `--session` id, an unreadable or unparseable transcript/audio file.
/// - ``stageFailed`` (4): the stage itself failed — model error, output write
///   failure, unusable config (e.g. no `[llm]` command resolved), every
///   cleanup candidate rejected.
/// - ``retryableUpstream`` (5): a retry-worthy upstream outage — the LLM
///   command timed out or failed in a network-shaped way.
/// - ``usage`` (64): invalid arguments or flag combinations. This *adopts*
///   swift-argument-parser's default (`EX_USAGE`) rather than overriding it,
///   so hand-rolled usage guards and ArgumentParser's own `ValidationError`
///   exits agree on one code.
///
/// Codes carry the failure's *class*, never data states — no `grep`/`diff`
/// -style "which outcome" encodings. Anything an operator needs beyond the
/// class goes to stderr and the structured log.
public enum ExitClass: Int32, Sendable, CaseIterable {
  case success = 0
  case inputMissing = 3
  case stageFailed = 4
  case retryableUpstream = 5
  case usage = 64

  /// The process exit code — the raw value, named for call-site readability
  /// (`ExitClass.inputMissing.code`).
  public var code: Int32 { rawValue }

  /// The short label log lines carry next to the raw code, e.g.
  /// `cleanup failed (exit 5, retryable-upstream)`.
  public var label: String {
    switch self {
    case .success: return "success"
    case .inputMissing: return "input-missing"
    case .stageFailed: return "stage-failed"
    case .retryableUpstream: return "retryable-upstream"
    case .usage: return "usage"
    }
  }

  /// The label for a raw exit code, `"unclassified"` for any code outside the
  /// taxonomy — the log stays honest about codes it can't interpret (a crash
  /// signal, a stray bare 1) instead of guessing.
  public static func label(forCode code: Int32) -> String {
    ExitClass(rawValue: code)?.label ?? "unclassified"
  }

  /// Classifies a failed ``EarsCore/LLMBackend`` call: a timeout is a
  /// retryable upstream outage (the backend was reachable-but-stalled — the
  /// network-shaped failure ``retryableUpstream`` exists for); everything
  /// else (non-zero exit, launch failure) is a hard ``stageFailed``, since
  /// retrying a crashing model or a missing binary buys nothing.
  public static func classifying(llmError error: some Error) -> ExitClass {
    if case .timedOut = error as? LLMBackendError { return .retryableUpstream }
    return .stageFailed
  }

  /// The `--help` epilogue documenting the taxonomy, shared verbatim by every
  /// stage binary's `CommandConfiguration.discussion` so the three tables
  /// can't drift apart.
  public static let helpEpilogue = """
    EXIT CODES:
      0    success
      3    input missing/invalid: unknown --session id, unreadable or \
    unparseable input file
      4    stage failed: model error, output write failure, unusable config, \
    every cleanup candidate rejected
      5    retryable upstream failure: LLM command timeout or network-shaped \
    error
      64   usage error: invalid arguments or flag combinations \
    (swift-argument-parser's default, EX_USAGE)
    """
}

extension RunOutcome {
  /// A failed run classified under the shared exit-code taxonomy — the
  /// runtimes' replacement for `RunOutcome(exitCode: 1, ...)`.
  public init(class exitClass: ExitClass, error: String? = nil, fields: [LogField] = []) {
    self.init(exitCode: exitClass.code, error: error, fields: fields)
  }
}
