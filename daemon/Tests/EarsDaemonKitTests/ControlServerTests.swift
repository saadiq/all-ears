import EarsCore
import EarsCoreTestSupport
import EarsIPC
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Covers ``ControlServer``'s v2 dispatch: the reply frames it builds
/// (`{"id", "result"}` / `{"id", "error": {"code", "message"}}`), the stable
/// error-code mapping, the `subscribe` snapshot, and routing into the
/// session registry. Transport-level concerns (`hello` gating,
/// capability tiers) live in `EarsIPCTests` — every call reaching this actor
/// has already cleared them.
@Suite("ControlServer")
struct ControlServerTests {
  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ControlServerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeServer(
    captureActors: [SourceID: CaptureActor] = [:],
    dataRoot: URL,
    startInstant: Instant = Instant(secondsSinceEpoch: 0),
    clock: any NowProviding,
    bus: EventBus? = nil,
    sessions: SessionRegistry? = nil
  ) -> ControlServer {
    ControlServer(
      captureActors: captureActors,
      dataRoot: dataRoot,
      startInstant: startInstant,
      clock: clock,
      bus: bus,
      sessions: sessions)
  }

  /// Decodes a `ControlReply`'s JSON frame (with a fixed test id) for
  /// assertions.
  private func frame(_ reply: ControlReply) throws -> [String: Any] {
    let data = try reply.encoded(id: .int(1), using: JSONEncoder())
    let object: [String: Any]? = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try #require(object)
  }

  /// The reply's `result` object, failing the test on an error frame.
  private func result(_ reply: ControlReply) throws -> [String: Any] {
    let json = try frame(reply)
    #expect(json["error"] == nil, "expected a result frame, got \(json)")
    let value: [String: Any]? = json["result"] as? [String: Any]
    return try #require(value)
  }

  /// The reply's `error.code`, failing the test on a result frame.
  private func errorCode(_ reply: ControlReply) throws -> String {
    let json = try frame(reply)
    let error: [String: Any]? = json["error"] as? [String: Any]
    let code: String? = try #require(error)["code"] as? String
    return try #require(code)
  }

  // MARK: - status / subscribe

  @Test("status reports uptime, sources, and the (empty) session list")
  func statusReportsUptime() async throws {
    let clock = ManualClock(Instant(secondsSinceEpoch: 1000))
    let server = makeServer(
      dataRoot: try makeDataRoot(), startInstant: Instant(secondsSinceEpoch: 100), clock: clock)

    let data = try result(await server.handle(.status))
    #expect(data["uptime_s"] as? Int == 900)
    #expect((data["sources"] as? [Any])?.isEmpty == true)
    #expect((data["sessions"] as? [Any])?.isEmpty == true)
  }

  @Test("status never reports negative uptime, even if the clock precedes startInstant")
  func statusClampsNegativeUptime() async throws {
    let clock = ManualClock(Instant(secondsSinceEpoch: 50))
    let server = makeServer(
      dataRoot: try makeDataRoot(), startInstant: Instant(secondsSinceEpoch: 100), clock: clock)

    let data = try result(await server.handle(.status))
    #expect(data["uptime_s"] as? Int == 0)
  }

  @Test("subscribe returns a snapshot tagged with the bus's current revision")
  func subscribeSnapshot() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let bus = EventBus()
    await bus.publish(.source(id: "mic", state: .capturing))  // rev 1
    let sessions = SessionRegistry(dataRoot: dataRoot, clock: clock, bus: bus)
    let started = try await sessions.start(SessionStartParams(title: "standup"))  // rev 2
    let server = makeServer(dataRoot: dataRoot, clock: clock, bus: bus, sessions: sessions)

    let data = try result(await server.handle(.subscribe(SubscribeParams())))
    #expect(data["rev"] as? Int == 2)
    let snapshotSessions: [[String: Any]]? = data["sessions"] as? [[String: Any]]
    #expect(try #require(snapshotSessions).count == 1)
    #expect(try #require(snapshotSessions).first?["id"] as? String == started.id)
  }

  // MARK: - sources / capture error mapping

  @Test("sources.add fails clearly rather than silently accepting")
  func sourcesAddNotSupported() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    let spec = SourceSpec(id: "app:us.zoom.xos", sourceClass: .app)
    #expect(try errorCode(await server.handle(.sourcesAdd(spec))) == "invalid_request")
  }

  @Test(
    "source verbs on an unknown id fail with source_not_found",
    arguments: [
      ControlCall.sourcesEnable(source: "mic"),
      .sourcesDisable(source: "mic"),
      .sourcesRemove(source: "mic"),
      .capturePause(source: "mic"),
      .captureResume(source: "mic"),
    ])
  func unknownSourceMapping(call: ControlCall) async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    let reply = await server.handle(call)
    #expect(try errorCode(reply) == "source_not_found")
    let json = try frame(reply)
    let error: [String: Any]? = json["error"] as? [String: Any]
    #expect((try #require(error)["message"] as? String)?.contains("mic") == true)
  }

  @Test(
    "fan-out verbs over zero sources succeed trivially",
    arguments: [ControlCall.capturePause(source: nil), .captureResume(source: nil), .flush])
  func fanOutEmpty(call: ControlCall) async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    _ = try result(await server.handle(call))
  }

  // MARK: - notification-only publishes

  @Test("segment.publish and job.publish forward to the bus and reply ok")
  func publishesForwardToBus() async throws {
    let clock = ManualClock()
    let bus = EventBus()
    let recorded = Mutex<[EventFrame]>([])
    await bus.attach { frame in recorded.withLock { $0.append(frame) } }
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock, bus: bus)

    let segment = SegmentPublishParams(
      session: "s1", speaker: "You", start: 604.1, end: 611.9, text: "ship it")
    _ = try result(await server.handle(.segmentPublish(segment)))
    let job = JobPublishParams(job: "j1", kind: "transcribe", session: "m1", state: .running)
    _ = try result(await server.handle(.jobPublish(job)))

    for _ in 0..<1_000 {
      if recorded.withLock({ $0.count }) >= 2 { break }
      await Task.yield()
    }
    let frames = recorded.withLock { $0 }
    #expect(frames.map(\.event) == [.segment(segment), .job(job)])
    #expect(frames.allSatisfy { $0.rev == nil })  // telemetry, never revved
  }

  @Test("segment.publish with no bus attached still replies ok (drop, don't fail)")
  func segmentPublishWithoutBusSucceeds() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    _ = try result(
      await server.handle(
        .segmentPublish(
          SegmentPublishParams(session: "s1", speaker: "You", start: 0, end: 1, text: "hi"))))
  }

  // MARK: - makeHandler wiring

  @Test("makeHandler forwards to handle(_:)")
  func makeHandlerForwards() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    let handler = server.makeHandler()
    let data = try result(await handler(.sourcesList))
    #expect((data["sources"] as? [Any])?.isEmpty == true)
  }

  // MARK: - session dispatch

  @Test("session verbs fail with internal when no registry is wired")
  func sessionWithoutRegistryFails() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    #expect(
      try errorCode(await server.handle(.sessionStart(SessionStartParams()))) == "internal")
  }

  @Test("session.start is idempotent through the wire and returns the full session object")
  func sessionStartIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let sessions = SessionRegistry(dataRoot: dataRoot, clock: clock)
    let server = makeServer(dataRoot: dataRoot, clock: clock, sessions: sessions)
    let params = SessionStartParams(
      platform: "meet", externalID: "abc", trigger: .browserExtension)

    let first = try result(await server.handle(.sessionStart(params)))
    let firstID = try #require(first["id"] as? String)
    #expect(first["state"] as? String == "active")
    #expect((first["intervals"] as? [Any])?.count == 1)

    let again = try result(await server.handle(.sessionStart(params)))
    #expect(again["id"] as? String == firstID)
  }

  @Test("session error mapping: not-found, ended, and rename conflict codes")
  func sessionErrorMapping() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let sessions = SessionRegistry(dataRoot: dataRoot, clock: clock)
    let server = makeServer(dataRoot: dataRoot, clock: clock, sessions: sessions)

    #expect(
      try errorCode(await server.handle(.sessionPause(session: "nope"))) == "session_not_found")

    let started = try result(
      await server.handle(.sessionStart(SessionStartParams(title: "standup"))))
    let id = try #require(started["id"] as? String)
    _ = try result(await server.handle(.sessionEnd(session: id)))
    #expect(try errorCode(await server.handle(.sessionResume(session: id))) == "session_ended")
    #expect(
      try errorCode(
        await server.handle(
          .sessionRename(SessionRenameParams(session: "nope", title: "x", ifRev: nil))))
        == "session_not_found")

    let second = try result(
      await server.handle(.sessionStart(SessionStartParams(title: "retro"))))
    let secondID = try #require(second["id"] as? String)
    #expect(
      try errorCode(
        await server.handle(
          .sessionRename(SessionRenameParams(session: secondID, title: "x", ifRev: 999))))
        == "conflict")
  }

  @Test("session.list returns live + recent sessions")
  func sessionList() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let sessions = SessionRegistry(dataRoot: dataRoot, clock: clock)
    let server = makeServer(dataRoot: dataRoot, clock: clock, sessions: sessions)
    _ = try result(await server.handle(.sessionStart(SessionStartParams(title: "standup"))))

    let data = try result(await server.handle(.sessionList))
    #expect((data["sessions"] as? [Any])?.count == 1)
  }
}
