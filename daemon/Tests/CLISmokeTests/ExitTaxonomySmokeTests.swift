import Foundation
import Testing

/// Tier-3 smoke coverage for the shared exit-code taxonomy (issue #61): the
/// pipeline stages must exit with the class of their failure — not a flat 1 —
/// so the daemon (and a future retry policy) can tell "unknown session" from
/// "LLM timed out" from "model crashed" by exit code alone:
///
///     0   success
///     3   input missing/invalid (unknown --session id, unreadable transcript)
///     4   stage failed (model error, write failure, unusable config)
///     5   retryable upstream failure (LLM timeout, network-shaped errors)
///     64  usage error (swift-argument-parser's default, EX_USAGE)
///
/// Spawns the real built binaries so the asserted codes are the ones the
/// daemon's `OnClosePipelineRunner` actually observes.
@Suite("CLI Smoke: exit-code taxonomy")
struct ExitTaxonomySmokeTests {
  private final class BundleMarker {}

  private static func binaryURL(_ name: String) throws -> URL {
    let productsDirectory = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    let url = productsDirectory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw SmokeError.binaryNotFound(url.path)
    }
    return url
  }

  private enum SmokeError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    var description: String {
      switch self {
      case .binaryNotFound(let path):
        return "expected a built binary at \(path) -- run `swift build` before `swift test`"
      }
    }
  }

  private struct RunResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
  }

  /// Runs a built binary with a fixed (not host-inherited) environment so no
  /// ambient `EARS_*` variable can leak into config resolution.
  private static func run(_ binary: String, _ arguments: [String]) throws -> RunResult {
    let process = Process()
    process.executableURL = try binaryURL(binary)
    process.arguments = arguments
    process.environment = [:]
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    return RunResult(
      exitCode: process.terminationStatus,
      stdout: String(
        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      stderr: String(
        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
  }

  /// One temp directory scrubbed on deinit, for the config + log file.
  private final class TempDirectory {
    let url: URL
    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExitTaxonomySmokeTests-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func write(_ contents: String, named name: String) -> String {
      let fileURL = url.appendingPathComponent(name)
      try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL.path
    }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  @Test("transcribe --session with an unknown session id exits 3 (input missing/invalid)")
  func transcribeUnknownSessionExitsInputMissing() throws {
    let temp = TempDirectory()
    // `socket_path` is pinned to a short /tmp path: the default
    // `<data_root>/runtime/earsd.sock` under the long temp directory would
    // blow `sockaddr_un.sun_path`'s 104-byte cap (the same constraint
    // `CLISmokeTests.tempSocketPath` documents) and trap inside the Network
    // framework before the run reaches the unknown-session check.
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"
      socket_path = "/tmp/ears-exit-taxonomy-\(UUID().uuidString).sock"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("transcribe.jsonl").path

    let result = try Self.run(
      "transcribe",
      ["--config", configPath, "--log-file", logPath, "--session", "no-such-session"])

    #expect(result.stderr.contains("unknown session"))
    #expect(result.exitCode == 3, "expected exit 3 (input-missing), got \(result.exitCode)")
  }

  @Test("cleanup pointed at a nonexistent transcript exits 3 (input missing/invalid)")
  func cleanupMissingTranscriptExitsInputMissing() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("cleanup.jsonl").path

    let result = try Self.run(
      "cleanup",
      ["--config", configPath, "--log-file", logPath, "/nonexistent/file.md"])

    #expect(result.stderr.contains("could not read transcript"))
    #expect(result.exitCode == 3, "expected exit 3 (input-missing), got \(result.exitCode)")
  }

  @Test("every stage's --help documents the exit-code taxonomy")
  func helpDocumentsExitCodeTable() throws {
    for binary in ["transcribe", "cleanup", "summarize"] {
      let result = try Self.run(binary, ["--help"])
      #expect(result.exitCode == 0)
      let help = result.stdout + result.stderr
      #expect(help.contains("EXIT CODES"), "\(binary) --help is missing the exit-code table")
      #expect(help.contains("64") && help.contains("usage error"), "\(binary) --help: 64/usage")
      #expect(help.contains("input missing/invalid"), "\(binary) --help: 3/input")
      #expect(help.contains("stage failed"), "\(binary) --help: 4/stage-failed")
      #expect(
        help.contains("retryable upstream failure"), "\(binary) --help: 5/retryable-upstream")
    }
  }
}
