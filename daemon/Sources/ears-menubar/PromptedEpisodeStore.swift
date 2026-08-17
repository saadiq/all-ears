import Foundation

/// Episodes already prompted (or accepted), persisted so a menu bar restart
/// mid-meeting doesn't re-prompt for the same episode. Bounded: only the
/// most recent entries are kept.
struct PromptedEpisodeStore {
  private static let key = "promptedMeetingEpisodes"
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
}
