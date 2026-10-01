/// How the user answered a notification, as the notifier shim maps
/// `UNNotificationResponse.actionIdentifier`: a click on the body, one of the
/// category's registered buttons, or anything else (a system dismiss).
public enum NotificationResponseKind: Sendable, Hashable {
  case body
  case button(String)
  case other
}

extension MeetingPrompt {
  /// The payload a prompt is posted with, and read back off a click.
  public var userInfo: [String: String] {
    ["action": "startDetected", "source": source, "episode": episode, "label": label]
  }
}

/// A prompt the user said yes to: the source to record and the episode the
/// start is idempotent on.
public struct MeetingPromptAcceptance: Sendable, Hashable {
  public var source: String
  public var episode: String

  public init(source: String, episode: String) {
    self.source = source
    self.episode = episode
  }

  /// Acting is the exception, not the default. Naming the two responses that
  /// accept — a click on the body, and the Start button — means a response
  /// this app does not understand is ignored rather than treated as a yes:
  /// "Not Now", the system's own dismiss identifier if the category ever
  /// gains `.customDismissAction`, and any button added later all fall
  /// through. Declining needs no undo, since the episode was marked prompted
  /// when the notification went out.
  public static func accepted(
    _ kind: NotificationResponseKind, userInfo: [String: String]
  ) -> MeetingPromptAcceptance? {
    switch kind {
    case .body, .button(MeetingPromptCategory.start): break
    case .button, .other: return nil
    }
    guard userInfo["action"] == "startDetected", let source = userInfo["source"],
      let episode = userInfo["episode"]
    else { return nil }
    return MeetingPromptAcceptance(source: source, episode: episode)
  }
}
