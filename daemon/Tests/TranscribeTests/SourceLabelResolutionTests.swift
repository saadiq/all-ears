import EarsCore
import EarsDataStore
import Foundation
import Testing

@testable import transcribe

@Suite("Source label resolution")
struct SourceLabelResolutionTests {
  @Test("labels come from the per-session meta.toml, skipping empty and missing ones")
  func readsSessionMetaLabels() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("labels-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: root, sessionID: "s1")
    let zoom = SourceDescriptor(
      schema: 1, id: SourceID("app:us.zoom.xos"), sourceClass: .app, label: "Zoom",
      nativeSampleRate: 48_000, asrSampleRate: 16_000, storeNative: true,
      channels: 1, codec: "aac", bitrate: 64_000,
      created: Instant(secondsSinceEpoch: 0))
    try SourceMetaStore.write(zoom, dataRoot: sessionRoot)

    let labels = TranscribePipeline.sourceLabels(
      sourceIDs: [SourceID("app:us.zoom.xos"), SourceID("mic")],
      sessionID: "s1", dataRoot: root)
    #expect(labels == ["app:us.zoom.xos": "Zoom"])
  }
}
