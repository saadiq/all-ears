import EarsCore

/// What accepting a detected meeting asks the daemon for. Like
/// ``StartRecording``, it reads the running daemon's `status.configured`
/// instead of daemon config, so what it declares is what that daemon will
/// actually capture.
public enum DetectedSessionStart {
  public enum Refusal: Error, Sendable, Hashable, CustomStringConvertible {
    /// `status` carried no `configured` block: a daemon older than this app.
    case daemonTooOld
    /// The meeting's app source is not one the running daemon captures.
    case sourceNotConfigured(String)

    public var description: String {
      switch self {
      case .daemonTooOld:
        return StartRecording.Refusal.daemonTooOld.description
      case .sourceNotConfigured(let source):
        return
          "\(source) is no longer configured in earsd — restart the daemon or re-add [[earsd.source]]."
      }
    }
  }

  /// The `session.start` platform slug for a detected native-app meeting.
  public static func platform(forBundleID bundleID: String) -> String {
    KnownMeetingApp.matching(bundleID: bundleID)?.platformSlug ?? bundleID
  }

  /// The meeting's app source, preceded by `mic` when the daemon captures
  /// one — the user's own side of the call.
  ///
  /// Refused when the app source is not configured: a prompt can outlive the
  /// daemon boot that raised it (it is alert-style and recoverable from
  /// Notification Center), and a daemon whose config dropped the source would
  /// silently skip it, recording the mic alone under a meeting's identity.
  ///
  /// The episode id is the external id, so a second accept of the same
  /// episode is idempotent. No `on_end_stages`: the daemon runs its
  /// configured chain for app-detected sessions (`OnEndChainPolicy`). No
  /// title: calendar enrichment renames it, else the daemon names it.
  public static func params(
    from status: StatusData, source: SourceID, episode: String
  ) -> Result<SessionStartParams, Refusal> {
    guard let configured = status.configured else { return .failure(.daemonTooOld) }
    guard configured.sources.contains(source) else {
      return .failure(.sourceNotConfigured(source.rawValue))
    }
    let mic = SourceID("mic")
    let sources = (configured.sources.contains(mic) ? [mic] : []) + [source]
    return .success(
      SessionStartParams(
        platform: platform(forBundleID: source.detail ?? source.rawValue), externalID: episode,
        sources: sources, trigger: .appDetected))
  }
}
