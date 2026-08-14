import EarsCore
import Foundation
import Testing

@testable import transcribe

@Suite("TranscriptStorePaths")
struct TranscriptStorePathsTests {
  private let start = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z
  private let dataRoot = URL(fileURLWithPath: "/data-root")

  @Test("a session run writes transcript.{md,json} into the session's own directory")
  func sessionRunUsesSessionDirectory() {
    let paths = TranscriptStorePaths.session(dataRoot: dataRoot, sessionID: "0d5e7f6a")
    #expect(paths.markdown.path == "/data-root/sessions/0d5e7f6a/transcript.md")
    #expect(paths.sidecar.path == "/data-root/sessions/0d5e7f6a/transcript.json")
  }

  @Test("a range run writes into runs/, keyed by its range-run identifier")
  func rangeRunUsesRunsDirectory() {
    let paths = TranscriptStorePaths.rangeRun(
      dataRoot: dataRoot, runIdentifier: "2026-07-17T10-30-00Z_mic")
    #expect(paths.markdown.path == "/data-root/runs/2026-07-17T10-30-00Z_mic.transcript.md")
    #expect(paths.sidecar.path == "/data-root/runs/2026-07-17T10-30-00Z_mic.transcript.json")
  }

  @Test("a follow run writes a per-source live transcript inside the session directory")
  func followRunUsesSessionDirectory() {
    let paths = TranscriptStorePaths.follow(
      dataRoot: dataRoot, sessionID: "0d5e7f6a", sourceID: SourceID("app:us.zoom.xos"))
    #expect(
      paths.markdown.path
        == "/data-root/sessions/0d5e7f6a/app_us.zoom.xos.follow.transcript.md")
    #expect(
      paths.sidecar.path
        == "/data-root/sessions/0d5e7f6a/app_us.zoom.xos.follow.transcript.json")
  }

  @Test("--out is used verbatim, with the sidecar swapping its extension to json")
  func explicitOutOverridesPath() {
    let paths = TranscriptStorePaths.explicit("/tmp/custom/my-transcript.md")
    #expect(paths.markdown.path == "/tmp/custom/my-transcript.md")
    #expect(paths.sidecar.path == "/tmp/custom/my-transcript.json")
  }

  @Test("rangeRunIdentifier combines the start timestamp and source slug")
  func rangeRunIdentifierShape() {
    #expect(
      TranscriptStorePaths.rangeRunIdentifier(
        requestedStart: start, sourceIDs: [SourceID("mic")]) == "2026-07-17T10-30-00Z_mic")
  }

  @Test("multiple sources join into the range-run identifier's slug")
  func multipleSourcesJoinSlug() {
    #expect(
      TranscriptStorePaths.rangeRunIdentifier(
        requestedStart: start, sourceIDs: [SourceID("mic"), SourceID("app:us.zoom.xos")])
        == "2026-07-17T10-30-00Z_mic_app_us.zoom.xos")
  }
}
