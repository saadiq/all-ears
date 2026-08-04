/// The frozen plain-mode stdout contract every batch pipeline stage
/// (`transcribe`, `cleanup`, `summarize`) ships under, per issue #62 — the
/// one promise `$(transcribe --session …)`-style consumers and the daemon's
/// on-end stage chain (`OnClosePipelineRunner`) build on:
///
/// > On exit 0 in default mode, stdout is exactly one line: the absolute
/// > path of the primary output. All other output goes to stderr. This will
/// > not change.
///
/// Enforced structurally by ``ResultChannel``'s fd swap and pinned end to end
/// by `Tests/CLISmokeTests/PlainModeContractSmokeTests.swift` across every
/// stage, in success and failure, with and without `--verbose`.
///
/// **Rejected alternatives, recorded so they stay rejected:**
/// - **No second stdout line, ever** — it would break every `$(…)` consumer
///   and the daemon's strict one-line parse in the same release.
/// - **No TTY detection for the data format** — stdout is the same one line
///   piped or interactive; a format that changes shape depending on who is
///   watching cannot be scripted against.
/// - **No `key=value` mode** — anything richer than the one path line is the
///   `--json` surface's job, on its own flag, never a mutation of plain mode.
public enum PlainModeContract {
  /// The verbatim promise, frozen. Quoted word for word in each stage's
  /// `--help` discussion and in `docs/specs/llm-stages.md`'s output-path
  /// contract section; the smoke harness asserts all three binaries carry it.
  public static let promise =
    "On exit 0 in default mode, stdout is exactly one line: the absolute path "
    + "of the primary output. All other output goes to stderr. This will not "
    + "change."

  /// The `--help` epilogue block carrying ``promise``, shared verbatim by
  /// every stage binary's `CommandConfiguration.discussion` (alongside
  /// ``ExitClass/helpEpilogue``) so the three statements can't drift apart.
  public static let helpEpilogue = "STDOUT CONTRACT:\n" + promise
}
