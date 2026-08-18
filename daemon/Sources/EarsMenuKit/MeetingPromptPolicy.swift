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

/// The notification category a detected-meeting prompt is posted under, and
/// the buttons it carries. `Notifier` registers these with
/// `UNUserNotificationCenter` at launch and reads them back off a click; the
/// identifiers live here rather than in that shim so both sides of the seam
/// name the same strings — see ``NotificationRequest/Action/notificationCategory``
/// for which notifications claim this category.
public enum MeetingPromptCategory {
  public static let identifier = "meeting-detected"
  /// Accepts the offer — the same effect as clicking the notification body.
  public static let start = "start-recording"
  /// Declines it. Nothing to undo: the episode is marked prompted when the
  /// notification is *posted*, so declining only closes the notification.
  public static let dismiss = "not-now"

  /// The notification id a prompt for `episode` is posted under.
  ///
  /// Keyed on the episode rather than freshly minted per post, because an
  /// offer to record a meeting goes stale: the meeting ends, or a session
  /// starts by other means, and the notification is left offering something
  /// that no longer stands. An alert-style prompt does not fade on its own
  /// (see `NSUserNotificationAlertStyle` in the app's Info.plist), so the app
  /// has to withdraw it — which it can only do if it can name it.
  public static func notificationIdentifier(episode: String) -> String {
    "\(identifier):\(episode)"
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
