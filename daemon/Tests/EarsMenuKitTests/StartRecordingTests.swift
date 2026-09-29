import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("StartRecording")
struct StartRecordingTests {
  private func status(_ configured: StatusData.Configured?) -> StatusData {
    StatusData(uptimeSeconds: 1, sources: [], configured: configured)
  }

  @Test("declares exactly the daemon's configured sources and chain, and no title")
  func declaresConfigured() throws {
    let params = try StartRecording.params(
      from: status(.init(sources: ["mic", "system"], onEndStages: ["transcribe", "cleanup"]))
    ).get()
    #expect(params.sources == ["mic", "system"])
    #expect(params.onEndStages == ["transcribe", "cleanup"])
    #expect(params.title == nil)
    #expect(params.trigger == nil)
  }

  @Test("an empty configured chain is declared as [] — run nothing — not omitted")
  func emptyChainIsDeclared() throws {
    let params = try StartRecording.params(
      from: status(.init(sources: ["mic"], onEndStages: []))
    ).get()
    #expect(params.onEndStages == [])
  }

  @Test("a daemon whose status has no configured block is refused as too old")
  func olderDaemonIsRefused() {
    #expect(StartRecording.params(from: status(nil)) == .failure(.daemonTooOld))
  }

  @Test("no configured sources is refused rather than recording nothing")
  func noSourcesIsRefused() {
    #expect(
      StartRecording.params(from: status(.init(sources: [], onEndStages: ["transcribe"])))
        == .failure(.noSources))
  }
}
