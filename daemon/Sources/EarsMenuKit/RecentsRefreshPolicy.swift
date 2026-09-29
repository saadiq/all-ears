import EarsCore

/// Decides when the Recent Sessions list is stale enough to re-read from disk.
///
/// The list is built by scanning the session store and the output tree, so it
/// cannot be derived from ``MenuState`` — something has to say *when* to look
/// again. Menu-open is not enough on its own: the scan is asynchronous, so a
/// refresh started when the menu opens lands after the menu has already been
/// built, leaving the list one open behind. Refreshing on the events that
/// change what the list would contain keeps it current *before* it is shown.
///
/// Two events change it:
///
/// - a session reaching `ended` adds a row (this is the only trigger that
///   fires when the daemon runs no on-end chain at all — with
///   `on_end_stages = []`, or against a daemon too old to run one, no job
///   event ever arrives for that session);
/// - a job finishing writes an artifact the row links to, so the row's
///   Open Summary / Open Transcript items go live.
public enum RecentsRefreshPolicy {
  public static func shouldRefresh(for frame: EventFrame) -> Bool {
    switch frame.event {
    case .session(let session):
      return session.state == .ended
    case .job(let job):
      return job.state == .done || job.state == .failed
    case .source, .vad, .segment:
      return false
    }
  }
}
