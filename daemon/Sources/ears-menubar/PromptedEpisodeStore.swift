import EarsMenuKit
import Foundation

/// ``PromptedEpisodes`` persisted in UserDefaults, so a menu bar restart
/// mid-meeting doesn't re-prompt for the same episode. The keys predate the
/// pure type and are kept as they were, so an existing install keeps its
/// history.
struct PromptedEpisodeStore {
  private static let key = "promptedMeetingEpisodes"
  private static let bootIDKey = "promptedMeetingEpisodesBootID"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var episodes: Set<String> { load().set }

  func mark(_ episode: String) {
    var history = load()
    history.mark(episode)
    save(history)
  }

  /// Called on every `hello` (fresh connect or reconnect) with the daemon's
  /// boot id, before any prompting can occur — see
  /// ``PromptedEpisodes/activate(bootID:)``.
  func activate(bootID: String) {
    var history = load()
    history.activate(bootID: bootID)
    save(history)
  }

  private func load() -> PromptedEpisodes {
    PromptedEpisodes(
      episodes: defaults.stringArray(forKey: Self.key) ?? [],
      bootID: defaults.string(forKey: Self.bootIDKey))
  }

  private func save(_ history: PromptedEpisodes) {
    defaults.set(history.episodes, forKey: Self.key)
    defaults.set(history.bootID, forKey: Self.bootIDKey)
  }
}
