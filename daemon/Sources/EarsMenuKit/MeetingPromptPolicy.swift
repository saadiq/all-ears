import EarsCore

/// One prompt-worthy detected meeting: the episode the caller marks as
/// prompted, and the notification to post. The source and label a click acts
/// on ride inside `request.action`, so they are not duplicated here.
public struct MeetingPrompt: Sendable, Hashable {
  public var episode: String
  public var request: NotificationRequest

  public init(episode: String, request: NotificationRequest) {
    self.episode = episode
    self.request = request
  }
}

/// Decides which detected meetings deserve a prompt right now. Policy, not
/// state: the caller owns the already-prompted set (persisted across app
/// restarts, keyed on the daemon's episode ids) and marks episodes as it
/// posts. Episodes that begin while a session is live are dropped, not
/// deferred — no prompt fires for them later.
public enum MeetingPromptPolicy {
  public static func prompts(
    state: MenuState, alreadyPrompted: Set<String>
  ) -> [MeetingPrompt] {
    guard state.connection == .connected, state.activeSession == nil else { return [] }
    return state.activeMeetings
      .filter { !alreadyPrompted.contains($0.episode) }
      .map { activity in
        let label = activity.displayLabel
        return MeetingPrompt(
          episode: activity.episode,
          request: NotificationRequest(
            title: "\(label) meeting detected",
            body: "Start recording?",
            action: .startDetected(
              source: activity.source.rawValue, episode: activity.episode, label: label)))
      }
  }
}

/// The `session.start` platform slug for a detected native-app meeting.
public enum DetectedSessionIdentity {
  public static func platform(forBundleID bundleID: String) -> String {
    KnownMeetingApp.matching(bundleID: bundleID)?.platformSlug ?? bundleID
  }
}
