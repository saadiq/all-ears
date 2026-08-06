import EarsCore
import EarsDataStore
import EarsMenuKit
import Foundation

/// Read-only bridge from the on-disk stores to menu items. Never writes —
/// earsd stays the only writer.
struct RecentSessionsProvider: Sendable {
  var dataRoot: String
  var outputRoot: String

  func load(limit: Int = 7) -> [RecentSessionItem] {
    let all = SessionStore.readAll(dataRoot: URL(fileURLWithPath: dataRoot))
    return RecentSessions.select(from: all, limit: limit).map { session in
      guard let key = SessionArtifactLocator.key(for: session) else {
        return RecentSessionItem(session: session, transcript: nil, clean: nil, summaries: [])
      }
      let day = URL(fileURLWithPath: outputRoot).appendingPathComponent(key.day)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: day.path)) ?? []
      let artifacts = SessionArtifactLocator.classify(filenames: names, key: key)
      return RecentSessionItem(
        session: session,
        transcript: artifacts.transcript.map { day.appendingPathComponent($0) },
        clean: artifacts.clean.map { day.appendingPathComponent($0) },
        summaries: artifacts.summaries.map { day.appendingPathComponent($0) })
    }
  }
}
