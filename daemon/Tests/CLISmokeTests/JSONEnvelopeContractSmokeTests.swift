import EarsCore
import EarsDataStore
import Foundation
import Testing

@testable import cleanup
@testable import summarize
@testable import transcribe

/// Tier-3 smoke coverage for the opt-in `--json` result-envelope contract
/// (issue #63), the growth surface next to the frozen plain-mode line
/// (`PlainModeContractSmokeTests` — that harness is untouched by design):
///
/// - success (exit 0): stdout is **exactly one JSON document** — versioned
///   (`schema: allears.<tool>/v1`), emitted through
///   `EarsCLISupport.ResultChannel`, decoded here into each tool's own
///   `Codable` envelope struct and asserted against the checked-in schema's
///   required keys (`shared/stage-envelopes/<tool>.v1.schema.json`).
/// - failure (non-zero exit): stdout stays **byte-empty** — "empty stdout ⇒
///   no result" holds in both modes — and the **last line of stderr** is the
///   error envelope (`ok: false`, `exit_class` carrying the issue-#61
///   taxonomy label, `message`).
/// - `--verbose` never changes stdout, exactly as in plain mode: every case
///   runs in both modes with identical assertions.
///
/// Fixtures are the plain harness's own (hermetic: `SessionStore`-written
/// schema-3 session + `ALLEARS_TRANSCRIBE_BACKEND=null`; scripted `[llm]
/// command`), so the two harnesses can't drift apart on what "a successful
/// run" means.
@Suite("CLI Smoke: --json envelope contract")
struct JSONEnvelopeContractSmokeTests {
  // MARK: - Modes

  /// The stdout-invariance axis, mirroring `PlainModeContractSmokeTests.Mode`.
  enum Mode: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case plain
    case verbose

    var extraArguments: [String] { self == .verbose ? ["--verbose"] : [] }
    var testDescription: String { rawValue }
  }

  // MARK: - Process plumbing (mirrors PlainModeContractSmokeTests)

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
    /// Raw stdout bytes — the failure assertions are *byte*-empty, and the
    /// success assertions decode the exact bytes, so no lossy string round-trip.
    var stdoutData: Data
    var stderr: String

    var stdout: String { String(data: stdoutData, encoding: .utf8) ?? "" }
  }

  /// Runs a built stage binary with a fixed (not host-inherited) environment
  /// so no ambient `EARS_*` variable can leak into config resolution.
  private static func run(
    _ binary: String, _ arguments: [String], environment: [String: String] = [:]
  ) throws -> RunResult {
    let process = Process()
    process.executableURL = try binaryURL(binary)
    process.arguments = arguments
    process.environment = environment
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    return RunResult(
      exitCode: process.terminationStatus,
      stdoutData: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
      stderr: String(
        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
  }

  /// One temp directory scrubbed on deinit, for configs, fixtures, and logs.
  private final class TempDirectory {
    let url: URL
    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "JSONEnvelopeContractSmokeTests-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func write(_ contents: String, named name: String) -> String {
      let fileURL = url.appendingPathComponent(name)
      try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL.path
    }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  /// A short, unique temp socket path (`sockaddr_un.sun_path` caps at 104
  /// bytes — the same constraint every smoke harness here documents).
  private static func tempSocketPath() -> String {
    "/tmp/ears-json-envelope-\(UUID().uuidString).sock"
  }

  // MARK: - Shared envelope assertions

  /// The success half of the contract: exit 0 and stdout is exactly one
  /// newline-terminated line that decodes as `Envelope`. Returns the decoded
  /// envelope for the caller's per-tool assertions.
  private static func decodeSuccessEnvelope<Envelope: Decodable>(
    _ result: RunResult, as type: Envelope.Type, mode: Mode,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> Envelope {
    #expect(
      result.exitCode == 0,
      "expected exit 0, got \(result.exitCode); stderr:\n\(result.stderr)",
      sourceLocation: sourceLocation)
    let stdout = result.stdout
    #expect(
      stdout.hasSuffix("\n"),
      "stdout must be newline-terminated, got: \(stdout.debugDescription)",
      sourceLocation: sourceLocation)
    let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    #expect(
      lines.count == 1,
      "stdout must be exactly one JSON document on one line (\(mode.rawValue) mode), got \(lines.count) lines: \(stdout.debugDescription)",
      sourceLocation: sourceLocation)
    return try JSONDecoder().decode(Envelope.self, from: result.stdoutData)
  }

  /// The failure half: the exit code carries its class, stdout is byte-empty,
  /// and the *last line of stderr* decodes as `Envelope` (the error variant).
  private static func decodeFailureEnvelope<Envelope: Decodable>(
    _ result: RunResult, as type: Envelope.Type, expectedExit: Int32, mode: Mode,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> Envelope {
    #expect(
      result.exitCode == expectedExit,
      "expected exit \(expectedExit), got \(result.exitCode); stderr:\n\(result.stderr)",
      sourceLocation: sourceLocation)
    #expect(
      result.stdoutData.isEmpty,
      "a failed run's stdout must be byte-empty (\(mode.rawValue) mode), got: \(result.stdout.debugDescription)",
      sourceLocation: sourceLocation)
    let lastLine = result.stderr.split(separator: "\n").last.map(String.init) ?? ""
    #expect(
      lastLine.hasPrefix("{"),
      "the last line of stderr must be the error envelope, got: \(lastLine.debugDescription)",
      sourceLocation: sourceLocation)
    return try JSONDecoder().decode(Envelope.self, from: Data(lastLine.utf8))
  }

  // MARK: - Fixtures (mirrors PlainModeContractSmokeTests)

  private static let fixtureUtterance =
    "hello there team this is the json envelope fixture segment"

  private static func writeFixtureTranscript(in temp: TempDirectory) throws -> String {
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      rangeRun: "2026-07-17T10-30-00Z_standup",
      sources: ["mic"],
      range: TimeRange(start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 60)),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: Instant(secondsSinceEpoch: 60),
      durationSeconds: 60,
      speechSeconds: 30,
      wordCount: 10,
      vocab: []
    )
    let document = TranscriptDocument(
      frontmatter: frontmatter,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: fixtureUtterance))
      ])
    let markdownURL = temp.url.appendingPathComponent("standup.transcript.md")
    try TranscriptRenderer.renderMarkdown(document).write(
      to: markdownURL, atomically: true, encoding: .utf8)
    let jsonURL = temp.url.appendingPathComponent("standup.transcript.json")
    try TranscriptRenderer.renderJSON(document).write(
      to: jsonURL, atomically: true, encoding: .utf8)
    return markdownURL.path
  }

  private static func writeFakeLLMScript(in temp: TempDirectory) throws -> String {
    let scriptURL = temp.url.appendingPathComponent("fake-llm.sh")
    let script = """
      #!/bin/sh
      /bin/cat >/dev/null
      printf '%s' '\(fixtureUtterance)'
      """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL.path
  }

  private static func writeFixtureSession(dataRoot: URL) throws -> String {
    let sessionID = "json-envelope-smoke"
    let session = Session(
      id: sessionID,
      title: "JSON envelope contract fixture",
      state: .ended,
      started: Instant(secondsSinceEpoch: 1_000),
      ended: Instant(secondsSinceEpoch: 1_060),
      intervals: [
        SessionInterval(
          start: Instant(secondsSinceEpoch: 1_000), end: Instant(secondsSinceEpoch: 1_060))
      ],
      sources: [SourceID("mic")],
      trigger: .manual)
    try SessionStore.write(session, dataRoot: dataRoot)
    return sessionID
  }

  // MARK: - transcribe (batch --session --json)

  @Test(
    "transcribe --json success: stdout is one envelope document with output/outputs/stats",
    arguments: Mode.allCases)
  func transcribeJSONSuccess(mode: Mode) throws {
    let temp = TempDirectory()
    let dataRoot = temp.url.appendingPathComponent("data")
    let sessionID = try Self.writeFixtureSession(dataRoot: dataRoot)
    let configPath = temp.write(
      """
      data_root = "\(dataRoot.path)"
      output_root = "\(temp.url.path)/out"
      socket_path = "\(Self.tempSocketPath())"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("transcribe.jsonl").path

    let result = try Self.run(
      "transcribe",
      ["--config", configPath, "--log-file", logPath, "--session", sessionID, "--json"]
        + mode.extraArguments,
      environment: ["ALLEARS_TRANSCRIBE_BACKEND": "null"])

    let envelope = try Self.decodeSuccessEnvelope(
      result, as: TranscribeResultEnvelope.self, mode: mode)
    #expect(envelope.schema == TranscribeResultEnvelope.schemaID)
    #expect(envelope.ok)
    let output = try #require(envelope.output)
    #expect(output.hasPrefix("/"), "output must be an absolute path, got: \(output)")
    #expect(output.hasSuffix("/sessions/\(sessionID)/transcript.md"))
    #expect(FileManager.default.fileExists(atPath: output))
    let outputs = try #require(envelope.outputs)
    #expect(outputs.first == output, "outputs must lead with the primary artifact")
    #expect(
      outputs.contains { $0.hasSuffix("/sessions/\(sessionID)/transcript.json") },
      "outputs must list the sidecar")
    for path in outputs {
      #expect(path.hasPrefix("/"), "every outputs entry must be absolute, got: \(path)")
      #expect(FileManager.default.fileExists(atPath: path), "outputs entry must exist: \(path)")
    }
    #expect(envelope.warnings == [])
    let stats = try #require(envelope.stats)
    #expect(stats.durationS == 60, "the fixture session spans 60s")
    #expect(stats.segments >= 0)
    #expect(stats.words >= 0)
    if mode == .verbose {
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test(
    "transcribe --json failure: stdout byte-empty, stderr's last line is the error envelope",
    arguments: Mode.allCases)
  func transcribeJSONFailure(mode: Mode) throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"
      socket_path = "\(Self.tempSocketPath())"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("transcribe.jsonl").path

    let result = try Self.run(
      "transcribe",
      ["--config", configPath, "--log-file", logPath, "--session", "no-such-session", "--json"]
        + mode.extraArguments,
      environment: ["ALLEARS_TRANSCRIBE_BACKEND": "null"])

    let envelope = try Self.decodeFailureEnvelope(
      result, as: TranscribeResultEnvelope.self, expectedExit: 3, mode: mode)
    #expect(envelope.schema == TranscribeResultEnvelope.schemaID)
    #expect(!envelope.ok)
    #expect(envelope.exitClass == "input-missing")
    #expect(try #require(envelope.message).contains("unknown session"))
  }

  // MARK: - cleanup --json

  @Test(
    "cleanup --json success: stdout is one envelope document with output/outputs/stats",
    arguments: Mode.allCases)
  func cleanupJSONSuccess(mode: Mode) throws {
    let temp = TempDirectory()
    let transcriptPath = try Self.writeFixtureTranscript(in: temp)
    let scriptPath = try Self.writeFakeLLMScript(in: temp)
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"
      output_root = "\(temp.url.path)/out"

      [llm]
      backend = "command"
      command = "\(scriptPath)"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("cleanup.jsonl").path

    let result = try Self.run(
      "cleanup",
      ["--config", configPath, "--log-file", logPath, transcriptPath, "--json"]
        + mode.extraArguments)

    let envelope = try Self.decodeSuccessEnvelope(
      result, as: CleanupResultEnvelope.self, mode: mode)
    #expect(envelope.schema == CleanupResultEnvelope.schemaID)
    #expect(envelope.ok)
    let output = try #require(envelope.output)
    #expect(output.hasPrefix("/"), "output must be an absolute path, got: \(output)")
    #expect(output.hasSuffix("/out/1970/01/01/1970-01-01 - mic.md"))
    #expect(FileManager.default.fileExists(atPath: output))
    let outputs = try #require(envelope.outputs)
    #expect(outputs.first == output, "outputs must lead with the primary artifact")
    #expect(
      outputs.contains { $0.hasSuffix("/out/1970/01/01/1970-01-01 - mic.json") },
      "outputs must list the sidecar")
    for path in outputs {
      #expect(FileManager.default.fileExists(atPath: path), "outputs entry must exist: \(path)")
    }
    #expect(envelope.warnings == [])
    let stats = try #require(envelope.stats)
    #expect(stats.segments == 1, "the fixture transcript has one segment")
    #expect(stats.accepted + stats.fallback + stats.skipped == stats.segments)
    if mode == .verbose {
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test(
    "cleanup --json failure: stdout byte-empty, stderr's last line is the error envelope",
    arguments: Mode.allCases)
  func cleanupJSONFailure(mode: Mode) throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("cleanup.jsonl").path

    let result = try Self.run(
      "cleanup",
      [
        "--config", configPath, "--log-file", logPath, "/nonexistent/standup.transcript.md",
        "--json",
      ] + mode.extraArguments)

    let envelope = try Self.decodeFailureEnvelope(
      result, as: CleanupResultEnvelope.self, expectedExit: 3, mode: mode)
    #expect(envelope.schema == CleanupResultEnvelope.schemaID)
    #expect(!envelope.ok)
    #expect(envelope.exitClass == "input-missing")
    #expect(try #require(envelope.message).contains("could not read transcript"))
  }

  // MARK: - summarize --json

  @Test(
    "summarize --json single-preset success: envelope carries output plus one per-preset entry",
    arguments: Mode.allCases)
  func summarizeJSONSuccess(mode: Mode) throws {
    let temp = TempDirectory()
    let transcriptPath = try Self.writeFixtureTranscript(in: temp)
    let scriptPath = try Self.writeFakeLLMScript(in: temp)
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [llm]
      backend = "command"
      command = "\(scriptPath)"

      [[summarize.preset]]
      name = "brief"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("summarize.jsonl").path

    let result = try Self.run(
      "summarize",
      [
        "--config", configPath, "--log-file", logPath, transcriptPath, "--preset", "brief",
        "--json",
      ] + mode.extraArguments)

    let envelope = try Self.decodeSuccessEnvelope(
      result, as: SummarizeResultEnvelope.self, mode: mode)
    #expect(envelope.schema == SummarizeResultEnvelope.schemaID)
    #expect(envelope.ok)
    let output = try #require(envelope.output, "a single-preset run has a primary artifact")
    #expect(output.hasPrefix("/"), "output must be an absolute path, got: \(output)")
    #expect(output.hasSuffix(".summary.md"))
    #expect(FileManager.default.fileExists(atPath: output))
    let outputs = try #require(envelope.outputs)
    #expect(outputs.count == 1)
    #expect(outputs.first?.preset == "brief")
    #expect(outputs.first?.ok == true)
    #expect(outputs.first?.path == output)
    #expect(envelope.warnings == [])
    #expect(envelope.stats?.presets == 1)
    if mode == .verbose {
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test(
    "summarize --json failure: stdout byte-empty, stderr's last line is the error envelope",
    arguments: Mode.allCases)
  func summarizeJSONFailure(mode: Mode) throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [[summarize.preset]]
      name = "brief"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("summarize.jsonl").path

    let result = try Self.run(
      "summarize",
      [
        "--config", configPath, "--log-file", logPath, "/nonexistent/standup.transcript.md",
        "--preset", "brief", "--json",
      ] + mode.extraArguments)

    let envelope = try Self.decodeFailureEnvelope(
      result, as: SummarizeResultEnvelope.self, expectedExit: 3, mode: mode)
    #expect(envelope.schema == SummarizeResultEnvelope.schemaID)
    #expect(!envelope.ok)
    #expect(envelope.exitClass == "input-missing")
    #expect(try #require(envelope.message).contains("could not read transcript"))
  }

  @Test("summarize --json --all-presets: output absent, one per-preset entry each")
  func summarizeJSONAllPresets() throws {
    let temp = TempDirectory()
    let transcriptPath = try Self.writeFixtureTranscript(in: temp)
    let scriptPath = try Self.writeFakeLLMScript(in: temp)
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [llm]
      backend = "command"
      command = "\(scriptPath)"

      [[summarize.preset]]
      name = "brief"

      [[summarize.preset]]
      name = "actions"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("summarize.jsonl").path

    let result = try Self.run(
      "summarize",
      ["--config", configPath, "--log-file", logPath, transcriptPath, "--all-presets", "--json"])

    let envelope = try Self.decodeSuccessEnvelope(
      result, as: SummarizeResultEnvelope.self, mode: .plain)
    #expect(envelope.ok)
    #expect(
      envelope.output == nil,
      "a multi-preset run has no single primary artifact, so output must be absent")
    let outputs = try #require(envelope.outputs)
    #expect(outputs.map(\.preset) == ["brief", "actions"])
    for entry in outputs {
      #expect(entry.ok)
      let path = try #require(entry.path)
      #expect(path.hasSuffix(".\(entry.preset).summary.md"))
      #expect(FileManager.default.fileExists(atPath: path))
    }
    #expect(envelope.stats?.presets == 2)
  }
}
