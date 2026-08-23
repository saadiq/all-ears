/// The native meeting apps detection recognises, and the two things the menu
/// bar derives from a watched bundle id: the `session.start` platform slug and
/// the marker this app's join links carry inside a calendar event.
///
/// One table rather than a switch per consumer — a new app is one entry, and
/// a slug can no longer exist for an app whose calendar marker was forgotten.
/// An unrecognised bundle id is not an error: detection still works from the
/// configured `app:*` source alone, only the calendar hint is unavailable.
public enum KnownMeetingApp: Sendable, CaseIterable {
  case zoom
  case teams
  case slack
  case facetime

  /// The bundle id(s) an `app:` source names for this app — the process that
  /// holds its audio, which is not always the app you click — across every
  /// id it has shipped under.
  public var bundleIDs: [String] {
    switch self {
    case .zoom: ["us.zoom.xos"]
    case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
    case .slack: ["com.tinyspeck.slackmacgap"]
    // FaceTime's audio belongs to its avconferenced media daemon, not
    // FaceTime.app (see RealRunningApplicationTracker).
    case .facetime: ["com.apple.avconferenced"]
    }
  }

  /// The `session.start` platform slug for a session this app triggered.
  public var platformSlug: String {
    switch self {
    case .zoom: "zoom-app"
    case .teams: "teams-app"
    case .slack: "slack-app"
    case .facetime: "facetime-app"
    }
  }

  /// The substring this app's join links carry, matched against a calendar
  /// event's location, notes, and URL.
  ///
  /// Slack's is narrower than the others by necessity: `zoom.us` and
  /// `teams.microsoft` appear in join links and virtually nowhere else, but a
  /// bare `slack.com` also matches every message permalink and workspace URL
  /// pasted into an invite — it would mark events that are not huddles. Most
  /// huddles are ad-hoc and never reach a calendar at all, so this marker
  /// rarely decides anything; the nearest-ongoing-event fallback does.
  public var linkMarker: String {
    switch self {
    case .zoom: "zoom.us"
    case .teams: "teams.microsoft"
    case .slack: "slack.com/huddle"
    // FaceTime links are `https://facetime.apple.com/join#...`; nothing else
    // lives on that host.
    case .facetime: "facetime.apple.com"
    }
  }

  public static func matching(bundleID: String) -> KnownMeetingApp? {
    allCases.first { $0.bundleIDs.contains(bundleID) }
  }
}
