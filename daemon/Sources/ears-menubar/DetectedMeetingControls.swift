import EarsCore
import EarsMenuKit

/// Starting a detected meeting, as control calls. Returns why it failed, or
/// `nil`, like ``SessionControls``: a start that silently does nothing
/// leaves the user believing a meeting is being recorded when it is not.
struct DetectedMeetingControls: Sendable {
  let connection: DaemonConnection
  /// `@MainActor`, and so `Sendable` to hold here; its calls hop there.
  let calendar: CalendarProvider

  /// Asks the daemon what it captures, starts the meeting's app source
  /// beside `mic` — see ``DetectedSessionStart`` — then enriches the session
  /// from a matching calendar event when one exists: a `session.rename` to
  /// the event's title, and its attendees upserted onto the roster.
  ///
  /// Recording starts *before* any calendar fetch — a first-ever calendar
  /// access on this machine blocks on an OS permission dialog, and that
  /// must never delay a capture the user just asked for. Calendar access is
  /// a garnish, never a gate — denied access or no match leaves the session
  /// running unenriched.
  func start(source: SourceID, episode: String) async -> String? {
    guard let status = await connection.status() else { return "not connected to earsd" }
    switch DetectedSessionStart.params(from: status, source: source, episode: episode) {
    case .failure(let refusal):
      return refusal.description
    case .success(let params):
      switch await connection.startSession(params) {
      case .failure(let error): return error.message
      case .success(let session): return await enrich(session: session, source: source)
      }
    }
  }

  /// Sends ``CalendarEnrichment``'s calls in order, stopping at the first
  /// failure and reporting it; earlier successes stand.
  private func enrich(session: Session, source: SourceID) async -> String? {
    guard let events = await calendar.eventsAroundNow(),
      let matched = CalendarMatching.best(
        events: events, now: AppClock.now(),
        platformMarker: CalendarMatching.marker(forBundleID: source.detail ?? ""))
    else { return nil }
    for call in CalendarEnrichment.calls(session: session.id, event: matched) {
      if let error = await connection.perform(call) { return error.message }
    }
    return nil
  }
}
