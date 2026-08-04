import Foundation
import Testing

@testable import EarsCLISupport

/// Proves the fd-swap enforcement: once a ``ResultChannel`` is active, a
/// stray `print` (ours or a dependency's) physically cannot reach the result
/// channel — only ``ResultChannel/emitResult(_:)`` can.
///
/// The test captures the *real* stdout by pointing fd 1 at a pipe before
/// activation, exactly the position the daemon's stage runner is in when it
/// parses a stage's stdout. Serialized because it swaps process-global file
/// descriptors.
@Suite("ResultChannel", .serialized)
struct ResultChannelTests {
  @Test("a stray print after activation cannot reach the result channel")
  func pollutionCannotReachTheResultChannel() throws {
    let capture = Pipe()
    let savedStdout = dup(STDOUT_FILENO)
    #expect(savedStdout >= 0)
    fflush(stdout)
    dup2(capture.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

    let channel = ResultChannel.activate()
    // The pollution vector: a stray stdio print (what a dependency would do).
    // Flushed explicitly because a piped stdout is fully buffered.
    print("pollution")
    fflush(stdout)
    channel.emitResult("/x")

    // Restore the runner's real stdout before asserting, then close every
    // write end so the capture read sees EOF.
    fflush(stdout)
    dup2(savedStdout, STDOUT_FILENO)
    close(savedStdout)
    channel.closeForTesting()
    capture.fileHandleForWriting.closeFile()

    let captured = String(
      decoding: capture.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    // The result line reaches the channel; the pollution never does.
    // Substring assertions (rather than whole-capture equality) keep the test
    // robust against the in-process test runner's own concurrent stdout
    // writes landing in the capture window.
    #expect(captured.contains("/x\n"))
    #expect(!captured.contains("pollution"))
  }
}
