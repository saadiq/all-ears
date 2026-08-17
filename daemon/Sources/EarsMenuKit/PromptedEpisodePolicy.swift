/// Decides whether a stored episode-prompt history is stale because it
/// belongs to a different daemon boot than the one now connected.
///
/// Detected-meeting episode ids are `<bundle>#<n>`, minted from a counter
/// that restarts at every daemon boot (`MeetingEpisodeTracker`). The prompt
/// history persists across menu bar restarts (``PromptedEpisodeStore``), but
/// not across daemon restarts: without this check, boot 2's
/// `us.zoom.xos#1` collides with boot 1's already-prompted
/// `us.zoom.xos#1`, so the first N meetings of every daemon boot after the
/// first would silently never prompt. Episodes from a dead boot can never
/// recur, so discarding the whole history on a boot change is safe as well
/// as necessary.
public enum PromptedEpisodePolicy {
  public static func shouldReset(storedBootID: String?, currentBootID: String) -> Bool {
    storedBootID != currentBootID
  }
}
