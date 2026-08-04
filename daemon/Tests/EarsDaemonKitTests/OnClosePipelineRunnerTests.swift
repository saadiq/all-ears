import EarsCore
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Coverage for the on-end stage chain (transcribe → cleanup → summarize) and
/// for all-ears issue #21: the daemon must capture each spawned child's stderr
/// and surface it — with the exit code and the full argv, keyed by session id —
/// in the daemon log on any non-zero exit, so a failing run is diagnosable
/// from the log alone instead of leaving its "actual error message
/// unrecoverable".
@Suite("OnClosePipelineRunner")
struct OnClosePipelineRunnerTests {
  /// Thread-safe collector for the runner's `@Sendable` `log` closure, so a
  /// test can assert on the diagnostic lines it emits, in order.
  private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
      lock.lock()
      defer { lock.unlock() }
      lines.append(line)
    }

    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return lines
    }
  }

  /// A scripted ``OnClosePipelineRunner/ProcessRunner`` that returns fixed
  /// outcomes in spawn order and records the argv it was handed.
  private final class ScriptedRunner: Sendable {
    private let outcomes: Mutex<[SpawnOutcome]>
    private let recorded = Mutex<[(name: String, arguments: [String])]>([])

    init(_ outcomes: [SpawnOutcome]) { self.outcomes = Mutex(outcomes) }

    var runner: OnClosePipelineRunner.ProcessRunner {
      { name, arguments in
        self.recorded.withLock { $0.append((name, arguments)) }
        return self.outcomes.withLock { $0.isEmpty ? SpawnOutcome(exitCode: 0) : $0.removeFirst() }
      }
    }

    var calls: [(name: String, arguments: [String])] { recorded.withLock { $0 } }
  }

  /// A transcribe/cleanup success whose final stdout line is `path` — the
  /// output-path contract as the real stages emit it.
  private static func pathOutcome(_ path: String) -> SpawnOutcome {
    SpawnOutcome(exitCode: 0, stdout: path + "\n")
  }

  /// A fresh per-test temp directory; callers remove it in a `defer`.
  private static func makeTempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "on-close-runner-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Creates a real (empty) file at `name` inside `directory` and returns its
  /// path — stage outputs must exist on disk to survive the runner's
  /// existence check.
  private static func makeFile(_ name: String, in directory: URL) throws -> String {
    let url = directory.appendingPathComponent(name)
    try Data().write(to: url)
    return url.path
  }

  // MARK: - stage chain

  @Test("the full chain runs transcribe → cleanup → summarize, threading each output path")
  func fullChainThreadsPaths() async throws {
    let directory = try Self.makeTempDirectory("full-chain")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("10-00-00_abc.transcript.md", in: directory)
    let clean = try Self.makeFile("10-00-00_abc.clean.md", in: directory)
    let logs = LogCollector()
    let runner = ScriptedRunner([
      Self.pathOutcome(transcript),
      Self.pathOutcome(clean),
      SpawnOutcome(exitCode: 0),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe", "cleanup", "summarize"])
    #expect(runner.calls[0].arguments == ["--session", "b7acc61f"])
    // cleanup consumes the transcript path transcribe printed…
    #expect(runner.calls[1].arguments == [transcript])
    // …and summarize consumes the cleaned path cleanup printed.
    #expect(runner.calls[2].arguments == [clean, "--all-presets"])
    for stage in ["transcribe", "cleanup", "summarize"] {
      #expect(logs.snapshot().contains { $0.contains("\(stage) succeeded for session 'b7acc61f'") })
    }
  }

  @Test("a transcribe-only stage list spawns nothing else")
  func transcribeOnly() async throws {
    let directory = try Self.makeTempDirectory("transcribe-only")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let runner = ScriptedRunner([Self.pathOutcome(transcript)])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner)

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe"])
  }

  @Test("without cleanup in the stages, summarize consumes the raw transcript path")
  func summarizeWithoutCleanup() async throws {
    let directory = try Self.makeTempDirectory("no-cleanup")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let runner = ScriptedRunner([
      Self.pathOutcome(transcript),
      SpawnOutcome(exitCode: 0),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner)

    _ = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe, .summarize], context: "session-end")

    #expect(runner.calls.map(\.name) == ["transcribe", "summarize"])
    #expect(runner.calls[1].arguments == [transcript, "--all-presets"])
  }

  @Test("a failed transcribe stops the chain and returns false")
  func transcribeFailureStopsChain() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([
      SpawnOutcome(exitCode: 1, stderr: "error: unknown source 'mic': no data found")
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(!transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe"])
    let failure = try #require(
      logs.snapshot().first { $0.contains("transcribe failed (exit 1, unclassified)") })
    // Keyed by session id, and carries the child's real error message.
    #expect(failure.contains("session 'b7acc61f'"))
    #expect(failure.contains("stderr: error: unknown source 'mic'"))
  }

  @Test("a transcribe that exits 0 without printing a path is a loud failure, not a silent success")
  func transcribeMissingPathIsFailure() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([SpawnOutcome(exitCode: 0, stdout: "")])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(!transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe"])
    let violation = try #require(
      logs.snapshot().first {
        $0.contains("stdout contract violated: expected exactly one line, got 0")
      })
    #expect(violation.contains("session 'b7acc61f'"))
    #expect(violation.contains("no stdout captured"))
  }

  @Test("multi-line stdout violates the one-line contract and fails the stage")
  func multiLineStdoutFailsStage() async throws {
    let directory = try Self.makeTempDirectory("multi-line")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let logs = LogCollector()
    let runner = ScriptedRunner([
      SpawnOutcome(exitCode: 0, stdout: "notice\n\(transcript)\n")
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(!transcribed)
    let violation = try #require(
      logs.snapshot().first {
        $0.contains("stdout contract violated: expected exactly one line, got 2")
      })
    // The bounded stdout rides along so the polluter is identifiable from the log.
    #expect(violation.contains("notice"))
    #expect(violation.contains("session 'b7acc61f'"))
  }

  @Test("a single-line stdout naming a path that does not exist fails the stage")
  func missingOutputFileFailsStage() async throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("on-close-runner-missing-\(UUID().uuidString)")
      .appendingPathComponent("t.transcript.md").path
    let logs = LogCollector()
    let runner = ScriptedRunner([Self.pathOutcome(missing)])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(!transcribed)
    let violation = try #require(
      logs.snapshot().first { $0.contains("does not exist") })
    #expect(violation.contains(missing))
    #expect(violation.contains("session 'b7acc61f'"))
  }

  @Test("a failed cleanup skips summarize but still returns true — LLM stages never gate retention")
  func cleanupFailureSkipsSummarizeKeepsTranscribe() async throws {
    let directory = try Self.makeTempDirectory("cleanup-fails")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let logs = LogCollector()
    let runner = ScriptedRunner([
      Self.pathOutcome(transcript),
      SpawnOutcome(exitCode: 1, stderr: "error: no [llm] command resolved"),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe", "cleanup"])
    let failure = try #require(
      logs.snapshot().first { $0.contains("cleanup failed (exit 1, unclassified)") })
    #expect(failure.contains("stderr: error: no [llm] command resolved"))
  }

  @Test("a failure log line names the exit class, so retry-worthiness is readable from the log")
  func failureLogCarriesExitClassLabel() async throws {
    let directory = try Self.makeTempDirectory("exit-class")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let logs = LogCollector()
    let runner = ScriptedRunner([
      Self.pathOutcome(transcript),
      SpawnOutcome(exitCode: 5, stderr: "error: LLM backend call timed out"),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    _ = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe, .cleanup], context: "session-end")

    // The exit-code taxonomy's class label (issue #61) rides in the failure
    // line, so a future retry policy — and a human reading the log — can tell
    // a retryable upstream outage from a hard stage failure at a glance.
    #expect(
      logs.snapshot().contains { $0.contains("cleanup failed (exit 5, retryable-upstream)") },
      "expected the failure line to carry the class label; got: \(logs.snapshot())")
  }

  @Test("an exit code outside the taxonomy is logged as unclassified")
  func unknownExitCodeLogsUnclassified() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([SpawnOutcome(exitCode: 87, stderr: "error: kaboom")])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    _ = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(
      logs.snapshot().contains { $0.contains("transcribe failed (exit 87, unclassified)") },
      "expected an unknown code to be labeled unclassified; got: \(logs.snapshot())")
  }

  @Test("a failed summarize is logged but the chain result stays true")
  func summarizeFailureLogged() async throws {
    let directory = try Self.makeTempDirectory("summarize-fails")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let clean = try Self.makeFile("t.clean.md", in: directory)
    let logs = LogCollector()
    let runner = ScriptedRunner([
      Self.pathOutcome(transcript),
      Self.pathOutcome(clean),
      SpawnOutcome(exitCode: 2, stderr: "   \n"),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "55815f35", stages: OnEndStage.allCases, context: "session-end")

    #expect(transcribed)
    // A failure with blank stderr says so rather than logging an empty tail.
    #expect(
      logs.snapshot().contains {
        $0.contains("summarize failed (exit 2, unclassified)") && $0.contains("no stderr captured")
      })
  }

  @Test("a stage list without transcribe spawns nothing and returns false")
  func stagesWithoutTranscribeNoOp() async throws {
    let runner = ScriptedRunner([])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner)

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.cleanup, .summarize], context: "session-end")

    #expect(!transcribed)
    #expect(runner.calls.isEmpty)
  }

  // MARK: - stdout path contract parsing

  @Test("exactly one trimmed line parses; zero or several are contract violations, not last-line")
  func strictResultLineParsing() {
    #expect(OnClosePipelineRunner.strictResultLine("/a/b.md\n") == .success("/a/b.md"))
    #expect(OnClosePipelineRunner.strictResultLine("  /a/b.md  \n\n") == .success("/a/b.md"))
    // Pollution above the path is a violation — the old last-line rule would
    // have parsed it "successfully".
    let polluted = OnClosePipelineRunner.strictResultLine("notice\n/a/b.md\n")
    #expect(throws: OnClosePipelineRunner.ContractViolation.self) { try polluted.get() }
    if case .failure(let violation) = polluted {
      #expect(
        violation.message.contains("stdout contract violated: expected exactly one line, got 2"))
      #expect(violation.message.contains("stdout: notice\n/a/b.md"))
    }
    // No lines at all is a violation too, saying so rather than quoting nothing.
    for empty in ["", "   \n \n"] {
      let parsed = OnClosePipelineRunner.strictResultLine(empty)
      #expect(throws: OnClosePipelineRunner.ContractViolation.self) { try parsed.get() }
      if case .failure(let violation) = parsed {
        #expect(violation.message.contains("expected exactly one line, got 0"))
        #expect(violation.message.contains("no stdout captured"))
      }
    }
  }

  // MARK: - on_end_stages config resolution

  @Test("resolveList canonicalises order, collapses duplicates, and accepts the full vocabulary")
  func resolveListValid() {
    let resolved = OnEndStage.resolveList(["summarize", "transcribe", "cleanup", "transcribe"])
    #expect(resolved.stages == [.transcribe, .cleanup, .summarize])
    #expect(resolved.problems.isEmpty)
    #expect(OnEndStage.resolveList([]).stages.isEmpty)
    #expect(OnEndStage.resolveList([]).problems.isEmpty)
  }

  @Test("resolveList drops unknown names with a problem naming the valid vocabulary")
  func resolveListUnknownName() {
    let resolved = OnEndStage.resolveList(["transcribe", "sumarize"])
    #expect(resolved.stages == [.transcribe])
    let problem = try? #require(resolved.problems.first)
    #expect(problem?.contains("'sumarize'") == true)
    #expect(problem?.contains("transcribe, cleanup, summarize") == true)
  }

  @Test("resolveList drops LLM stages configured without transcribe — they need its output")
  func resolveListLLMWithoutTranscribe() {
    let resolved = OnEndStage.resolveList(["cleanup", "summarize"])
    #expect(resolved.stages.isEmpty)
    #expect(resolved.problems.contains { $0.contains("require the transcribe stage") })
  }

  // MARK: - bounded capture

  @Test("bounded capture trims whitespace and passes a short message through unchanged")
  func boundedCaptureShort() {
    #expect(OnClosePipelineRunner.boundedCapture("  boom  \n") == "boom")
    #expect(OnClosePipelineRunner.boundedCapture("") == "")
  }

  @Test("bounded capture keeps the tail of an over-long message and marks the truncation")
  func boundedCaptureLongKeepsTail() {
    let padding = String(repeating: "x", count: OnClosePipelineRunner.maxCaptureLogBytes + 500)
    let long = padding + "TAIL-MARKER"
    let bounded = OnClosePipelineRunner.boundedCapture(long)
    #expect(bounded.hasPrefix("…(truncated) "))
    #expect(bounded.hasSuffix("TAIL-MARKER"))
    // Bounded to the cap plus the short truncation prefix, never the full input.
    #expect(bounded.utf8.count < long.utf8.count)
  }

  // MARK: - real process runner

  @Test("the real process runner captures a child's stderr and its non-zero exit code")
  func realRunnerCapturesStderr() async throws {
    let outcome = await OnClosePipelineRunner.realProcessRunner(
      "sh", ["-c", "printf 'boom on stderr' 1>&2; exit 3"])
    #expect(outcome.exitCode == 3)
    #expect(outcome.stderr.contains("boom on stderr"))
  }

  @Test("the real process runner captures stdout and stderr independently")
  func realRunnerCapturesBothPipes() async throws {
    let outcome = await OnClosePipelineRunner.realProcessRunner(
      "sh", ["-c", "printf '/out/path.md\\n'; printf 'note' 1>&2; exit 0"])
    #expect(outcome.exitCode == 0)
    #expect(OnClosePipelineRunner.strictResultLine(outcome.stdout) == .success("/out/path.md"))
    #expect(outcome.stderr == "note")
  }

  @Test("the real process runner reports a clean zero exit with empty output for a silent child")
  func realRunnerSilentChild() async throws {
    let outcome = await OnClosePipelineRunner.realProcessRunner("sh", ["-c", "exit 0"])
    #expect(outcome.exitCode == 0)
    #expect(outcome.stderr.isEmpty)
    #expect(outcome.stdout.isEmpty)
  }
}
