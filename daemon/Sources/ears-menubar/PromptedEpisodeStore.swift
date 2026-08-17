import EarsMenuKit
import Foundation

/// Episodes already prompted (or accepted), persisted so a menu bar restart
/// mid-meeting doesn't re-prompt for the same episode. Bounded: only the
/// most recent entries are kept.
///
/// Scoped to the daemon boot behind the episode ids (see ``activate(bootID:)``):
/// without that scoping, a daemon restart's fresh episode counter collides
/// with the previous boot's already-prompted ids and every early meeting of
/// the new boot silently never prompts.
struct PromptedEpisodeStore {
  private static let key = "promptedMeetingEpisodes"
  private static let bootIDKey = "promptedMeetingEpisodesBootID"
  private static let cap = 50
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var episodes: Set<String> {
    Set(defaults.stringArray(forKey: Self.key) ?? [])
  }

  func mark(_ episode: String) {
    var list = defaults.stringArray(forKey: Self.key) ?? []
    guard !list.contains(episode) else { return }
    list.append(episode)
    if list.count > Self.cap { list.removeFirst(list.count - Self.cap) }
    defaults.set(list, forKey: Self.key)
  }

  /// Called on every `hello` (fresh connect or reconnect) with the daemon's
  /// boot id, before any prompting can occur. Clears the history when the
  /// boot id has changed — see ``PromptedEpisodePolicy``.
  func activate(bootID: String) {
    let stored = defaults.string(forKey: Self.bootIDKey)
    guard PromptedEpisodePolicy.shouldReset(storedBootID: stored, currentBootID: bootID) else {
      return
    }
    defaults.set([String](), forKey: Self.key)
    defaults.set(bootID, forKey: Self.bootIDKey)
  }
}
