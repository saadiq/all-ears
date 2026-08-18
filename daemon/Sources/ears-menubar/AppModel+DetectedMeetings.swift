import EarsCore
import EarsMenuKit
import Foundation

/// Detecting and offering meetings the daemon has already noticed, and
/// turning an accepted offer into a recording enriched from the calendar.
/// Split out of `AppModel.swift` to keep that file under the project's
/// line-count limit; these members reach into state and helpers declared
/// there (`connection`, `calendar`, `promptedEpisodes`, `sources`, `report`,
/// `reloadDeclarations`, `clearActionError`, `now`), each left non-`private`
/// specifically so this extension can reach them.
extension AppModel {
  /// Prompts for any newly detected meeting the policy allows, and marks the
  /// episodes it prompts (or drops) so neither is offered again. A live
  /// session withdraws every standing offer.
  func offerDetectedMeetings() {
    // Only a live session voids an offer. An episode going inactive must
    // *not*: meeting apps drop and retake the input stream while a call is
    // being joined — Zoom was observed taking the mic, releasing it 17s later,
    // and taking it again — so withdrawing on that edge cancelled the prompt
    // within seconds of posting it, twice, before the user could answer.
    // Waiting to be answered is the whole point of an alert-style prompt.
    //
    // An offer for a call that has since ended therefore stays on screen, and
    // that is the intended trade: the notification id is keyed on the source,
    // so a later episode replaces it rather than stacking, and accepting a
    // stale one costs a session the daemon auto-ends after `idle_grace_s`.
    if state.activeSession != nil {
      announcements.withdrawMeetingPrompts(state.meetingActivity.map(\.source.rawValue))
      // Dropped, not deferred (the spec's prompt policy): an episode that
      // began while a session was live never prompts later — marking it
      // prompted now is what encodes the drop. The menu row still renders
      // from live state, so manual start remains available.
      for activity in state.activeMeetings { promptedEpisodes.mark(activity.episode) }
      return
    }
    let prompts = MeetingPromptPolicy.prompts(
      state: state, alreadyPrompted: promptedEpisodes.episodes)
    guard !prompts.isEmpty else { return }
    for prompt in prompts { promptedEpisodes.mark(prompt.episode) }
    announcements.announceMeetingPrompts(prompts)
  }

  /// Starts recording a meeting the daemon already detected, then enriches
  /// it from a matching calendar event when one exists: a `session.rename`
  /// to the event's title, and its attendees upserted onto the roster.
  /// Recording starts *before* any calendar fetch — a first-ever calendar
  /// access on this machine blocks on an OS permission dialog, and that
  /// must never delay a capture the user just asked for. Calendar access is
  /// a garnish, never a gate — denied access or no match leaves the session
  /// running unenriched.
  func startDetectedSession(source: String, episode: String) {
    guard let connection else { return }
    // Answered, whichever way this call ends: accepted from the notification
    // macOS has already taken down, or from the menu row, where this app's
    // standing offer may still be on screen offering what is about to start.
    announcements.withdrawMeetingPrompts([source])
    // An accept can arrive long after the offer, now that the prompt is
    // alert-style and recoverable from Notification Center: the menu only
    // offers the verb while idle, but a notification clicked after a session
    // started by other means lands here. The daemon records one session at a
    // time, so a second `session.start` would surface only as an error the
    // user did not cause.
    guard state.activeSession == nil else {
      promptedEpisodes.mark(episode)
      return
    }
    // Against the config as it is *now* — see ``startRecording()``.
    reloadDeclarations()
    let app = SourceID(source)
    var declared = sources.filter { $0 == SourceID("mic") }
    declared.append(app)
    promptedEpisodes.mark(episode)
    let platform = DetectedSessionIdentity.platform(forBundleID: app.detail ?? app.rawValue)
    let marker = CalendarMatching.marker(forBundleID: app.detail ?? "")
    // No on_end_stages: the daemon's own policy runs the configured chain
    // for app-detected sessions (OnEndChainPolicy), unlike manual starts.
    let params = SessionStartParams(
      platform: platform, externalID: episode, sources: declared, trigger: .appDetected)
    Task { [weak self] in
      guard let self else { return }
      switch await connection.startSession(params) {
      case .failure(let error):
        self.report(error.message)
      case .success(let session):
        self.clearActionError()
        await self.enrichFromCalendar(session: session, marker: marker, connection: connection)
      }
    }
  }

  /// Task 12's calendar enrichment for a session already started: matches a
  /// nearby calendar event, renames the session to its title, and upserts
  /// its attendees. Runs after `session.start` so a first-run permission
  /// dialog for calendar access never delays capture — see
  /// ``startDetectedSession(source:episode:)``.
  private func enrichFromCalendar(
    session: Session, marker: String?, connection: DaemonConnection
  ) async {
    let events = await calendar.eventsAroundNow()
    guard
      let matched = events.flatMap({
        CalendarMatching.best(events: $0, now: Self.now(), platformMarker: marker)
      })
    else { return }
    if !matched.title.isEmpty {
      let rename = SessionRenameParams(session: session.id, title: matched.title)
      if let error = await connection.perform(.sessionRename(rename)) {
        report(error.message)
      }
    }
    for (index, attendee) in matched.attendees.enumerated() {
      let upsert = SessionAttendeeParams(
        session: session.id,
        id: "calendar-\(index)",
        displayName: attendee.name,
        origin: .calendar,
        isLocal: attendee.isCurrentUser ? true : nil)
      if let error = await connection.perform(.sessionAttendee(upsert)) {
        report(error.message)
        break
      }
    }
  }
}
