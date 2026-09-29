/// Whether the app can actually deliver the notifications ``NotificationPolicy``
/// decides to post.
///
/// The policy answers *what* to notify about; this answers *whether the answer
/// gets through*. They are separate because macOS accepts a post from an
/// unauthorized app and then drops it: `UNUserNotificationCenter.add` reports
/// success, `usernoted` logs the record as `ineligible for pipeline …
/// authorizationStatus: Denied`, and the user sees nothing. Nothing in the app
/// notices — which is the same silent-failure shape this app refuses for
/// control calls, and it costs more here, because the user is not standing at
/// the menu waiting when a summary lands.
public enum NotificationAvailability: Sendable, Hashable {
  /// The grant was given, or has not been asked for yet. Quiet either way:
  /// warning before the prompt has been answered would fire on every launch.
  case authorized
  /// macOS refused the grant. Posts are accepted and silently dropped.
  case denied
  /// No bundle, so notifications were never on offer — a bare `swift run`
  /// binary rather than the installed `.app`.
  case unsupported

  /// The menu's warning, or `nil` when there is nothing the user can act on.
  public var menuLine: String? {
    switch self {
    case .authorized, .unsupported: return nil
    case .denied: return "⚠ Notifications are off — no summary alerts"
    }
  }
}
