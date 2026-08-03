import EarsCore
import Foundation
import Synchronization

/// The exit status and captured stderr of one spawned pipeline stage.
///
/// Carrying stderr — rather than letting the child inherit the daemon's own,
/// where it vanished — is what makes an on-end transcribe failure diagnosable
/// from the daemon log alone. All-ears issue #21: the failing run's "stderr was
/// captured nowhere, so the failing run's actual error message is
/// unrecoverable"; capturing it "alone would have identified the root cause on
/// day one".
public struct SpawnOutcome: Sendable, Equatable {
  public var exitCode: Int32
  /// The child's stderr, verbatim. Callers bound it before logging via
  /// ``OnClosePipelineRunner/boundedStderr(_:)`` so a runaway child can't flood
  /// the daemon log.
  public var stderr: String

  public init(exitCode: Int32, stderr: String = "") {
    self.exitCode = exitCode
    self.stderr = stderr
  }
}

/// Runs the on-end transcribe against an ended meeting — the stage-spawner
/// behind the meeting-end auto-transcription hook (see ``EarsDaemon``).
///
/// On any non-zero exit logs the child's captured stderr so the failure is
/// diagnosable from the daemon log (issue #21).
public struct OnClosePipelineRunner: Sendable {
  /// Runs one pipeline stage (today only `"transcribe"`) with the given
  /// arguments and returns its exit code plus captured stderr.
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

  /// Runs a meeting-level transcribe against an ended meeting — the v2
  /// auto-transcription trigger (`transcribe --meeting <id>` unions the
  /// meeting's intervals into one transcript; see
  /// `docs/specs/control-protocol.md`'s "Transcription output").
  /// Only the transcribe stage runs at meeting level today.
  ///
  /// - Returns: `true` iff `transcribe --meeting` exited 0 — the signal the
  ///   caller uses to stamp the meeting's transcript-completion marker (which
  ///   in turn starts the retention clock).
  @discardableResult
  public func runMeetingTranscribe(meetingID: String, context: String) async -> Bool {
    let arguments = ["--meeting", meetingID]
    // Spawn record: the full argv, keyed by meeting id, logged *before* the run
    // so the daemon log shows exactly what was spawned even for a child that
    // dies instantly (issue #21).
    log(
      "\(context) on_end: spawning transcribe \(arguments.joined(separator: " ")) "
        + "for meeting '\(meetingID)'")
    let outcome = await runProcess("transcribe", arguments)
    guard outcome.exitCode == 0 else {
      // On a non-zero exit, the exit code and the child's captured stderr both
      // land in the daemon log, keyed by meeting id — the missing diagnostic
      // that left this failure's root cause unrecoverable (issue #21).
      log(
        "\(context) on_end: transcribe failed (exit \(outcome.exitCode)) for "
          + "meeting '\(meetingID)'; \(Self.stderrNote(outcome.stderr))")
      return false
    }
    log("\(context) on_end: transcribe succeeded for meeting '\(meetingID)'")
    return true
  }

  /// The largest slice of a child's stderr the daemon log carries, in bytes:
  /// enough for a real Swift error and some context, bounded so a runaway child
  /// can't flood the log (issue #21's "captured stderr (bounded)").
  static let maxStderrLogBytes = 4096

  /// A one-line, log-safe rendering of a child's stderr for a failure notice:
  /// `"no stderr captured"` when empty, else `stderr: <text>` with the text
  /// trimmed and bounded to ``maxStderrLogBytes`` (keeping the *tail* — the
  /// `error: …` line a failing stage writes last).
  static func stderrNote(_ stderr: String) -> String {
    let bounded = boundedStderr(stderr)
    return bounded.isEmpty ? "no stderr captured" : "stderr: \(bounded)"
  }

  /// Trims and length-bounds captured stderr for logging, keeping the tail and
  /// marking any elision. Exposed (not private) so the failure-logging contract
  /// is unit-testable without spawning a real child.
  static func boundedStderr(_ stderr: String) -> String {
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count > maxStderrLogBytes else { return trimmed }
    let tail = String(decoding: trimmed.utf8.suffix(maxStderrLogBytes), as: UTF8.self)
    return "…(truncated) " + tail
  }

  /// The production ``ProcessRunner``: spawns `name` (PATH-resolved via
  /// `/usr/bin/env`) with `arguments`, captures its stderr, waits for exit, and
  /// returns both.
  ///
  /// stderr is drained *as the child writes it* (via the read handle's
  /// readability callback), not read once after exit: a child that writes more
  /// than one pipe buffer (~64 KB) of stderr would otherwise block on the write
  /// — never reaching exit — while this waited for an exit that never comes.
  public static let realProcessRunner: ProcessRunner = { name, arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [name] + arguments
    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    let collector = StderrCollector()
    // The callback receives the read handle as its parameter, so no
    // non-`Sendable` `FileHandle` is captured across the concurrency boundary.
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      collector.ingest(handle.availableData) { handle.readabilityHandler = nil }
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
        collector.finish()
        continuation.resume(returning: -1)
      }
    }
    let stderr = await collector.value()
    return SpawnOutcome(exitCode: exitCode, stderr: stderr)
  }
}

/// Accumulates a child process's stderr, delivered piecemeal by a
/// `FileHandle.readabilityHandler`, and hands the full text to an `async`
/// awaiter once the stream reaches EOF.
///
/// A dedicated type (rather than inline closures) so the continuation/EOF
/// handshake — which must resume its awaiter exactly once whether EOF arrives
/// before or after ``value()`` is called — lives in one auditable place.
/// `Sendable` without `@unchecked`: its only stored state is a
/// `Synchronization.Mutex`, and every field it guards is itself `Sendable`.
private final class StderrCollector: Sendable {
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

  /// The full captured stderr, awaiting EOF if it has not arrived yet.
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
