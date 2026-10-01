import EarsCore
import Foundation
import Testing

@testable import EarsMenuKit

@Suite("DetectedSessionStart")
struct DetectedSessionStartTests {
  private func status(_ sources: [SourceID]?) -> StatusData {
    StatusData(
      uptimeSeconds: 1, sources: [],
      configured: sources.map { .init(sources: $0, onEndStages: ["transcribe"]) })
  }

  private let zoom = SourceID("app:us.zoom.xos")

  @Test("a Zoom meeting records mic and the app, as an app-detected zoom-app session")
  func zoomWithMic() throws {
    let params = try DetectedSessionStart.params(
      from: status(["mic", "system", zoom]), source: zoom, episode: "us.zoom.xos#3"
    ).get()
    #expect(params.sources == ["mic", zoom])
    #expect(params.platform == "zoom-app")
    #expect(params.externalID == "us.zoom.xos#3")
    #expect(params.trigger == .appDetected)
    #expect(params.title == nil)
    #expect(params.onEndStages == nil)
  }

  @Test("without a configured mic only the app source is declared")
  func noMic() throws {
    let params = try DetectedSessionStart.params(
      from: status([zoom]), source: zoom, episode: "us.zoom.xos#1"
    ).get()
    #expect(params.sources == [zoom])
  }

  @Test("bundle ids map to platform slugs with a bundle-id fallback")
  func platformSlugs() {
    #expect(DetectedSessionStart.platform(forBundleID: "us.zoom.xos") == "zoom-app")
    #expect(DetectedSessionStart.platform(forBundleID: "com.microsoft.teams2") == "teams-app")
    #expect(DetectedSessionStart.platform(forBundleID: "com.microsoft.teams") == "teams-app")
    #expect(DetectedSessionStart.platform(forBundleID: "com.tinyspeck.slackmacgap") == "slack-app")
    #expect(DetectedSessionStart.platform(forBundleID: "com.apple.avconferenced") == "facetime-app")
    #expect(DetectedSessionStart.platform(forBundleID: "com.example.other") == "com.example.other")
  }

  @Test("the wire payload omits on_end_stages and title, so the daemon's chain applies")
  func payloadOmitsChainAndTitle() throws {
    let params = try DetectedSessionStart.params(
      from: status(["mic", zoom]), source: zoom, episode: "us.zoom.xos#1"
    ).get()
    let json = try #require(String(data: JSONEncoder().encode(params), encoding: .utf8))
    #expect(!json.contains("on_end_stages"))
    #expect(!json.contains("title"))
    #expect(json.contains("\"trigger\":\"app-detected\""))
  }

  @Test("a daemon whose status has no configured block is refused as too old")
  func daemonTooOld() {
    #expect(
      DetectedSessionStart.params(from: status(nil), source: zoom, episode: "e")
        == .failure(.daemonTooOld))
  }

  @Test("an app source the running daemon no longer captures is refused")
  func sourceNotConfigured() {
    let result = DetectedSessionStart.params(from: status(["mic"]), source: zoom, episode: "e")
    #expect(result == .failure(.sourceNotConfigured("app:us.zoom.xos")))
    if case .failure(let refusal) = result {
      #expect(refusal.description.hasPrefix("app:us.zoom.xos is no longer configured in earsd"))
    }
  }
}
