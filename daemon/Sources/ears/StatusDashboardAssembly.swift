import EarsCore
import EarsDataStore
import Foundation

/// Assembles the status dashboard's inputs: the daemon's `status` payload
/// plus what disk adds — per-session speech evidence from `attribution.jsonl`
/// and the recent-sessions tail. Disk being unavailable (unresolvable
/// config, no data root yet) degrades to a daemon-only dashboard rather than
/// failing the command: the daemon half is the part status has always shown.
enum StatusDashboardAssembly {
  /// How many ended sessions the dashboard's recent tail shows.
  static let recentTailCount = 3

  static func dashboard(status: StatusData, configFlag: String?, debug: DebugLog) -> String {
    let now = Instant(secondsSinceEpoch: Date().timeIntervalSince1970)
    let timeZone = TimeZone.current

    var evidence: [String: AttributionSpeechEvidence] = [:]
    var recent: [SessionListEntry] = []
    var onEndChain = OnEndStage.allCases
    switch SessionArtifactScanner.environment(configFlag: configFlag) {
    case .failure(let error):
      debug.log("disk scan unavailable, rendering daemon state only: \(error.description)")
    case .success(let environment):
      onEndChain = environment.onEndChain
      for session in status.sessions where session.state != .ended {
        let url = SessionAttributionLog.fileURL(
          dataRoot: environment.dataRoot, sessionID: session.id)
        if let jsonl = try? String(contentsOf: url, encoding: .utf8) {
          evidence[session.id] = AttributionBindingHints.speechEvidence(jsonl: jsonl)
        }
      }
      recent = SessionStore.readAll(dataRoot: environment.dataRoot)
        .filter { $0.state == .ended }
        .sorted { ($0.ended ?? $0.started) > ($1.ended ?? $1.started) }
        .prefix(recentTailCount)
        .map {
          SessionListEntry(
            session: $0,
            artifacts: SessionArtifactScanner.scan(session: $0, environment: environment))
        }
    }

    return StatusDashboardRendering.render(
      StatusDashboardInputs(
        status: status, evidenceBySession: evidence, recent: recent,
        configuredChain: onEndChain),
      now: now, timeZone: timeZone)
  }
}
