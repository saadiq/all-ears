import Foundation

/// One `ears sessions` row's inputs: the session record plus what the disk
/// scan found downstream of it.
public struct SessionListEntry: Sendable, Equatable {
  public var session: Session
  public var artifacts: SessionArtifacts

  public init(session: Session, artifacts: SessionArtifacts) {
    self.session = session
    self.artifacts = artifacts
  }
}

/// Renders the `ears sessions` list: one line per session with its id and
/// pipeline outcome, grouped by local start day (`TODAY`, `YESTERDAY`, then ISO
/// dates), newest first.
public enum SessionsListRendering {
  public static func render(
    entries: [SessionListEntry], now: Instant, timeZone: TimeZone,
    configuredChain: [OnEndStage], emptiness: TranscriptEmptinessPolicy = .defaults
  ) -> String {
    guard !entries.isEmpty else { return "(no sessions)" }
    let sorted = entries.sorted { $0.session.started > $1.session.started }
    let idWidth = sorted.map(\.session.id.count).max() ?? 0
    let titleWidth = sorted.map(\.session.title.count).max() ?? 0

    let today = HumanUnits.localDate(now, timeZone: timeZone)
    let yesterday = HumanUnits.localDate(now.advanced(by: -86_400), timeZone: timeZone)

    var lines: [String] = []
    var currentDay: String?
    for entry in sorted {
      let day = HumanUnits.localDate(entry.session.started, timeZone: timeZone)
      if day != currentDay {
        currentDay = day
        switch day {
        case today: lines.append("TODAY")
        case yesterday: lines.append("YESTERDAY")
        default: lines.append(day)
        }
      }
      let clock = HumanUnits.clock(entry.session.started, timeZone: timeZone)
      // The id is what every other verb takes (`ears session show <id>`,
      // `ears summarize --session <id>`), so it sits beside the clock where
      // it can be copied without hunting through `--json`.
      let id = entry.session.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
      let title = entry.session.title.padding(
        toLength: titleWidth, withPad: " ", startingAt: 0)
      let outcome = SessionPipeline.outcome(
        session: entry.session, artifacts: entry.artifacts, now: now,
        configuredChain: configuredChain, emptiness: emptiness)
      lines.append("  \(clock)  \(id)  \(title)  \(outcome.glyph) \(outcome.text)")
    }
    return lines.joined(separator: "\n")
  }
}
