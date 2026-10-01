import EarsCore
import EarsDataStore
import EarsMenuKit
import Foundation
import Observation

/// Reads recent sessions back from disk through the scanner `ears` uses.
/// Never writes: earsd stays the only writer.
struct RecentsLoader: Sendable {
  var environment: SessionScanEnvironment

  func load(limit: Int = 7, now: Instant) -> [RecentSessionItem] {
    let all = SessionStore.readAll(dataRoot: environment.dataRoot)
    return RecentSessions.select(from: all, limit: limit).map { item(for: $0, now: now) }
  }

  /// The first summary on disk for one session — a notification click's
  /// fallback when the daemon reported no path, or the file has moved.
  func summary(forSession id: String, now: Instant) -> URL? {
    guard let session = try? SessionStore.read(sessionID: id, dataRoot: environment.dataRoot)
    else { return nil }
    return item(for: session, now: now).summaries.first
  }

  private func item(for session: Session, now: Instant) -> RecentSessionItem {
    let artifacts = SessionArtifactScanner.scan(
      session: session, environment: environment, depth: .outcome)
    let outcome = SessionPipeline.outcome(
      session: session, artifacts: artifacts, now: now,
      configuredChain: environment.onEndChain, emptiness: environment.emptiness)
    return RecentSessionItem(session: session, artifacts: artifacts, outcome: outcome)
  }
}

/// The Recent Sessions submenu's rows, refreshed off the main actor so a
/// large store never stalls the menu bar.
@MainActor @Observable final class RecentsStore {
  private(set) var items: [RecentSessionItem] = []
  let loader: RecentsLoader?
  /// Refreshes overlap (menu open, a session ending, a job finishing), and a
  /// slower, older scan must not land over a newer one's rows.
  @ObservationIgnored private var generation = 0

  init(loader: RecentsLoader?) {
    self.loader = loader
  }

  func refresh() {
    guard let loader else { return }
    generation += 1
    let mine = generation
    Task.detached { [weak self] in
      let items = loader.load(now: AppClock.now())
      await MainActor.run {
        guard let self, self.generation == mine else { return }
        self.items = items
      }
    }
  }
}
