import EarsCore
import Foundation
import Synchronization

/// The exit status and captured output of one spawned pipeline stage.
///
/// Carrying stderr — rather than letting the child inherit the daemon's own,
/// where it vanished — is what makes an on-end transcribe failure diagnosable
/// from the daemon log alone. All-ears issue #21: the failing run's "stderr was
/// captured nowhere, so the failing run's actual error message is
/// unrecoverable"; capturing it "alone would have identified the root cause on
/// day one".
///
/// stdout carries the stage's machine-readable output-path contract: a
/// successful `transcribe`/`cleanup` run's stdout is exactly one line — the
/// path of the file it wrote, which the stage chain feeds to the next stage.
public struct SpawnOutcome: Sendable, Equatable {
  public var exitCode: Int32
  /// The child's stderr, verbatim. Callers bound it before logging via
  /// ``OnClosePipelineRunner/boundedCapture(_:)`` so a runaway child can't
  /// flood the daemon log.
  public var stderr: String
  /// The child's stdout, verbatim (the output-path contract requires it to be
  /// exactly one line — see ``OnClosePipelineRunner/strictResultLine(_:)``).
  public var stdout: String

  public init(exitCode: Int32, stderr: String = "", stdout: String = "") {
    self.exitCode = exitCode
    self.stderr = stderr
    self.stdout = stdout
  }
}

/// One stage of the on-end pipeline, in chain order. The raw values are the
/// config vocabulary (`[earsd.sessions] on_end_stages`) *and* the spawned
/// binary names.
public enum OnEndStage: String, Sendable, Hashable, CaseIterable {
  case transcribe
  case cleanup
  case summarize

  /// Resolves the raw `on_end_stages` config list into a valid chain, with a
  /// human-readable problem per entry dropped. Pure and lenient, matching the
  /// per-source config policy ("skipped and reported, never takes down the
  /// daemon"):
  ///
  /// - Unknown stage names are dropped with a problem.
  /// - `cleanup`/`summarize` without `transcribe` are dropped with a problem —
  ///   the LLM stages consume the transcribe stage's output, so a chain
  ///   without it has nothing to run on.
  /// - Duplicates collapse; config order is irrelevant. The result is always
  ///   in canonical chain order (`allCases`).
  public static func resolveList(_ raw: [String]) -> (stages: [OnEndStage], problems: [String]) {
    var problems: [String] = []
    var requested = Set<OnEndStage>()
    for name in raw {
      guard let stage = OnEndStage(rawValue: name) else {
        problems.append(
          "unknown on_end_stages entry '\(name)' "
            + "(valid: \(allCases.map(\.rawValue).joined(separator: ", ")))")
        continue
      }
      requested.insert(stage)
    }
    if !requested.contains(.transcribe) && !requested.isEmpty {
      let dropped = allCases.filter { requested.contains($0) }.map(\.rawValue)
      problems.append(
        "on_end_stages \(dropped) require the transcribe stage; dropping the on-end chain")
      requested = []
    }
    return (allCases.filter { requested.contains($0) }, problems)
  }
}

/// Runs the on-end stage chain against an ended session — the stage-spawner
/// behind the session-end hook (see ``EarsDaemon``):
///
///     transcribe --session <id>   → prints the .transcript.md path
///     cleanup <transcript path>   → prints the .clean.md path
///     summarize <path> --all-presets
///
/// Output paths flow between stages via the stdout contract (each
/// path-producing stage prints its output path as its *only* stdout line), so
/// the daemon never re-derives `transcribe`'s `OutputPathResolution` logic.
/// The parse side is strict: anything other than exactly one line is a
/// contract violation that fails the stage, and the parsed path must exist on
/// disk before it feeds the next stage — a lie or stale path dies at this
/// seam, not two stages later.
///
/// The chain stops loudly on the first failure. A `cleanup`/`summarize`
/// failure never un-succeeds the transcribe: the raw transcript is the
/// durable artifact, and the caller's retention stamp keys on transcribe
/// alone. On any non-zero exit the child's captured stderr lands in the
/// daemon log so the failure is diagnosable from the log alone (issue #21).
public struct OnClosePipelineRunner: Sendable {
  /// Runs one pipeline stage binary (`"transcribe"`, `"cleanup"`,
  /// `"summarize"`) with the given arguments and returns its exit code plus
  /// captured stderr and stdout.
  /// The production runner spawns the real binary via `Foundation.Process`
  /// (PATH-resolved through `/usr/bin/env`, matching
  /// `EarsLLMKit.CommandLLMBackend`); tests inject a scripted fake.
  public typealias ProcessRunner = @Sendable (String, [String]) async -> SpawnOutcome

  private let runProcess: ProcessRunner
  private let log: @Sendable (String) -> Void

  public init(
    runProcess: @escaping ProcessRunner = OnClosePipelineRunner.realProcessRunner,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.runProcess = runProcess
    self.log = log
  }

  /// Runs the configured stage chain against an ended session.
  ///
  /// - Returns: `true` iff `transcribe --session` exited 0 — the signal the
  ///   caller uses to stamp the session's transcript-completion marker (which
  ///   in turn starts the retention clock). LLM-stage failures are logged but
  ///   never affect the return value: derived artifacts must not hold the
  ///   retention clock hostage.
  @discardableResult
  public func runOnEndChain(
    sessionID: String, stages: [OnEndStage], context: String
  ) async -> Bool {
    // Config validation (`EarsdConfigSchema`) rejects LLM stages without
    // transcribe; an empty list means the whole chain is off. Defensive here
    // so a mis-wired caller degrades to a no-op, not a cleanup of nothing.
    guard stages.contains(.transcribe) else { return false }

    guard
      let transcriptPath = await runPathStage(
        .transcribe, arguments: ["--session", sessionID], sessionID: sessionID, context: context)
    else { return false }

    var nextInput = transcriptPath
    if stages.contains(.cleanup) {
      guard
        let cleanPath = await runPathStage(
          .cleanup, arguments: [transcriptPath], sessionID: sessionID, context: context)
      else { return true }  // transcribe already succeeded; chain stops here
      nextInput = cleanPath
    }

    if stages.contains(.summarize) {
      // Summarize writes one file per preset, so it has no single output path
      // to thread — success is just exit 0.
      _ = await spawn(
        .summarize, arguments: [nextInput, "--all-presets"], sessionID: sessionID,
        context: context)
    }
    return true
  }

  /// Spawns a path-producing stage and returns its printed output path, or
  /// `nil` on failure. Exit 0 with anything but exactly one path line is a
  /// failure too — a silent or polluted success the chain can't build on is
  /// treated exactly like a crash, loudly. So is a printed path with no file
  /// behind it: the existence check kills a lie or stale path at this seam
  /// instead of letting it corrupt a later stage.
  private func runPathStage(
    _ stage: OnEndStage, arguments: [String], sessionID: String, context: String
  ) async -> String? {
    guard
      let outcome = await spawn(
        stage, arguments: arguments, sessionID: sessionID, context: context)
    else { return nil }
    let path: String
    switch Self.strictResultLine(outcome.stdout) {
    case .success(let line):
      path = line
    case .failure(let violation):
      log(
        "\(context) on_end: \(stage.rawValue) exited 0 but failed for "
          + "session '\(sessionID)': \(violation.message)")
      return nil
    }
    guard FileManager.default.fileExists(atPath: path) else {
      log(
        "\(context) on_end: \(stage.rawValue) exited 0 but failed for "
          + "session '\(sessionID)': printed output path '\(path)' does not exist")
      return nil
    }
    return path
  }

  /// Spawns one stage with the issue-#21 logging contract: the full argv is
  /// logged *before* the run (so the log shows what was spawned even for a
  /// child that dies instantly), and a non-zero exit logs the exit code plus
  /// bounded stderr. Returns `nil` on non-zero exit.
  private func spawn(
    _ stage: OnEndStage, arguments: [String], sessionID: String, context: String
  ) async -> SpawnOutcome? {
    log(
      "\(context) on_end: spawning \(stage.rawValue) \(arguments.joined(separator: " ")) "
        + "for session '\(sessionID)'")
    let outcome = await runProcess(stage.rawValue, arguments)
    guard outcome.exitCode == 0 else {
      log(
        "\(context) on_end: \(stage.rawValue) failed (exit \(outcome.exitCode)) for "
          + "session '\(sessionID)'; \(Self.stderrNote(outcome.stderr))")
      return nil
    }
    log("\(context) on_end: \(stage.rawValue) succeeded for session '\(sessionID)'")
    return outcome
  }

  /// A stage's breach of the stdout output-path contract. Carries a
  /// ready-to-log description of what the stage actually printed, with the
  /// offending stdout bounded the same way stderr is (``boundedCapture(_:)``).
  struct ContractViolation: Error, Equatable {
    var message: String
  }

  /// The stdout output-path contract's parse side, strict: the stage's stdout
  /// must be exactly one non-empty trimmed line — the output path. Zero lines
  /// or more than one is a ``ContractViolation``: pollution above (or below)
  /// the path line must fail the stage at this seam, never parse
  /// "successfully" via a last-line rule and corrupt silently. Exposed (not
  /// private) so the contract is unit-testable directly.
  static func strictResultLine(_ stdout: String) -> Result<String, ContractViolation> {
    let lines =
      stdout
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard lines.count == 1 else {
      return .failure(
        ContractViolation(
          message:
            "stdout contract violated: expected exactly one line, got \(lines.count); "
            + stdoutNote(stdout)))
    }
    return .success(lines[0])
  }

  /// The largest slice of a child's captured output (stderr or stdout) the
  /// daemon log carries, in bytes: enough for a real Swift error and some
  /// context, bounded so a runaway child can't flood the log (issue #21's
  /// "captured stderr (bounded)").
  static let maxCaptureLogBytes = 4096

  /// A one-line, log-safe rendering of a child's stderr for a failure notice:
  /// `"no stderr captured"` when empty, else `stderr: <text>` with the text
  /// trimmed and bounded to ``maxCaptureLogBytes`` (keeping the *tail* — the
  /// `error: …` line a failing stage writes last).
  static func stderrNote(_ stderr: String) -> String {
    let bounded = boundedCapture(stderr)
    return bounded.isEmpty ? "no stderr captured" : "stderr: \(bounded)"
  }

  /// ``stderrNote(_:)``'s stdout twin, for contract-violation notices:
  /// `"no stdout captured"` when empty, else `stdout: <text>`, bounded the
  /// same way.
  static func stdoutNote(_ stdout: String) -> String {
    let bounded = boundedCapture(stdout)
    return bounded.isEmpty ? "no stdout captured" : "stdout: \(bounded)"
  }

  /// Trims and length-bounds a captured child output for logging, keeping the
  /// tail and marking any elision. Exposed (not private) so the
  /// failure-logging contract is unit-testable without spawning a real child.
  static func boundedCapture(_ captured: String) -> String {
    let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count > maxCaptureLogBytes else { return trimmed }
    let tail = String(decoding: trimmed.utf8.suffix(maxCaptureLogBytes), as: UTF8.self)
    return "…(truncated) " + tail
  }

  /// The production ``ProcessRunner``: spawns `name` (PATH-resolved via
  /// `/usr/bin/env`) with `arguments`, captures its stderr and stdout, waits
  /// for exit, and returns all three.
  ///
  /// Both pipes are drained *as the child writes them* (via each read
  /// handle's readability callback), not read once after exit: a child that
  /// writes more than one pipe buffer (~64 KB) would otherwise block on the
  /// write — never reaching exit — while this waited for an exit that never
  /// comes.
  public static let realProcessRunner: ProcessRunner = { name, arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [name] + arguments
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe

    let stderrCollector = PipeCollector()
    let stdoutCollector = PipeCollector()
    // The callbacks receive the read handle as their parameter, so no
    // non-`Sendable` `FileHandle` is captured across the concurrency boundary.
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      stderrCollector.ingest(handle.availableData) { handle.readabilityHandler = nil }
    }
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      stdoutCollector.ingest(handle.availableData) { handle.readabilityHandler = nil }
    }

    let exitCode: Int32 = await withCheckedContinuation { continuation in
      // Set the handler *before* `run()` so a child that exits before the
      // handler is installed can't leave the continuation hanging.
      process.terminationHandler = { finished in
        continuation.resume(returning: finished.terminationStatus)
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrCollector.finish()
        stdoutCollector.finish()
        continuation.resume(returning: -1)
      }
    }
    let stderr = await stderrCollector.value()
    let stdout = await stdoutCollector.value()
    return SpawnOutcome(exitCode: exitCode, stderr: stderr, stdout: stdout)
  }
}

/// Accumulates one pipe of a child process's output, delivered piecemeal by a
/// `FileHandle.readabilityHandler`, and hands the full text to an `async`
/// awaiter once the stream reaches EOF.
///
/// A dedicated type (rather than inline closures) so the continuation/EOF
/// handshake — which must resume its awaiter exactly once whether EOF arrives
/// before or after ``value()`` is called — lives in one auditable place.
/// `Sendable` without `@unchecked`: its only stored state is a
/// `Synchronization.Mutex`, and every field it guards is itself `Sendable`.
private final class PipeCollector: Sendable {
  private struct State {
    var data = Data()
    var finished = false
    var waiter: CheckedContinuation<String, Never>? = nil
  }
  private let state = Mutex(State())

  /// Appends one readability chunk. Foundation delivers an empty chunk at EOF:
  /// that runs `onEOF` (to detach the handler and stop further callbacks) and
  /// releases any awaiter.
  func ingest(_ chunk: Data, onEOF: () -> Void) {
    guard chunk.isEmpty else {
      state.withLock { $0.data.append(chunk) }
      return
    }
    onEOF()
    finish()
  }

  /// Marks the stream complete and resumes a waiting ``value()`` if one is
  /// already parked. Idempotent — a second call (e.g. the spawn-failure path)
  /// is a no-op.
  func finish() {
    let resumption = state.withLock { s -> (CheckedContinuation<String, Never>, String)? in
      guard !s.finished else { return nil }
      s.finished = true
      guard let waiter = s.waiter else { return nil }
      s.waiter = nil
      return (waiter, String(decoding: s.data, as: UTF8.self))
    }
    if let resumption {
      resumption.0.resume(returning: resumption.1)
    }
  }

  /// The full captured text, awaiting EOF if it has not arrived yet.
  func value() async -> String {
    await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
      let immediate = state.withLock { s -> String? in
        guard s.finished else {
          s.waiter = continuation
          return nil
        }
        return String(decoding: s.data, as: UTF8.self)
      }
      if let immediate { continuation.resume(returning: immediate) }
    }
  }
}
