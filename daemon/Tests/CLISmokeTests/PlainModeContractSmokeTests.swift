import EarsCore
import EarsDataStore
import Foundation
import Testing

/// Tier-3 smoke coverage for the frozen plain-mode stdout contract
/// (issue #62, `EarsCLISupport.PlainModeContract`):
///
/// > On exit 0 in default mode, stdout is exactly one line: the absolute
/// > path of the primary output. All other output goes to stderr. This will
/// > not change.
///
/// One harness pins the promise across all three pipeline stages —
/// `transcribe` (batch `--session`), `cleanup`, `summarize` — over the full
/// matrix {success, failure} × {default, `--verbose`}:
///
/// - success: stdout is exactly one `\n`-terminated line, the line is an
///   absolute path, and the named file exists. (`summarize` emits no result
///   line yet — its result surface is deferred to the `--json` issue — so
///   its pinned "current plain behavior" is byte-empty stdout with the
///   summary file written; see `docs/specs/llm-stages.md`.)
/// - failure: stdout is **byte-empty**, in both modes.
/// - `--verbose` never changes stdout: the fd swap
///   (`EarsCLISupport.ResultChannel`) makes it hold structurally, and this
///   harness proves it end to end against the real spawned binaries.
///
/// Fixtures are fully hermetic: `transcribe` runs against a real schema-3
/// `session.toml` (written via `SessionStore`, the daemon's own writer) with
/// the ASR backend diverted to a `NullTranscriber` via the
/// `ALLEARS_TRANSCRIBE_BACKEND=null` test-only seam
/// (`Sources/transcribe/NullTranscriberOverride.swift`), and the LLM stages
/// run a scripted `[llm] command` (a tiny shell script echoing the fixture
/// segment back) — no network, no model download, no real LLM.
@Suite("CLI Smoke: plain-mode contract")
struct PlainModeContractSmokeTests {
  // MARK: - Modes

  /// The stdout-invariance axis: every case runs once plain and once with
  /// `--verbose`, and the assertions are identical — verbose diagnostics may
  /// only widen stderr, never touch stdout.
  enum Mode: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case plain
    case verbose

    var extraArguments: [String] { self == .verbose ? ["--verbose"] : [] }
    var testDescription: String { rawValue }
  }

  // MARK: - Process plumbing (mirrors ExitTaxonomySmokeTests)

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
    /// Raw stdout bytes — the failure assertions are *byte*-empty, so the
    /// harness keeps the data rather than a lossy string round-trip.
    var stdoutData: Data
    var stderr: String

    var stdout: String { String(data: stdoutData, encoding: .utf8) ?? "" }
  }

  /// Runs a built stage binary with a fixed (not host-inherited) environment
  /// so no ambient `EARS_*` variable can leak into config resolution — plus
  /// whatever explicit test-seam variables the fixture needs.
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
          "PlainModeContractSmokeTests-\(UUID().uuidString)", isDirectory: true)
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
  /// bytes, so `/tmp`, never the long temp directory — the same constraint
  /// `CLISmokeTests.tempSocketPath` and `ExitTaxonomySmokeTests` document;
  /// without it `transcribe --session` traps inside the Network framework
  /// before the pipeline even runs).
  private static func tempSocketPath() -> String {
    "/tmp/ears-plain-contract-\(UUID().uuidString).sock"
  }

  // MARK: - Shared contract assertions

  /// The success half of the promise: stdout is exactly one `\n`-terminated
  /// line, the line is an absolute path, and the file it names exists (and
  /// carries the stage's expected suffix).
  private static func expectSingleResultLine(
    _ result: RunResult, suffix: String, mode: Mode,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
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
      "stdout must be exactly one line (\(mode.rawValue) mode), got \(lines.count): \(stdout.debugDescription)",
      sourceLocation: sourceLocation)
    let path = String(lines.first ?? "")
    #expect(
      path.hasPrefix("/"), "the result line must be an absolute path, got: \(path)",
      sourceLocation: sourceLocation)
    #expect(
      path.hasSuffix(suffix), "expected a \(suffix) path, got: \(path)",
      sourceLocation: sourceLocation)
    #expect(
      FileManager.default.fileExists(atPath: path),
      "the emitted path must name a file that exists: \(path)",
      sourceLocation: sourceLocation)
  }

  /// The failure half of the promise: stdout is byte-empty, both modes.
  private static func expectEmptyStdoutFailure(
    _ result: RunResult, expectedExit: Int32, mode: Mode,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(
      result.exitCode == expectedExit,
      "expected exit \(expectedExit), got \(result.exitCode); stderr:\n\(result.stderr)",
      sourceLocation: sourceLocation)
    #expect(
      result.stdoutData.isEmpty,
      "a failed run's stdout must be byte-empty (\(mode.rawValue) mode), got: \(result.stdout.debugDescription)",
      sourceLocation: sourceLocation)
  }

  // MARK: - Fixtures

  /// The one fixture utterance, shared by the transcript fixture and the
  /// scripted LLM (which echoes it back verbatim, so `CleanupValidator`
  /// accepts the "cleaned" candidate as a genuine minimal edit).
  private static let fixtureUtterance =
    "hello there team this is the plain mode fixture segment"

  /// Writes a real `.transcript.md` (+ JSON sidecar) through the production
  /// renderers, mirroring `CleanupPipelineTests.writeFixtureTranscript`.
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

  /// Writes the scripted `[llm] command`: a shell script that drains its
  /// stdin (the prompt) and prints the fixture utterance — a deterministic,
  /// network-free stand-in for a real LLM. Absolute tool paths inside, since
  /// the spawned stage runs with an empty environment (no `PATH`).
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

  /// Writes a minimal ended session (one closed interval, one `mic` source
  /// with no captured audio anywhere) through `SessionStore` — the daemon's
  /// own schema-3 writer — so `transcribe --session` resolves it exactly as
  /// it would a real one. With the `NullTranscriber` seam active, the run
  /// succeeds end to end: an (empty) transcript is written and its absolute
  /// path is the one stdout line.
  private static func writeFixtureSession(dataRoot: URL) throws -> String {
    let sessionID = "plain-contract-smoke"
    let session = Session(
      id: sessionID,
      title: "Plain-mode contract fixture",
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

  // MARK: - transcribe (batch --session)

  @Test(
    "transcribe success: stdout is exactly one line, the absolute .transcript.md path",
    arguments: Mode.allCases)
  func transcribeSuccess(mode: Mode) throws {
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
      ["--config", configPath, "--log-file", logPath, "--session", sessionID]
        + mode.extraArguments,
      environment: ["ALLEARS_TRANSCRIBE_BACKEND": "null"])

    Self.expectSingleResultLine(result, suffix: ".transcript.md", mode: mode)
    if mode == .verbose {
      // Diagnostics exist and land on stderr — never on stdout.
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test(
    "transcribe failure: stdout is byte-empty (unknown session, exit 3)",
    arguments: Mode.allCases)
  func transcribeFailure(mode: Mode) throws {
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
      ["--config", configPath, "--log-file", logPath, "--session", "no-such-session"]
        + mode.extraArguments,
      environment: ["ALLEARS_TRANSCRIBE_BACKEND": "null"])

    Self.expectEmptyStdoutFailure(result, expectedExit: 3, mode: mode)
    #expect(result.stderr.contains("unknown session"))
  }

  // MARK: - cleanup

  @Test(
    "cleanup success: stdout is exactly one line, the absolute .clean.md path",
    arguments: Mode.allCases)
  func cleanupSuccess(mode: Mode) throws {
    let temp = TempDirectory()
    let transcriptPath = try Self.writeFixtureTranscript(in: temp)
    let scriptPath = try Self.writeFakeLLMScript(in: temp)
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [llm]
      backend = "command"
      command = "\(scriptPath)"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("cleanup.jsonl").path

    let result = try Self.run(
      "cleanup",
      ["--config", configPath, "--log-file", logPath, transcriptPath] + mode.extraArguments)

    Self.expectSingleResultLine(result, suffix: ".clean.md", mode: mode)
    if mode == .verbose {
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test(
    "cleanup failure: stdout is byte-empty (missing transcript, exit 3)",
    arguments: Mode.allCases)
  func cleanupFailure(mode: Mode) throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"
      """,
      named: "config.toml")
    let logPath = temp.url.appendingPathComponent("cleanup.jsonl").path

    let result = try Self.run(
      "cleanup",
      ["--config", configPath, "--log-file", logPath, "/nonexistent/standup.transcript.md"]
        + mode.extraArguments)

    Self.expectEmptyStdoutFailure(result, expectedExit: 3, mode: mode)
    #expect(result.stderr.contains("could not read transcript"))
  }

  // MARK: - summarize

  @Test(
    "summarize success: current plain behavior — byte-empty stdout, summary file written (result surface deferred to the --json issue)",
    arguments: Mode.allCases)
  func summarizeSuccess(mode: Mode) throws {
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
      ["--config", configPath, "--log-file", logPath, transcriptPath, "--preset", "brief"]
        + mode.extraArguments)

    #expect(
      result.exitCode == 0,
      "expected exit 0, got \(result.exitCode); stderr:\n\(result.stderr)")
    // `summarize` emits no result line yet (deferred to the `--json` issue);
    // plain-mode stdout still carries nothing else, so today's frozen shape
    // is byte-empty stdout on success — in both modes.
    #expect(
      result.stdoutData.isEmpty,
      "summarize success stdout must be byte-empty (\(mode.rawValue) mode), got: \(result.stdout.debugDescription)"
    )
    let summaryPath = temp.url.appendingPathComponent("standup.summary.md").path
    #expect(
      FileManager.default.fileExists(atPath: summaryPath),
      "expected the summary written at \(summaryPath)")
    if mode == .verbose {
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test(
    "summarize failure: stdout is byte-empty (missing transcript, exit 3)",
    arguments: Mode.allCases)
  func summarizeFailure(mode: Mode) throws {
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
        "--preset", "brief",
      ] + mode.extraArguments)

    Self.expectEmptyStdoutFailure(result, expectedExit: 3, mode: mode)
    #expect(result.stderr.contains("could not read transcript"))
  }

  // MARK: - The promise, in --help

  @Test("every stage's --help carries the frozen plain-mode promise, verbatim")
  func helpCarriesTheFrozenPromise() throws {
    // `EarsCLISupport.PlainModeContract.promise`, quoted rather than
    // imported: this test pins the *user-visible words*, so a rewording of
    // the constant fails here instead of silently propagating everywhere.
    let promise =
      "On exit 0 in default mode, stdout is exactly one line: the absolute path "
      + "of the primary output. All other output goes to stderr. This will not "
      + "change."
    for binary in ["transcribe", "cleanup", "summarize"] {
      let result = try Self.run(binary, ["--help"])
      #expect(result.exitCode == 0)
      // ArgumentParser re-wraps discussion text to the terminal width, so
      // normalize all whitespace runs to single spaces before comparing.
      let help = (result.stdout + result.stderr)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
      #expect(
        help.contains(promise),
        "\(binary) --help is missing the verbatim plain-mode promise")
      #expect(help.contains("This will not change."), "\(binary) --help: promise freeze")
    }
  }
}
