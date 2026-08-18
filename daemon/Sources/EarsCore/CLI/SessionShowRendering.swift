import Foundation

/// Renders `ears session show`'s human view: a title header, the five
/// pipeline stage rows from ``SessionPipeline``, and the warnings tail.
public enum SessionShowRendering {
  public static func render(
    session: Session,
    artifacts: SessionArtifacts,
    now: Instant,
    timeZone: TimeZone,
    showWarnings: Bool,
    configuredChain: [OnEndStage]
  ) -> String {
    var lines = [header(session: session, now: now, timeZone: timeZone), ""]

    let stages = SessionPipeline.stages(
      session: session, artifacts: artifacts, now: now, configuredChain: configuredChain)
    let width = stages.map(\.name.count).max() ?? 0
    for stage in stages {
      let name = stage.name.padding(toLength: width, withPad: " ", startingAt: 0)
      lines.append("  \(name)  \(glyph(stage.state)) \(stage.detail)")
    }

    if !session.warnings.isEmpty {
      if showWarnings {
        lines.append(contentsOf: session.warnings.map { "  ⚠ \($0)" })
      } else {
        let count = session.warnings.count
        lines.append(
          "  ⚠ \(count) attribution warning\(count == 1 ? "" : "s") — show with --warnings")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func header(session: Session, now: Instant, timeZone: TimeZone) -> String {
    switch session.state {
    case .ended:
      let endedAt = session.ended ?? session.started
      let clock = HumanUnits.clock(endedAt, timeZone: timeZone)
      let length = HumanUnits.duration(seconds: endedAt.interval(since: session.started))
      return "\(session.title) — ended \(clock), \(length)"
    case .active, .paused:
      let verb = session.state == .active ? "recording" : "paused"
      let clock = HumanUnits.clock(session.started, timeZone: timeZone)
      let elapsed = HumanUnits.duration(seconds: now.interval(since: session.started))
      return "\(session.title) — \(verb), started \(clock) (\(elapsed) ago)"
    }
  }

  static func glyph(_ state: PipelineStageState) -> String {
    switch state {
    case .done: "✓"
    case .running, .waiting: "·"
    case .missing: "–"
    // Hollow, so a stage nobody asked for reads as an empty slot rather than
    // as the gap `–` marks or the in-flight `·`.
    case .notRequested: "○"
    }
  }
}

/// `ears session show --json`'s document: the wire-shape session, the derived
/// stage rows, the artifact paths the disk scan resolved, and the warnings —
/// a new surface, so its shape is pinned by tests from day one. Additive
/// keys only from here.
public struct SessionShowView: Codable, Hashable, Sendable {
  public var schema: Int
  public var session: Session
  public var stages: [Stage]
  public var artifacts: Artifacts
  public var warnings: [String]

  public struct Stage: Codable, Hashable, Sendable {
    public var stage: String
    public var state: PipelineStageState
    public var detail: String
  }

  public struct Artifacts: Codable, Hashable, Sendable {
    /// `sessions/<id>/transcript.md`, when present.
    public var transcript: String?
    /// The resolved `[cleanup] output` path, when it exists on disk.
    public var cleanup: String?
    /// `*.summary.md` siblings of the cleaned transcript.
    public var summaries: Int
    /// The published note link, verbatim from the cleaned transcript's
    /// `note:` frontmatter (wikilink or absolute path).
    public var note: String?
  }

  public static func build(
    session: Session, artifacts: SessionArtifacts, now: Instant, configuredChain: [OnEndStage]
  ) -> SessionShowView {
    SessionShowView(
      schema: 1,
      session: session,
      stages: SessionPipeline.stages(
        session: session, artifacts: artifacts, now: now, configuredChain: configuredChain
      )
      .map { Stage(stage: $0.name, state: $0.state, detail: $0.detail) },
      artifacts: Artifacts(
        transcript: artifacts.transcriptExists ? artifacts.transcriptPath : nil,
        cleanup: artifacts.cleanupExists ? artifacts.cleanupPath : nil,
        summaries: artifacts.summaryCount,
        note: artifacts.noteLink),
      warnings: session.warnings)
  }
}
