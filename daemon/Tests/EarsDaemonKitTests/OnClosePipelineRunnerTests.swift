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

  /// A `transcribe --json` success whose stdout is the recorded v1 envelope
  /// naming `path` — the result contract as the real stage emits it.
  private static func transcribeOutcome(_ path: String) -> SpawnOutcome {
    SpawnOutcome(exitCode: 0, stdout: StageEnvelopeFixtures.transcribeSuccess(output: path))
  }

  /// `transcribeOutcome(_:)`'s cleanup twin.
  private static func cleanupOutcome(_ path: String) -> SpawnOutcome {
    SpawnOutcome(exitCode: 0, stdout: StageEnvelopeFixtures.cleanupSuccess(output: path))
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
    let brief = try Self.makeFile("10-00-00_abc.brief.summary.md", in: directory)
    let actions = try Self.makeFile("10-00-00_abc.actions.summary.md", in: directory)
    let logs = LogCollector()
    let runner = ScriptedRunner([
      Self.transcribeOutcome(transcript),
      Self.cleanupOutcome(clean),
      SpawnOutcome(
        exitCode: 0,
        stdout: StageEnvelopeFixtures.summarizeAllPresetsSuccess(
          presets: [(preset: "brief", path: brief), (preset: "actions", path: actions)])),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe", "cleanup", "summarize"])
    #expect(runner.calls[0].arguments == ["--session", "b7acc61f", "--json"])
    // cleanup consumes the `output` path transcribe's envelope named…
    #expect(runner.calls[1].arguments == [transcript, "--json"])
    // …and summarize consumes the cleaned path cleanup's envelope named.
    #expect(runner.calls[2].arguments == [clean, "--all-presets", "--json"])
    for stage in ["transcribe", "cleanup", "summarize"] {
      #expect(logs.snapshot().contains { $0.contains("\(stage) succeeded for session 'b7acc61f'") })
    }
    // Summarize's per-preset results are visible in the daemon log.
    #expect(
      logs.snapshot().contains {
        $0.contains("summarize wrote 2/2 presets for session 'b7acc61f'")
      })
  }

  @Test("a transcribe-only stage list spawns nothing else")
  func transcribeOnly() async throws {
    let directory = try Self.makeTempDirectory("transcribe-only")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let runner = ScriptedRunner([Self.transcribeOutcome(transcript)])
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
      Self.transcribeOutcome(transcript),
      SpawnOutcome(exitCode: 0),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner)

    _ = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe, .summarize], context: "session-end")

    #expect(runner.calls.map(\.name) == ["transcribe", "summarize"])
    #expect(runner.calls[1].arguments == [transcript, "--all-presets", "--json"])
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

  @Test("a transcribe that exits 0 with empty stdout is a loud failure, not a silent success")
  func transcribeMissingEnvelopeIsFailure() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([SpawnOutcome(exitCode: 0, stdout: "")])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(!transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe"])
    let violation = try #require(
      logs.snapshot().first {
        $0.contains("stdout is not one JSON envelope document")
      })
    #expect(violation.contains("session 'b7acc61f'"))
    #expect(violation.contains("no stdout captured"))
  }

  @Test("non-JSON stdout — pollution around or instead of the envelope — fails the stage")
  func nonJSONStdoutFailsStage() async throws {
    let directory = try Self.makeTempDirectory("polluted")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let logs = LogCollector()
    // Pollution above an otherwise-valid envelope: the whole stdout is no
    // longer one JSON document, so the stage fails at this seam.
    let polluted = "notice\n" + StageEnvelopeFixtures.transcribeSuccess(output: transcript)
    let runner = ScriptedRunner([
      SpawnOutcome(exitCode: 0, stdout: polluted)
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(!transcribed)
    let violation = try #require(
      logs.snapshot().first {
        $0.contains("stdout is not one JSON envelope document")
      })
    // The bounded stdout rides along so the polluter is identifiable from the log.
    #expect(violation.contains("notice"))
    #expect(violation.contains("session 'b7acc61f'"))
  }

  @Test("an envelope whose output path does not exist on disk fails the stage")
  func missingOutputFileFailsStage() async throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("on-close-runner-missing-\(UUID().uuidString)")
      .appendingPathComponent("t.transcript.md").path
    let logs = LogCollector()
    let runner = ScriptedRunner([Self.transcribeOutcome(missing)])
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
      Self.transcribeOutcome(transcript),
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
      Self.transcribeOutcome(transcript),
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
      Self.transcribeOutcome(transcript),
      Self.cleanupOutcome(clean),
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

  // MARK: - JSON result-envelope consumption (issue #64)

  @Test("a v1 transcribe JSON envelope parses and its output path feeds cleanup")
  func transcribeJSONEnvelopeFeedsCleanup() async throws {
    let directory = try Self.makeTempDirectory("json-envelope")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let clean = try Self.makeFile("t.clean.md", in: directory)
    let brief = try Self.makeFile("t.brief.summary.md", in: directory)
    let runner = ScriptedRunner([
      SpawnOutcome(
        exitCode: 0, stdout: StageEnvelopeFixtures.transcribeSuccess(output: transcript)),
      SpawnOutcome(exitCode: 0, stdout: StageEnvelopeFixtures.cleanupSuccess(output: clean)),
      SpawnOutcome(
        exitCode: 0,
        stdout: StageEnvelopeFixtures.summarizeAllPresetsSuccess(
          presets: [(preset: "brief", path: brief)])),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner)

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    #expect(transcribed)
    #expect(runner.calls.map(\.name) == ["transcribe", "cleanup", "summarize"])
    // Every stage is spawned in JSON mode…
    #expect(runner.calls[0].arguments == ["--session", "b7acc61f", "--json"])
    // …and each envelope's `output` (not its raw stdout) feeds the next stage.
    #expect(runner.calls[1].arguments == [transcript, "--json"])
    #expect(runner.calls[2].arguments == [clean, "--all-presets", "--json"])
  }

  @Test("a wrong-major envelope fails the stage, naming expected and received schemas")
  func wrongMajorEnvelopeFailsStage() async throws {
    let directory = try Self.makeTempDirectory("wrong-major")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let logs = LogCollector()
    let runner = ScriptedRunner([
      SpawnOutcome(
        exitCode: 0, stdout: StageEnvelopeFixtures.transcribeWrongMajor(output: transcript))
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(!transcribed)
    let violation = try #require(
      logs.snapshot().first {
        $0.contains("allears.transcribe/v1") && $0.contains("allears.transcribe/v2")
      },
      "expected a failure line naming both the expected and received schema; got: \(logs.snapshot())"
    )
    #expect(violation.contains("session 'b7acc61f'"))
  }

  @Test("a summarize partial failure logs per-preset results: wrote 2/3, naming the failed preset")
  func summarizePartialSuccessLogsPresetResults() async throws {
    let directory = try Self.makeTempDirectory("summarize-partial")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let clean = try Self.makeFile("t.clean.md", in: directory)
    let brief = try Self.makeFile("t.brief.summary.md", in: directory)
    let decisions = try Self.makeFile("t.decisions.summary.md", in: directory)
    let logs = LogCollector()
    let runner = ScriptedRunner([
      SpawnOutcome(
        exitCode: 0, stdout: StageEnvelopeFixtures.transcribeSuccess(output: transcript)),
      SpawnOutcome(exitCode: 0, stdout: StageEnvelopeFixtures.cleanupSuccess(output: clean)),
      SpawnOutcome(
        exitCode: 4,
        stderr: "summarize: running 3 presets\n"
          + StageEnvelopeFixtures.summarizePartialFailureError(
            briefPath: brief, decisionsPath: decisions)),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: OnEndStage.allCases, context: "session-end")

    // Partial summarize success never un-succeeds the transcribe.
    #expect(transcribed)
    let presetLine = try #require(
      logs.snapshot().first { $0.contains("summarize wrote 2/3 presets") },
      "expected a per-preset partial-success line; got: \(logs.snapshot())")
    #expect(presetLine.contains("failed: actions"))
  }

  @Test("a newer-minor v1 envelope with unknown extra keys still succeeds — additive keys are free")
  func unknownExtraKeysEnvelopeSucceeds() async throws {
    let directory = try Self.makeTempDirectory("unknown-keys")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let runner = ScriptedRunner([
      SpawnOutcome(
        exitCode: 0,
        stdout: StageEnvelopeFixtures.transcribeSuccessWithUnknownKeys(output: transcript))
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner)

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(transcribed)
  }

  @Test("a failure whose last stderr line is the error envelope logs its exit_class and message")
  func failureLogCarriesErrorEnvelope() async throws {
    let directory = try Self.makeTempDirectory("error-envelope")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = try Self.makeFile("t.transcript.md", in: directory)
    let logs = LogCollector()
    let stderr =
      "cleanup: resolving [llm] command\n"
      + StageEnvelopeFixtures.cleanupError(
        exitClass: "stage-failed", message: "error: no [llm] command resolved")
    let runner = ScriptedRunner([
      Self.transcribeOutcome(transcript),
      SpawnOutcome(exitCode: 4, stderr: stderr),
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    _ = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe, .cleanup], context: "session-end")

    let failure = try #require(
      logs.snapshot().first { $0.contains("cleanup failed (exit 4, stage-failed)") })
    // The envelope augments the failure line…
    #expect(failure.contains("envelope: stage-failed — error: no [llm] command resolved"))
    // …but never replaces the bounded raw stderr capture (issue #21).
    #expect(failure.contains("stderr: cleanup: resolving [llm] command"))
  }

  @Test("an exit-0 envelope reporting ok=false is a contract violation, not a success")
  func okFalseUnderExitZeroFailsStage() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([
      SpawnOutcome(
        exitCode: 0,
        stdout: StageEnvelopeFixtures.transcribeError(
          exitClass: "stage-failed", message: "error: output write failed") + "\n")
    ])
    let pipeline = OnClosePipelineRunner(runProcess: runner.runner, log: { logs.append($0) })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "b7acc61f", stages: [.transcribe], context: "session-end")

    #expect(!transcribed)
    #expect(
      logs.snapshot().contains { $0.contains("ok=false despite exit 0") },
      "expected the ok=false violation to be logged; got: \(logs.snapshot())")
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
    #expect(outcome.stdout == "/out/path.md\n")
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
