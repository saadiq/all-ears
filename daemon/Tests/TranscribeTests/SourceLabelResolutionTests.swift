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

  @Test("an unlabelled session copy falls through to the ring's label")
  func emptySessionLabelFallsThroughToRing() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("labels-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: root, sessionID: "s1")
    // The per-session copy predates the label; the ring carries the real name.
    try SourceMetaStore.write(descriptor(label: ""), dataRoot: sessionRoot)
    try SourceMetaStore.write(descriptor(label: "Zoom"), dataRoot: root)

    let labels = TranscribePipeline.sourceLabels(
      sourceIDs: [SourceID("app:us.zoom.xos")], sessionID: "s1", dataRoot: root)
    #expect(labels == ["app:us.zoom.xos": "Zoom"])
  }

  private func descriptor(label: String) -> SourceDescriptor {
    SourceDescriptor(
      schema: 1, id: SourceID("app:us.zoom.xos"), sourceClass: .app, label: label,
      nativeSampleRate: 48_000, asrSampleRate: 16_000, storeNative: true,
      channels: 1, codec: "aac", bitrate: 64_000,
      created: Instant(secondsSinceEpoch: 0))
  }
}
