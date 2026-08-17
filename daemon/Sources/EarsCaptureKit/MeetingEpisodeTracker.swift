import EarsCore

/// One confirmed activity edge for a watched bundle id.
public struct MeetingActivityChange: Sendable, Hashable {
  public var bundleID: String
  public var active: Bool
  /// Daemon-boot-scoped: `<bundle-id>#<n>`, stable across one continuous
  /// meeting. An `active == false` change carries the id of the episode that
  /// just ended.
  public var episode: String

  public init(bundleID: String, active: Bool, episode: String) {
    self.bundleID = bundleID
    self.active = active
    self.episode = episode
  }
}

/// Pure debounce state machine turning raw per-poll activity samples into
/// **episodes**: a transition is confirmed only once the observed state has
/// persisted for `debounceSeconds`, so a mic-permission flap or a one-poll
/// glitch never begins or ends a meeting. Clock-injected via the `at`
/// parameter — no wall time.
public struct MeetingEpisodeTracker: Sendable {
  private let debounceSeconds: Double
  private var confirmed: [String: Bool] = [:]
  private var pendingSince: [String: (active: Bool, since: Instant)] = [:]
  private var episodeCounts: [String: Int] = [:]
  private var currentEpisode: [String: String] = [:]

  public init(debounceSeconds: Double) {
    self.debounceSeconds = debounceSeconds
  }

  public mutating func observe(
    bundleID: String, active: Bool, at now: Instant
  ) -> MeetingActivityChange? {
    let current = confirmed[bundleID] ?? false
    guard active != current else {
      pendingSince[bundleID] = nil
      return nil
    }
    guard let pending = pendingSince[bundleID], pending.active == active else {
      pendingSince[bundleID] = (active, now)
      return nil
    }
    guard now.interval(since: pending.since) >= debounceSeconds else { return nil }
    pendingSince[bundleID] = nil
    confirmed[bundleID] = active
    if active {
      let next = (episodeCounts[bundleID] ?? 0) + 1
      episodeCounts[bundleID] = next
      currentEpisode[bundleID] = "\(bundleID)#\(next)"
    }
    return MeetingActivityChange(
      bundleID: bundleID, active: active,
      episode: currentEpisode[bundleID] ?? "\(bundleID)#0")
  }
}
