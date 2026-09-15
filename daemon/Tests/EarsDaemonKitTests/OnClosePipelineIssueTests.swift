import EarsCore
import EarsCoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

@Suite("On-close issue and job consistency")
struct OnClosePipelineIssueTests {
  @Test("an invalid summarize result fails the live job and the persisted stage together")
  func invalidSummarizeResult() async throws {
    let transcript = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pipeline-issue-\(UUID().uuidString).md")
    try Data().write(to: transcript)
    defer { try? FileManager.default.removeItem(at: transcript) }
    let jobs = Mutex<[JobPublishParams]>([])
    let issues = Mutex<[PipelineIssue]>([])
    let pipeline = OnClosePipelineRunner(
      runProcess: { name, _ in
        name == "transcribe"
          ? SpawnOutcome(
            exitCode: 0,
            stdout: StageEnvelopeFixtures.transcribeSuccess(output: transcript.path))
          : SpawnOutcome(exitCode: 0, stdout: "not a result envelope")
      },
      publishJob: { job in jobs.withLock { $0.append(job) } })

    let transcribed = await pipeline.runOnEndChain(
      sessionID: "manual-session", stages: [.transcribe, .summarize],
      context: "test", recordIssues: { recorded in issues.withLock { $0 = recorded } })

    #expect(transcribed)
    #expect(issues.withLock { $0.map(\.stage) } == ["summarize"])
    #expect(issues.withLock { $0.map(\.kind) } == [.failed])
    #expect(jobs.withLock { $0.map(\.state) } == [.started, .failed])
    #expect(jobs.withLock { $0.last?.detail } == "invalid result envelope")
  }
}
