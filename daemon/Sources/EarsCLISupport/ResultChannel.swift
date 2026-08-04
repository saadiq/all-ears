import Foundation

/// The guarded, machine-readable stdout channel for the batch stages' final
/// -line contract (`docs/specs/transcribe.md` / `docs/specs/llm-stages.md`: a
/// successful batch run's final stdout line is the written output's path, and
/// nothing else ever appears on stdout).
///
/// The contract used to be enforced by discipline alone: `writeStdout` wrote
/// to real stdout, but so could any stray `print` in our code or a dependency
/// (FluidAudio is exactly the kind of library that logs to stdout), producing
/// a plausible-looking wrong path rather than an error. ``activate()`` makes
/// pollution structurally impossible with a file-descriptor swap: it saves
/// the real stdout with `dup(1)`, then `dup2(2, 1)` so the process-default
/// stdout *is* stderr. After activation, `print`/`FileHandle.standardOutput`
/// physically cannot reach the result channel — only ``emitResult(_:)``,
/// writing to the saved descriptor, can.
public final class ResultChannel: @unchecked Sendable {
  private let handle: FileHandle
  private let ownsDescriptor: Bool

  private init(handle: FileHandle, ownsDescriptor: Bool) {
    self.handle = handle
    self.ownsDescriptor = ownsDescriptor
  }

  /// Saves the real stdout and redirects fd 1 to stderr. Call once, at a
  /// batch tool's entry point, before any pipeline work runs.
  public static func activate() -> ResultChannel {
    // Flush anything stdio already buffered for the real stdout, so it can't
    // surface later through fd 1's new target.
    fflush(stdout)
    let saved = dup(STDOUT_FILENO)
    guard saved >= 0 else {
      // The real stdout could not be saved (descriptor table exhausted).
      // Leave the process's descriptors untouched: the contract degrades to
      // the old by-discipline enforcement rather than the tool losing its
      // result line entirely.
      return ResultChannel(handle: FileHandle.standardOutput, ownsDescriptor: false)
    }
    dup2(STDERR_FILENO, STDOUT_FILENO)
    return ResultChannel(
      handle: FileHandle(fileDescriptor: saved, closeOnDealloc: false), ownsDescriptor: true)
  }

  /// Writes one result line to the *real* stdout saved at activation — the
  /// only remaining route to the result channel.
  public func emitResult(_ line: String) {
    handle.write(Data((line + "\n").utf8))
  }

  /// Tests only: releases the saved descriptor so a test capture pipe sees
  /// EOF. Production never closes the channel — process exit does.
  func closeForTesting() {
    if ownsDescriptor { try? handle.close() }
  }
}
