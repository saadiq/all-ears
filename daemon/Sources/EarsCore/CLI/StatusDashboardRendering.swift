import Foundation

/// Everything the status dashboard needs, assembled by the `ears` executable:
/// the daemon's `status` payload, per-session speech evidence read from each
/// session's `attribution.jsonl` (absent key = no log, so no claim), and the
/// recent-sessions tail read from disk.
public struct StatusDashboardInputs: Sendable {
  public var status: StatusData
  public var evidenceBySession: [String: AttributionSpeechEvidence]
  public var recent: [SessionListEntry]

  public init(
    status: StatusData,
    evidenceBySession: [String: AttributionSpeechEvidence],
    recent: [SessionListEntry]
  ) {
    self.status = status
    self.evidenceBySession = evidenceBySession
    self.recent = recent
  }
}

/// Renders `ears status` (and bare `ears`) as a human dashboard: a daemon
/// header, each live session with its sources grouped beneath it, any
/// leftover sources, and a short recent tail.
///
/// Source ids are opaque track handles (`docs/data-formats.md`, "Source
/// labeling"): a browser source renders under an attendee's display name
/// only when the speaker map or the roster's `source` link provides one, and
/// otherwise as "remote audio (tN)" — never as an identity parsed out of the
/// id. `mic` is you.
public enum StatusDashboardRendering {
  public static func render(
    _ inputs: StatusDashboardInputs, now: Instant, timeZone: TimeZone
  ) -> String {
    var blocks: [String] = [header(inputs.status)]

    let live = inputs.status.sessions.filter { $0.state != .ended }
    for session in live {
      blocks.append(
        sessionBlock(
          session: session,
          sources: inputs.status.sources,
          evidence: inputs.evidenceBySession[session.id],
          now: now, timeZone: timeZone))
    }

    let claimed = Set(live.flatMap(\.sources))
    let leftover = inputs.status.sources.filter { !claimed.contains($0.id) }
    if !leftover.isEmpty {
      let width = leftover.map(\.id.rawValue.count).max() ?? 0
      var lines = ["sources"]
      for source in leftover {
        let id = source.id.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
        var line = "  \(id)  \(source.state.rawValue)"
        if source.bytesUsed > 0 { line += "  \(HumanUnits.bytes(source.bytesUsed))" }
        lines.append(line)
      }
      blocks.append(lines.joined(separator: "\n"))
    }

    if !inputs.recent.isEmpty {
      let width = inputs.recent.map(\.session.title.count).max() ?? 0
      var lines = ["recent"]
      for entry in inputs.recent {
        let clock = HumanUnits.clock(entry.session.started, timeZone: timeZone)
        let title = entry.session.title.padding(toLength: width, withPad: " ", startingAt: 0)
        let outcome = SessionPipeline.outcome(
          session: entry.session, artifacts: entry.artifacts, now: now)
        lines.append("  \(clock)  \(title)  \(outcome.glyph) \(outcome.text)")
      }
      blocks.append(lines.joined(separator: "\n"))
    }

    return blocks.joined(separator: "\n\n")
  }

  private static func header(_ status: StatusData) -> String {
    let up = HumanUnits.duration(seconds: Double(status.uptimeSeconds))
    let doing = status.sources.contains { $0.state == .capturing } ? "capturing" : "idle"
    return "earsd — up \(up), \(doing)"
  }

  private static func sessionBlock(
    session: Session, sources: [SourceStatus], evidence: AttributionSpeechEvidence?,
    now: Instant, timeZone: TimeZone
  ) -> String {
    let glyph = session.state == .paused ? "◐" : "●"
    var meta: [String] = []
    if let platform = session.identity?.platform { meta.append(platform) }
    if !session.attendees.isEmpty { meta.append("\(session.attendees.count) attendees") }
    let clock = HumanUnits.clock(session.started, timeZone: timeZone)
    let elapsed = HumanUnits.duration(seconds: now.interval(since: session.started))
    meta.append("started \(clock) (\(elapsed) ago)")
    var lines = ["\(glyph) \(session.title)  \(meta.joined(separator: " · "))"]

    let statusByID = Dictionary(
      uniqueKeysWithValues: sources.map { ($0.id, $0) })
    var rows: [(label: String, bytes: Int, marker: String?)] = []
    var silentGroup: (handles: [String], bytes: Int) = ([], 0)
    for sourceID in session.sources {
      guard let source = statusByID[sourceID] else { continue }
      switch sourceID.sourceClass {
      case .mic:
        rows.append(("you (mic)", source.bytesUsed, nil))
      case .browser:
        let handle = SessionPipeline.captureHandle(sourceID)
        let name = speakerName(for: sourceID, in: session)
        let marker = evidence.map {
          $0.speechCaptures.contains(handle) ? "carrying speech" : "silent"
        }
        if name == nil, marker == "silent" {
          silentGroup.handles.append(handle)
          silentGroup.bytes += source.bytesUsed
        } else {
          let label = name.map { "\($0) (\(handle))" } ?? "remote audio (\(handle))"
          rows.append((label, source.bytesUsed, marker))
        }
      default:
        rows.append((sourceID.rawValue, source.bytesUsed, nil))
      }
    }
    if silentGroup.handles.count == 1 {
      rows.append(("remote audio (\(silentGroup.handles[0]))", silentGroup.bytes, "silent"))
    } else if silentGroup.handles.count > 1 {
      rows.append((silentGroup.handles.joined(separator: ", "), silentGroup.bytes, "silent"))
    }

    let width = rows.map(\.label.count).max() ?? 0
    for row in rows {
      let label = row.label.padding(toLength: width, withPad: " ", startingAt: 0)
      var line = "    \(label)  \(HumanUnits.bytes(row.bytes))"
      if let marker = row.marker { line += "  \(marker)" }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }

  /// The display name the session's own data provides for a source, or `nil`
  /// — the speaker map first (authoritative once reconciled), then the
  /// roster's live `source` link. Never derived from the source id.
  private static func speakerName(for source: SourceID, in session: Session) -> String? {
    if let mapped = session.speakers.first(where: { $0.source == source }) {
      return mapped.name
    }
    return session.attendees.first { $0.source == source && !$0.isLocal }?.displayName
  }
}
