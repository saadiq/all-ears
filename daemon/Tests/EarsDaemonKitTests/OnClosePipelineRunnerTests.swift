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

  // MARK: - stage chain

  @Test("the full chain runs transcribe → cleanup → summarize, threading each output path")
  func fullChainThreadsPaths() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([
      Self.pathOutcome("/out/2026-08-03/10-00-00_abc.transcript.md"),
      Self.pathOutcome("/out/2026-08-03/10-00-00_abc.clean.md"),
      SpawnOutcome(exitCode: 0),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe", "cleanup", "summarize"])
    #expect(runner.calls[0].arguments == ["--session", "b7acc61f"])
    // cleanup consumes the transcript path transcribe printed…
    #expect(runner.calls[1].arguments == ["/out/2026-08-03/10-00-00_abc.transcript.md"])
    // …and summarize consumes the cleaned path cleanup printed.
    #expect(
      runner.calls[2].arguments == ["/out/2026-08-03/10-00-00_abc.clean.md", "--all-presets"])
    for stage in ["transcribe", "cleanup", "summarize"] {
      #expect(logs.snapshot().contains { $0.contains("\(stage) succeeded for session 'b7acc61f'") })
    }
  }

  @Test("a transcribe-only stage list spawns nothing else")
  func transcribeOnly() async throws {
    let runner = ScriptedRunner([Self.pathOutcome("/out/t.transcript.md")])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner)

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe"])
  }

  @Test("without cleanup in the stages, summarize consumes the raw transcript path")
  func summarizeWithoutCleanup() async throws {
    let runner = ScriptedRunner([
      Self.pathOutcome("/out/t.transcript.md"),
      SpawnOutcome(exitCode: 0),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner)

    _ = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe, .summarize], context: "session-end")

    #expect(runner.calls.map(\.name) == ["transcribe", "summarize"])
    #expect(runner.calls[1].arguments == ["/out/t.transcript.md", "--all-presets"])
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
    let failure = try #require(logs.snapshot().first { $0.contains("transcribe failed (exit 1)") })
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
    #expect(
      logs.snapshot().contains {
        $0.contains("printed no output path") && $0.contains("session 'b7acc61f'")
      })
  }

  @Test("a failed cleanup skips summarize but still returns true — LLM stages never gate retention")
  func cleanupFailureSkipsSummarizeKeepsTranscribe() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([
      Self.pathOutcome("/out/t.transcript.md"),
      SpawnOutcome(exitCode: 1, stderr: "error: no [llm] command resolved"),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe", "cleanup"])
    let failure = try #require(logs.snapshot().first { $0.contains("cleanup failed (exit 1)") })
    #expect(failure.contains("stderr: error: no [llm] command resolved"))
  }

  @Test("a failed summarize is logged but the chain result stays true")
  func summarizeFailureLogged() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([
      Self.pathOutcome("/out/t.transcript.md"),
      Self.pathOutcome("/out/t.clean.md"),
      SpawnOutcome(exitCode: 2, stderr: "   \n"),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "55815f35", stages: OnEndStage.allCases, context: "session-end")

    #expect(transcribed)
    // A failure with blank stderr says so rather than logging an empty tail.
    #expect(
      logs.snapshot().contains {
        $0.contains("summarize failed (exit 2)") && $0.contains("no stderr captured")
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

  @Test("the final stdout line wins, ignoring earlier lines and trailing whitespace")
  func finalStdoutLineParsing() {
    #expect(OnClosePipelineRunner.finalStdoutLine("/a/b.md\n") == "/a/b.md")
    #expect(OnClosePipelineRunner.finalStdoutLine("notice\n/a/b.md\n") == "/a/b.md")
    #expect(OnClosePipelineRunner.finalStdoutLine("  /a/b.md  \n\n") == "/a/b.md")
    #expect(OnClosePipelineRunner.finalStdoutLine("") == nil)
    #expect(OnClosePipelineRunner.finalStdoutLine("   \n \n") == nil)
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

  // MARK: - bounded stderr

  @Test("bounded stderr trims whitespace and passes a short message through unchanged")
  func boundedStderrShort() {
    #expect(OnClosePipelineRunner.boundedStderr("  boom  \n") == "boom")
    #expect(OnClosePipelineRunner.boundedStderr("") == "")
  }

  @Test("bounded stderr keeps the tail of an over-long message and marks the truncation")
  func boundedStderrLongKeepsTail() {
    let padding = String(repeating: "x", count: OnClosePipelineRunner.maxStderrLogBytes + 500)
    let long = padding + "TAIL-MARKER"
    let bounded = OnClosePipelineRunner.boundedStderr(long)
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
    #expect(OnClosePipelineRunner.finalStdoutLine(outcome.stdout) == "/out/path.md")
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
