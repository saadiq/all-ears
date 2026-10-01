/// Episodes already prompted (or accepted, or dropped), so none is offered
/// twice — including across a menu bar restart mid-meeting, which is why the
/// app persists this value. Bounded: only the most recent ``cap`` entries are
/// kept, oldest evicted first.
///
/// Scoped to the daemon boot behind the episode ids (see
/// ``activate(bootID:)``): without that scoping, a daemon restart's fresh
/// episode counter collides with the previous boot's already-prompted ids and
/// every early meeting of the new boot silently never prompts.
public struct PromptedEpisodes: Sendable, Hashable {
  public static let cap = 50

  public private(set) var episodes: [String]
  public private(set) var bootID: String?

  public init(episodes: [String] = [], bootID: String? = nil) {
    self.episodes = episodes
    self.bootID = bootID
  }

  public var set: Set<String> { Set(episodes) }

  public mutating func mark(_ episode: String) {
    guard !episodes.contains(episode) else { return }
    episodes.append(episode)
    if episodes.count > Self.cap { episodes.removeFirst(episodes.count - Self.cap) }
  }

  /// Called on every `hello` (fresh connect or reconnect) with the daemon's
  /// boot id, before any prompting can occur. Clears the history when the
  /// boot id has changed — see ``PromptedEpisodePolicy``.
  public mutating func activate(bootID current: String) {
    guard PromptedEpisodePolicy.shouldReset(storedBootID: bootID, currentBootID: current) else {
      return
    }
    episodes = []
    bootID = current
  }
}
