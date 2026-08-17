/// One watched `app:*` source's meeting-audio activity — the payload of the
/// `meeting.activity` telemetry event and of `status`'s `meeting_activity`
/// snapshot. `active` flips when the app's confirmed (debounced) use of the
/// microphone starts or stops; `episode` is a daemon-boot-scoped id stable
/// for one continuous meeting, which clients key prompts and
/// `session.start` idempotency on.
public struct MeetingActivityStatus: Sendable, Hashable, Codable {
  public var source: SourceID
  public var bundleID: String
  public var label: String
  public var active: Bool
  public var episode: String

  public init(source: SourceID, bundleID: String, label: String, active: Bool, episode: String) {
    self.source = source
    self.bundleID = bundleID
    self.label = label
    self.active = active
    self.episode = episode
  }

  private enum CodingKeys: String, CodingKey {
    case source, label, active, episode
    case bundleID = "bundle_id"
  }
}
