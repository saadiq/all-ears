import EarsCaptureKit
import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import EarsIPC
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Integration tests for ``EarsDaemon``, the top-level composition that wires
/// ``CaptureActor``/``SessionRegistry``/``ControlServer``/``PowerObserver``/
/// ``ShutdownCoordinator`` into one runnable daemon. Every source is backed by
/// a ``SyntheticCaptureBackend`` (or a scripted failure) via the
/// ``CaptureBackendFactory`` seam, so nothing here touches Core Audio or TCC.
@Suite("EarsDaemon")
struct EarsDaemonTests {
  private let nativeRate = 48_000
  private let asrRate = 16_000

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EarsDaemonTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A short, unique temp socket path. `sockaddr_un.sun_path` caps at 104
  /// bytes, so `/tmp` (not the long scratchpad dir) keeps us well under, per
  /// `EarsIPCTests/NetworkTransportIntegrationTests`' precedent.
  private func tempSocketPath() -> String {
    "/tmp/ears-daemon-\(UUID().uuidString).sock"
  }

  private func makeDescriptor(id: SourceID, sourceClass: SourceClass) -> SourceDescriptor {
    SourceDescriptor(
      schema: 1,
      id: id,
      sourceClass: sourceClass,
      label: id.rawValue,
      nativeSampleRate: nativeRate,
      asrSampleRate: asrRate,
      storeNative: true,
      channels: 1,
      codec: "aac",
      bitrate: 64_000,
      created: Instant(secondsSinceEpoch: 1_000)
    )
  }

  private func makeBuffer(seconds: Double, value: Float = 0.5) -> AudioBuffer {
    AudioBuffer(
      samples: [Float](repeating: value, count: Int(seconds * Double(nativeRate))),
      sampleRate: nativeRate)
  }

  /// Every on-disk chunk file (native `chunks/` + ASR `asr/`) for a source under
  /// a specific session's directory — the assertion that a source's audio landed
  /// in the session it belongs to, not another's tree (#19).
  private func chunkFiles(dataRoot: URL, sessionID: String, source: SourceID) -> [String] {
    let sourceDir = DataStoreLayout.sourceDirectory(
      dataRoot: DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: sessionID),
      sourceID: source)
    let chunks =
      (try? FileManager.default.contentsOfDirectory(
        atPath: sourceDir.appendingPathComponent("chunks").path)) ?? []
    let asr =
      (try? FileManager.default.contentsOfDirectory(
        atPath: sourceDir.appendingPathComponent("asr").path)) ?? []
    return chunks + asr
  }

  private struct StartFailure: Error {}

  /// A ``CaptureBackend`` whose `start()` always throws, standing in for a
  /// denied-permission source without touching real TCC.
  private struct FailingStartCaptureBackend: CaptureBackend {
    let source: SourceID
    func start() async throws -> AsyncStream<AudioBuffer> { throw StartFailure() }
    func stop() async {}
  }

  @Test(
    "one source's start() failure is isolated: it lands in .error, other sources keep capturing")
  func perSourceStartupFailureIsolation() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))
    let logRecorder = RecordingLogRecordSink()

    let configuration = EarsDaemonConfiguration(
      sources: [
        makeDescriptor(id: "mic", sourceClass: .mic),
        makeDescriptor(id: "system", sourceClass: .system),
      ],
      dataRoot: dataRoot,
      socketPath: tempSocketPath()
    )

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        if descriptor.id == "system" {
          return FailingStartCaptureBackend(source: descriptor.id)
        }
        return SyntheticCaptureBackend(
          source: descriptor.id, buffers: [self.makeBuffer(seconds: 0.1)])
      },
      clock: clock,
      logSink: logRecorder
    )

    // Must not throw: a single source's permission-style failure never takes
    // down the whole daemon (docs/specs/capture-daemon.md).
    try await daemon.start()
    // Idle boot: nothing captures until a session starts.
    #expect(await daemon.statusForTesting().isEmpty)

    // A manual session naming both sources starts capture of each
    // independently; the failing one lands in .error, the other keeps going.
    _ = try await daemon.startSessionForTesting(
      SessionStartParams(title: "call", sources: ["mic", "system"]))

    let statuses = await daemon.statusForTesting()
    #expect(statuses["system"]?.state == .error)
    #expect(statuses["mic"]?.state == .capturing)

    // The "source 'system' failed to start" lifecycle message fans out to the
    // shared sink as a `daemon.log` record. The daemon's string-log wrapper is
    // fire-and-forget (a detached Task), so poll briefly rather than assuming
    // it has landed the instant start() returns.
    var sawSystemLog = false
    for _ in 0..<100 {
      if logRecorder.recorded.contains(where: { $0.msg?.contains("system") == true }) {
        sawSystemLog = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sawSystemLog)

    await daemon.stop()
  }

  @Test("boots idle: no source directory or meta.toml until a session starts the source")
  func idleBootWritesNothingUntilSession() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 5_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: tempSocketPath()
    )

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [])
      },
      clock: clock
    )

    // Construction writes no meta.toml and creates no source directory.
    #expect(throws: DataStoreError.self) {
      _ = try SourceMetaStore.read(sourceID: "mic", dataRoot: dataRoot)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: "mic").path))

    try await daemon.start()
    let session = try await daemon.startSessionForTesting(
      SessionStartParams(title: "call", sources: ["mic"]))

    // The session started the source, so its meta.toml now exists — under the
    // session's own directory, not a global sources/ tree.
    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: session.id)
    let written = try SourceMetaStore.read(sourceID: "mic", dataRoot: sessionRoot)
    #expect(written.id == "mic")
    #expect(written.sourceClass == .mic)
    #expect(written.nativeSampleRate == nativeRate)
    #expect(written.created == Instant(secondsSinceEpoch: 1_000))

    // No global sources/ tree exists any more — audio is session-scoped.
    #expect(
      !FileManager.default.fileExists(
        atPath: DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: "mic").path))

    await daemon.stop()
  }

  @Test(
    "a source captured after restart preserves an existing meta.toml's created timestamp while updating its other fields to match the current config"
  )
  func preservesExistingMetaTomlCreatedOnRestart() async throws {
    let dataRoot = try makeDataRoot()
    let originalCreated = Instant(secondsSinceEpoch: 500)

    // A session still active on disk from a prior daemon run — the daemon
    // resumes its capture at start() (SessionRegistry.loadFromDisk), which is
    // the restart path that re-writes the source's meta.toml.
    let session = Session(
      id: "restart-session",
      title: "call",
      state: .active,
      started: Instant(secondsSinceEpoch: 8_000),
      intervals: [SessionInterval(start: Instant(secondsSinceEpoch: 8_000))],
      sources: ["mic"])
    try SessionStore.write(session, dataRoot: dataRoot)

    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: session.id)
    var preExisting = makeDescriptor(id: "mic", sourceClass: .mic)
    preExisting.created = originalCreated
    preExisting.bitrate = 32_000
    try SourceMetaStore.write(preExisting, dataRoot: sessionRoot)

    let configuration = EarsDaemonConfiguration(
      // A fresh config-resolution pass stamps `created` with "now" and may
      // have a different `bitrate` than what's already on disk.
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: tempSocketPath()
    )

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [])
      },
      clock: ManualClock(Instant(secondsSinceEpoch: 9_000))
    )
    try await daemon.start()

    let written = try SourceMetaStore.read(sourceID: "mic", dataRoot: sessionRoot)
    #expect(written.created == originalCreated)
    #expect(written.bitrate == 64_000)

    await daemon.stop()
  }

  @Test("boots idle, records only while a session is active, over a real control socket")
  func sessionScopedCaptureOverSocket() async throws {
    let dataRoot = try makeDataRoot()
    let socketPath = tempSocketPath()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: socketPath
    )

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [self.makeBuffer(seconds: 0.1)])
      },
      clock: clock
    )

    try await daemon.start()

    let client = try await ControlSocketClient.connect(toPath: socketPath)
    _ = try await client.hello(client: "test/0")

    // Idle: status reports no sources until a session starts.
    let idle = try await client.send(.status, expecting: StatusData.self)
    #expect(idle.sources.isEmpty)

    let session = try await client.send(
      .sessionStart(SessionStartParams(title: "call", sources: ["mic"])),
      expecting: Session.self)

    let active = try await client.send(.status, expecting: StatusData.self)
    #expect(active.sources.count == 1)
    #expect(active.sources.first?.id == "mic")
    #expect(active.sources.first?.state == .capturing)

    _ = try await client.send(.sessionEnd(session: session.id), expecting: Session.self)

    // Session ended: the source's actor is stopped and torn down, so status
    // reports no live sources again.
    let afterEnd = try await client.send(.status, expecting: StatusData.self)
    #expect(afterEnd.sources.isEmpty)

    await client.close()
    await daemon.stop()

    // The socket listener is torn down as part of stop(), so a fresh connect
    // attempt to the same path fails -- proof stop() actually stopped serving.
    await #expect(throws: SocketTransportError.self) {
      _ = try await ControlSocketClient.connect(toPath: socketPath)
    }
  }

  @Test("session start writes audio to disk; session end stops and flushes capture")
  func sessionWritesAudioThenStops() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: tempSocketPath()
    )
    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [self.makeBuffer(seconds: 2)])
      },
      clock: clock
    )
    try await daemon.start()

    // Fresh start: nothing on disk under a global sources/ tree — and there
    // never will be; audio is session-scoped.
    let globalSourceDir = DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: "mic")
    #expect(!FileManager.default.fileExists(atPath: globalSourceDir.path))

    let session = try await daemon.startSessionForTesting(
      SessionStartParams(title: "call", sources: ["mic"]))
    // session.end stops capture, flushing the in-progress chunk to disk.
    try await daemon.endSessionForTesting(id: session.id)

    // The audio landed under the session's own directory.
    let sourceDir = DataStoreLayout.sourceDirectory(
      dataRoot: DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: session.id),
      sourceID: "mic")
    #expect(!FileManager.default.fileExists(atPath: globalSourceDir.path))

    let chunkFiles =
      ((try? FileManager.default.contentsOfDirectory(
        atPath: sourceDir.appendingPathComponent("chunks").path)) ?? [])
      + ((try? FileManager.default.contentsOfDirectory(
        atPath: sourceDir.appendingPathComponent("asr").path)) ?? [])
    #expect(!chunkFiles.isEmpty, "expected a chunk file under chunks/ or asr/ after the session")

    // The source is no longer live once the session ended.
    #expect(await daemon.statusForTesting().isEmpty)

    await daemon.stop()
  }

  // MARK: - Dynamic browser (ingest) sources

  @Test("openIngestSource builds a dynamic browser source that writes real PCM to disk")
  func dynamicIngestSourceWritesToDisk() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    // A browser session must exist before ingest opens — its identity tag is
    // how the daemon resolves which session directory the audio lands in.
    let session = try await daemon.startSessionForTesting(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: [], trigger: .browserExtension))

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let streamID = try await daemon.openIngestSource(
      label: "browser:meet:jane-a1b2", format: format,
      session: SessionIdentity(platform: "meet", externalID: "abc"))

    let samples = [Float](repeating: 0.25, count: 1600)  // 100 ms @ 16 kHz
    await daemon.pushIngestAudio(streamID: streamID, samples: samples, sampleRate: 16000)
    // stop() (called by closeIngestSource) awaits the CaptureActor's consume
    // task draining every already-yielded buffer before returning, and
    // flushes whatever's pending as a short final chunk — so no sleep is
    // needed here to avoid racing the background consume loop.
    await daemon.closeIngestSource(streamID: streamID)

    let statuses = await daemon.statusForTesting()
    let status = try #require(statuses["browser:meet:jane-a1b2"])
    #expect(status.bytesUsed > 0)
    #expect(status.state == .disabled)  // stopped by ingest.close, not left capturing

    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: session.id)
    let written = try SourceMetaStore.read(
      sourceID: "browser:meet:jane-a1b2", dataRoot: sessionRoot)
    #expect(written.sourceClass == .browser)
    #expect(written.nativeSampleRate == 16000)
    #expect(written.asrSampleRate == 16000)
    #expect(written.storeNative == false)

    await daemon.stop()
  }

  @Test("a batched ingest.attribution lands in attribution.jsonl under the right session")
  func attributionBatchLandsInSessionDirectory() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    // An earlier session for a different meeting, already superseded when the
    // batch arrives — the batch must land under the CURRENT session, not here.
    let earlier = try await daemon.startSessionForTesting(
      SessionStartParams(
        platform: "meet", externalID: "old-meeting", sources: [], trigger: .browserExtension))
    let session = try await daemon.startSessionForTesting(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: [], trigger: .browserExtension))

    // Sanitized synthetic lines only, per the flight-recorder privacy rule.
    let lines = [
      #"{"schema":1,"type":"dom-burst","t":1000,"deviceId":"spaces/demo/devices/1"}"#,
      #"{"schema":1,"type":"track-ended","t":1001,"trackId":"trk-1"}"#,
    ]
    await daemon.appendAttributionEvents(
      session: SessionIdentity(platform: "meet", externalID: "abc"), events: lines)
    // A second batch appends rather than overwriting.
    let more = [#"{"schema":1,"type":"track-unmuted","t":1002,"trackId":"trk-2"}"#]
    await daemon.appendAttributionEvents(
      session: SessionIdentity(platform: "meet", externalID: "abc"), events: more)

    #expect(
      SessionAttributionLog.readAllLines(dataRoot: dataRoot, sessionID: session.id) == lines + more)
    #expect(SessionAttributionLog.readAllLines(dataRoot: dataRoot, sessionID: earlier.id).isEmpty)

    // A tag naming no live session drops the batch without writing anywhere.
    await daemon.appendAttributionEvents(
      session: SessionIdentity(platform: "meet", externalID: "never-started"), events: lines)
    let sessionsDir = DataStoreLayout.sessionsDirectory(dataRoot: dataRoot)
    let sessionDirs = try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
    #expect(Set(sessionDirs) == Set([earlier.id, session.id]))

    await daemon.stop()
  }

  @Test("an ingest.capture_failed report lands in events.jsonl under the right session")
  func captureFailureLandsInSessionTimeline() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    let session = try await daemon.startSessionForTesting(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: [], trigger: .browserExtension))

    await daemon.recordCaptureFailure(
      source: "browser:meet:t3",
      session: SessionIdentity(platform: "meet", externalID: "abc"),
      reason: "decoder gave up after 5 restarts")

    let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: session.id)
    let failure = timeline.first { $0.event == "capture_failed" }
    #expect(failure != nil)
    #expect(failure?.source == "browser:meet:t3")
    #expect(failure?.reason == "decoder gave up after 5 restarts")

    // A tag naming no live session drops the report without creating anything.
    await daemon.recordCaptureFailure(
      source: "browser:meet:t3",
      session: SessionIdentity(platform: "meet", externalID: "never-started"),
      reason: "decoder gave up")
    let sessionsDir = DataStoreLayout.sessionsDirectory(dataRoot: dataRoot)
    let sessionDirs = try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
    #expect(Set(sessionDirs) == Set([session.id]))

    await daemon.stop()
  }

  @Test(
    "reopening the same label after a close resumes the same on-disk source rather than a fresh one"
  )
  func reopenSameLabelResumesSameSource() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    _ = try await daemon.startSessionForTesting(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: [], trigger: .browserExtension))
    let identity = SessionIdentity(platform: "meet", externalID: "abc")

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let label: SourceID = "browser:meet:speaker-1"
    // A full second, not a small 100ms buffer: FilenameTimestampCodec
    // truncates chunk filenames to whole-second precision (chunks are
    // fixed-duration 30s+ in real capture, so sub-second start times never
    // collide in practice — see that type's doc comment). ChunkEncoder's
    // timeline is buffer-duration-derived, not clock-derived, so the two
    // streams' chunks must be pushed far enough apart in accumulated
    // duration to land in different whole seconds and write distinct files,
    // or the second stream's flush silently overwrites the first's file.
    let samples = [Float](repeating: 0.25, count: 16000)

    let firstStreamID = try await daemon.openIngestSource(
      label: label, format: format, session: identity)
    await daemon.pushIngestAudio(streamID: firstStreamID, samples: samples, sampleRate: 16000)
    await daemon.closeIngestSource(streamID: firstStreamID)
    let bytesAfterFirstStream = try #require(await daemon.statusForTesting()[label]?.bytesUsed)

    // Same label, a later "join": must reuse the existing CaptureActor, not
    // build a second one — a fresh stream_id each time, same source.
    let secondStreamID = try await daemon.openIngestSource(
      label: label, format: format, session: identity)
    #expect(secondStreamID != firstStreamID)
    await daemon.pushIngestAudio(streamID: secondStreamID, samples: samples, sampleRate: 16000)
    await daemon.closeIngestSource(streamID: secondStreamID)
    let bytesAfterSecondStream = try #require(await daemon.statusForTesting()[label]?.bytesUsed)

    #expect(bytesAfterSecondStream > bytesAfterFirstStream)
    #expect(await daemon.statusForTesting().keys.filter { $0 == label }.count == 1)

    await daemon.stop()
  }

  @Test(
    "closing an ingest stream flushes the final ingest_stats interval, and a sender seq restart is not frame loss"
  )
  func ingestStatsFlushedOnCloseAndSeqRestartIsNotLoss() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))
    let logRecorder = RecordingLogRecordSink()

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock,
      logSink: logRecorder)
    try await daemon.start()

    _ = try await daemon.startSessionForTesting(
      SessionStartParams(
        platform: "meet", externalID: "abc", sources: [], trigger: .browserExtension))
    let identity = SessionIdentity(platform: "meet", externalID: "abc")
    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let label: SourceID = "browser:meet:speaker-1"
    // Whole seconds per buffer, per reopenSameLabelResumesSameSource's
    // filename-precision note.
    let samples = [Float](repeating: 0.25, count: 16000)

    func push(_ streamID: String, seq: UInt32) async {
      await daemon.pushIngestAudio(
        streamID: streamID, samples: samples, sampleRate: 16000,
        stamp: IngestFrameStamp(seq: seq, sentAtEpochMs: clock.now().secondsSinceEpoch * 1000))
    }
    func statsRecords() -> [LogRecord] {
      logRecorder.recorded.filter { $0.event == "capture.ingest_stats" }
    }
    func field(_ record: LogRecord, _ key: String) -> LogValue? {
      record.fields.first { $0.key == key }?.value
    }

    // First pipeline instance: 3 frames, all well inside one 30s interval —
    // without the close-time flush this interval would never be emitted.
    let firstStreamID = try await daemon.openIngestSource(
      label: label, format: format, session: identity)
    for seq: UInt32 in [5, 6, 7] { await push(firstStreamID, seq: seq) }
    clock.advance(by: 2)
    await daemon.closeIngestSource(streamID: firstStreamID)

    let firstFlush = try #require(statsRecords().first)
    #expect(statsRecords().count == 1)
    #expect(field(firstFlush, "frames") == .int(3))
    #expect(field(firstFlush, "frames_lost") == nil)

    // The participant's pipeline is rebuilt: same label, fresh seq. Neither
    // the reopen (100 vs the old stream's 7 — only harmless because the close
    // cleared the baseline) nor a mid-stream restart (0 after 101) may be
    // misread as lost frames.
    let secondStreamID = try await daemon.openIngestSource(
      label: label, format: format, session: identity)
    await push(secondStreamID, seq: 100)
    await push(secondStreamID, seq: 101)
    await push(secondStreamID, seq: 0)
    clock.advance(by: 1)
    await daemon.closeIngestSource(streamID: secondStreamID)

    let flushes = statsRecords()
    #expect(flushes.count == 2)
    let secondFlush = try #require(flushes.last)
    #expect(field(secondFlush, "frames") == .int(3))
    #expect(field(secondFlush, "frames_lost") == nil)

    await daemon.stop()
  }

  @Test("a published segment.publish reaches a subscribed client end to end")
  func endToEndSegmentPublish() async throws {
    let dataRoot = try makeDataRoot()
    let socketPath = tempSocketPath()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: socketPath)

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [])
      },
      clock: clock)
    try await daemon.start()

    let watcher = try await ControlSocketClient.connect(toPath: socketPath)
    _ = try await watcher.hello(client: "test/0")
    let (_, events) = try await watcher.subscribe(SubscribeParams(events: [.segment]))
    while await daemon.subscriberCountForTesting() == 0 { await Task.yield() }

    // A second connection publishes — mirroring a real `transcribe --follow`
    // process, which keeps its own connection for publishing.
    let publisher = try await ControlSocketClient.connect(toPath: socketPath)
    _ = try await publisher.hello(client: "test/0")
    let segment = SegmentPublishParams(
      session: "s_call", speaker: "You", start: 604.1, end: 611.9, text: "ship it")
    _ = try await publisher.send(.segmentPublish(segment), expecting: EmptyData.self)
    await publisher.close()

    var received: [EarsEvent] = []
    for await frame in events {
      received.append(frame.event)
      break
    }
    #expect(received == [.segment(segment)])

    await watcher.close()
    await daemon.stop()
  }

  @Test("openIngestSource rejects a label that isn't a browser:* source")
  func rejectsNonBrowserLabel() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    await #expect(throws: EarsDaemon.IngestError.self) {
      _ = try await daemon.openIngestSource(label: "mic", format: format)
    }

    await daemon.stop()
  }

  @Test(
    "full retention lifecycle: idle boot, session records under its directory, transcript completion starts the clock, and the sweeper deletes the audio at the deadline"
  )
  func retentionLifecycleEndToEnd() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [makeDescriptor(id: "mic", sourceClass: .mic)],
      dataRoot: dataRoot,
      socketPath: tempSocketPath(),
      evictAfterTranscriptSeconds: 100,
      maxAudioAgeSeconds: 1_000
    )
    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [self.makeBuffer(seconds: 2)])
      },
      clock: clock
    )
    try await daemon.start()

    // Idle boot: nothing on disk.
    #expect(
      !FileManager.default.fileExists(
        atPath: DataStoreLayout.sessionsDirectory(dataRoot: dataRoot).path))

    // A session records real audio under its own directory, then ends.
    let session = try await daemon.startSessionForTesting(
      SessionStartParams(title: "call", sources: ["mic"]))
    clock.advance(by: 600)
    try await daemon.endSessionForTesting(id: session.id)

    let sourcesDir = DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: session.id)
      .appendingPathComponent("sources")
    #expect(FileManager.default.fileExists(atPath: sourcesDir.path))

    // The transcript completes, starting the retention clock.
    await daemon.markTranscriptCompletedForTesting(id: session.id)

    // One second before completion + evict_after_transcript_seconds: retained.
    clock.advance(by: 99)
    await daemon.sweepRetentionForTesting()
    #expect(FileManager.default.fileExists(atPath: sourcesDir.path))

    // At the deadline: the audio is gone; the session's record survives.
    clock.advance(by: 1)
    await daemon.sweepRetentionForTesting()
    #expect(!FileManager.default.fileExists(atPath: sourcesDir.path))
    #expect(
      FileManager.default.fileExists(
        atPath: DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: session.id).path))

    // A second session whose transcript never completes: its audio survives
    // past the transcript deadline and is deleted only at the hard cap.
    let failed = try await daemon.startSessionForTesting(
      SessionStartParams(title: "no-transcript", sources: ["mic"]))
    clock.advance(by: 600)
    try await daemon.endSessionForTesting(id: failed.id)
    let failedSourcesDir = DataStoreLayout.sessionDirectory(
      dataRoot: dataRoot, sessionID: failed.id
    ).appendingPathComponent("sources")
    #expect(FileManager.default.fileExists(atPath: failedSourcesDir.path))

    clock.advance(by: 999)
    await daemon.sweepRetentionForTesting()
    #expect(FileManager.default.fileExists(atPath: failedSourcesDir.path))

    clock.advance(by: 1)
    await daemon.sweepRetentionForTesting()
    #expect(!FileManager.default.fileExists(atPath: failedSourcesDir.path))
    #expect(
      FileManager.default.fileExists(
        atPath: DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: failed.id).path))

    await daemon.stop()
  }

  @Test("openIngestSource rejects an open whose session identity can't be resolved")
  func rejectsIngestOpenWithoutResolvableSession() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath())

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    // No session tag at all: nowhere to put the audio.
    await #expect(throws: EarsDaemon.IngestError.self) {
      _ = try await daemon.openIngestSource(label: "browser:meet:jane-a1b2", format: format)
    }
    // A tag naming an identity no live session declared (ingest.open raced
    // ahead of session.start): rejected too — the client retries after its
    // session.start lands.
    await #expect(throws: EarsDaemon.IngestError.self) {
      _ = try await daemon.openIngestSource(
        label: "browser:meet:jane-a1b2", format: format,
        session: SessionIdentity(platform: "meet", externalID: "never-started"))
    }

    await daemon.stop()
  }

  // MARK: - single active session invariant (#19 / #27)

  @Test(
    "a browser slot label reused under a superseding session rebuilds against the new session's directory"
  )
  func ingestRebuildsAgainstNewSessionOnMismatch() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))
    let logRecorder = RecordingLogRecordSink()

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: tempSocketPath(),
      // Keep session-end from spawning real pipeline subprocesses when the
      // first session is superseded — this test is about capture directories.
      onEndStages: [])

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock,
      logSink: logRecorder)
    try await daemon.start()

    let label: SourceID = "browser:meet:speaker-1"
    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let samples = [Float](repeating: 0.25, count: 16000)  // 1 s @ 16 kHz

    // Session A: opens the slot label, streams, then the tab drops (ingest close)
    // WITHOUT a session.end — the exact shape that left a browser actor pointing
    // at A's tree in the incident.
    let a = try await daemon.startSessionForTesting(
      SessionStartParams(
        platform: "meet", externalID: "aaa", sources: [], trigger: .browserExtension))
    let streamA = try await daemon.openIngestSource(
      label: label, format: format, session: SessionIdentity(platform: "meet", externalID: "aaa"))
    await daemon.pushIngestAudio(streamID: streamA, samples: samples, sampleRate: 16000)
    await daemon.closeIngestSource(streamID: streamA)

    // Session B starts — superseding A under the single-active invariant — and
    // rejoins the SAME slot label. The label-only reuse would have written B's
    // audio into A's directory (#19 manifestation B); the (SourceID, sessionID)
    // identity check rebuilds against B's directory instead.
    let b = try await daemon.startSessionForTesting(
      SessionStartParams(
        platform: "meet", externalID: "bbb", sources: [], trigger: .browserExtension))
    #expect(b.id != a.id)
    let streamB = try await daemon.openIngestSource(
      label: label, format: format, session: SessionIdentity(platform: "meet", externalID: "bbb"))
    await daemon.pushIngestAudio(streamID: streamB, samples: samples, sampleRate: 16000)
    await daemon.closeIngestSource(streamID: streamB)

    // B's audio landed under B's own directory.
    #expect(
      !chunkFiles(dataRoot: dataRoot, sessionID: b.id, source: label).isEmpty,
      "expected B's audio under B's own directory after the rebuild")

    // A's audio is still under A's directory — not stranded, not overwritten.
    #expect(
      !chunkFiles(dataRoot: dataRoot, sessionID: a.id, source: label).isEmpty,
      "expected A's audio to remain under A's directory")

    // The reuse-mismatch error line fired (the daemon's string log is
    // fire-and-forget, so poll briefly for it to land).
    var sawMismatch = false
    for _ in 0..<100 {
      if logRecorder.recorded.contains(where: { $0.msg?.contains("reuse-mismatch") == true }) {
        sawMismatch = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sawMismatch)

    await daemon.stop()
  }

  // MARK: - Native-app meeting detection

  @Test("meeting activity reaches a real-socket subscriber and the status snapshot")
  func meetingActivityOverTheSocket() async throws {
    let dataRoot = try makeDataRoot()
    let socketPath = tempSocketPath()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    var zoomDescriptor = makeDescriptor(id: "app:us.zoom.xos", sourceClass: .app)
    zoomDescriptor.label = "Zoom"
    let configuration = EarsDaemonConfiguration(
      sources: [zoomDescriptor],
      dataRoot: dataRoot,
      socketPath: socketPath,
      // A non-zero debounce, confirmed only once the clock is advanced past it
      // below (after the subscriber barrier), so the edge cannot possibly be
      // confirmed — and published — before the subscription is registered.
      // ScriptedProbe repeats its single scripted entry forever, so with
      // nothing gating confirmation, a wall-clock-driven debounce would race
      // the socket handshake instead: the edge fires on whichever poll lands
      // after ~1s of real time, independent of subscriber readiness.
      detection: DetectionSettings(enabled: true, debounceSeconds: 5, appIdleGraceSeconds: 90))

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [])
      },
      clock: clock,
      activityProbe: ScriptedProbe([["us.zoom.xos": true]]))
    try await daemon.start()

    let client = try await ControlSocketClient.connect(toPath: socketPath)
    _ = try await client.hello(client: "test/0")
    let (_, events) = try await client.subscribe(SubscribeParams(events: [.meetingActivity]))
    while await daemon.subscriberCountForTesting() == 0 { await Task.yield() }

    // Only now does advancing the clock let the tracker's still-pending
    // sample (set by the monitor's first poll, at or before this point) clear
    // its debounce on the next poll — the barrier above guarantees that poll's
    // confirmed edge has a registered subscriber to reach.
    clock.advance(by: 10)

    var received: [EarsEvent] = []
    for await frame in events {
      received.append(frame.event)
      break
    }
    #expect(
      received == [
        .meetingActivity(
          MeetingActivityStatus(
            source: "app:us.zoom.xos", bundleID: "us.zoom.xos", label: "Zoom", active: true,
            episode: "us.zoom.xos#1"))
      ])

    let status = try await client.send(.status, expecting: StatusData.self)
    #expect(
      status.meetingActivity == [
        MeetingActivityStatus(
          source: "app:us.zoom.xos", bundleID: "us.zoom.xos", label: "Zoom", active: true,
          episode: "us.zoom.xos#1")
      ])

    await client.close()
    await daemon.stop()
  }

  @Test("ears status can never show two active sessions: a second start supersedes the first")
  func statusShowsSingleActiveSessionAfterSupersede() async throws {
    let dataRoot = try makeDataRoot()
    let socketPath = tempSocketPath()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_000))

    let configuration = EarsDaemonConfiguration(
      sources: [],
      dataRoot: dataRoot,
      socketPath: socketPath,
      onEndStages: [])

    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in SyntheticCaptureBackend(source: descriptor.id, buffers: []) },
      clock: clock)
    try await daemon.start()

    let client = try await ControlSocketClient.connect(toPath: socketPath)
    _ = try await client.hello(client: "test/0")

    _ = try await client.send(
      .sessionStart(SessionStartParams(platform: "meet", externalID: "first")),
      expecting: Session.self)
    let second = try await client.send(
      .sessionStart(SessionStartParams(platform: "meet", externalID: "second")),
      expecting: Session.self)

    let status = try await client.send(.status, expecting: StatusData.self)
    #expect(status.sessions.count == 1)
    #expect(status.sessions.first?.id == second.id)
    #expect(status.sessions.allSatisfy { $0.state == .active })

    await client.close()
    await daemon.stop()
  }
}
