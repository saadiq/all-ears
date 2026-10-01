import EarsCore

/// One detected meeting the menu offers to record: the row above the plain
/// verbs. Identified by its source — one standing offer per meeting app.
public struct MeetingOffer: Sendable, Hashable, Identifiable {
  public var source: String
  public var episode: String
  public var label: String

  public init(source: String, episode: String, label: String) {
    self.source = source
    self.episode = episode
    self.label = label
  }

  public var id: String { source }

  public var menuTitle: String { "Start Recording ‘\(label)’ Meeting" }
}

public enum MeetingOffers {
  /// The meetings worth offering right now: every active one, in activity
  /// order, but only while connected with nothing recording — the daemon
  /// records one session at a time, so an offer beside a live session could
  /// only fail.
  public static func render(_ activity: MeetingActivityState, menu: MenuState) -> [MeetingOffer] {
    guard menu.connection == .connected, menu.activeSession == nil else { return [] }
    return activity.active.map {
      MeetingOffer(source: $0.source.rawValue, episode: $0.episode, label: $0.displayLabel)
    }
  }
}
