import EarsCore

/// What Start Recording asks the daemon for: exactly the sources and chain
/// the running daemon reports in `status.configured`. The app never reads
/// daemon config, so what it asks for cannot drift from what the daemon on
/// the other end of the socket will capture and run.
public enum StartRecording {
  public enum Refusal: Error, Sendable, Hashable, CustomStringConvertible {
    /// `status` carried no `configured` block: a daemon older than this app.
    case daemonTooOld
    /// The daemon captures no configured source; a session would record nothing.
    case noSources

    public var description: String {
      switch self {
      case .daemonTooOld:
        return "earsd is older than this menu bar app — reinstall with `make install`."
      case .noSources:
        return "No capture sources are configured — see [[earsd.source]] in your config."
      }
    }
  }

  /// No title: the daemon names an unnamed manual session itself, and a
  /// title sent here would read as one the user chose.
  public static func params(from status: StatusData) -> Result<SessionStartParams, Refusal> {
    guard let configured = status.configured else { return .failure(.daemonTooOld) }
    guard !configured.sources.isEmpty else { return .failure(.noSources) }
    return .success(
      SessionStartParams(sources: configured.sources, onEndStages: configured.onEndStages))
  }
}
