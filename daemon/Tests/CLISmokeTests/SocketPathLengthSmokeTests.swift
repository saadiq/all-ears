import Foundation
import Testing

/// Tier-3 smoke coverage for the over-long socket path guard (issue #74): a
/// `data_root` deep enough that the derived `<data_root>/runtime/earsd.sock`
/// cannot fit in `sockaddr_un.sun_path` must produce a clear stderr message
/// and a taxonomy exit — never the SIGTRAP the Network framework used to
/// raise. Spawns the real built binaries, mirroring `ExitTaxonomySmokeTests`.
@Suite("CLI Smoke: over-long socket path")
struct SocketPathLengthSmokeTests {
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

  /// One temp directory scrubbed on deinit, holding the config, log file, and
  /// the deliberately-too-deep `data_root`.
  private final class TempDirectory {
    let url: URL
    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "SocketPathLengthSmokeTests-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func write(_ contents: String, named name: String) -> String {
      let fileURL = url.appendingPathComponent(name)
      try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL.path
    }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  /// A config whose `data_root` alone exceeds `sun_path`'s 104-byte cap, with
  /// `socket_path` left empty — the exact shape issue #74 describes: the
  /// derived `<data_root>/runtime/earsd.sock` arms the trap.
  private static func writeDeepDataRootConfig(in temp: TempDirectory) -> String {
    let deepDataRoot = temp.url.appendingPathComponent(String(repeating: "d", count: 120)).path
    return temp.write(
      """
      data_root = "\(deepDataRoot)"
      """,
      named: "config.toml")
  }

  @Test("transcribe --session with a too-deep data_root exits 4 with the message, not SIGTRAP")
  func transcribeSessionOverlongSocketPathFailsCleanly() throws {
    let temp = TempDirectory()
    let configPath = Self.writeDeepDataRootConfig(in: temp)
    let logPath = temp.url.appendingPathComponent("transcribe.jsonl").path

    let result = try Self.run(
      "transcribe",
      ["--config", configPath, "--log-file", logPath, "--session", "any-session"])

    #expect(result.stderr.contains("socket path too long for sun_path"))
    #expect(result.stderr.contains("set socket_path to a shorter path or move data_root"))
    #expect(result.exitCode == 4, "expected exit 4 (stage-failed), got \(result.exitCode)")
  }

  @Test("earsd with a too-deep data_root refuses to start with the same message")
  func earsdOverlongSocketPathRefusesToStart() throws {
    let temp = TempDirectory()
    let configPath = Self.writeDeepDataRootConfig(in: temp)
    let logPath = temp.url.appendingPathComponent("earsd.jsonl").path

    // The guard fires before the daemon is constructed, so this normally
    // never-exits-on-its-own binary exits promptly on its own here.
    let result = try Self.run("earsd", ["--config", configPath, "--log-file", logPath])

    #expect(result.stderr.contains("socket path too long for sun_path"))
    #expect(result.stderr.contains("set socket_path to a shorter path or move data_root"))
    #expect(result.exitCode == 1, "expected exit 1, got \(result.exitCode)")
  }

  @Test("ears status with a too-deep data_root fails at config resolution with the message")
  func earsOverlongSocketPathFailsCleanly() throws {
    let temp = TempDirectory()
    let configPath = Self.writeDeepDataRootConfig(in: temp)

    let result = try Self.run("ears", ["status", "--config", configPath])

    #expect(result.stderr.contains("socket path too long for sun_path"))
    #expect(result.stderr.contains("set socket_path to a shorter path or move data_root"))
    #expect(result.exitCode != 0, "expected a nonzero exit, got \(result.exitCode)")
  }
}
