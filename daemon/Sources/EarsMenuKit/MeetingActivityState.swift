import EarsCore

/// The daemon's detected-meeting activity, as this client last heard it: one
/// entry per watched `app:*` source, upserted from `meeting.activity`
/// telemetry and refilled from `status` after every (re)connect.
///
/// Kept beside ``MenuState`` rather than inside it, so detection — a fork
/// feature — never touches the stack's menu types.
public struct MeetingActivityState: Sendable, Hashable {
  public var activity: [MeetingActivityStatus] = []
  /// Bumped on every live edge and on every (re)connect. A `status` catch-up
  /// captures it before asking and applies only if it is unchanged — see
  /// ``MeetingActivityReducer/catchUp(_:_:ifEditsEqual:)``.
  public var edits = 0

  public init() {}

  public var active: [MeetingActivityStatus] { activity.filter(\.active) }
}

public enum MeetingActivityReducer {
  /// A fresh subscription: activity is telemetry, not part of the snapshot,
  /// so whatever was held belongs to a socket that is gone. The `status`
  /// catch-up refills it.
  public static func connected(_ state: inout MeetingActivityState) {
    state.activity = []
    state.edits += 1
  }

  /// Upserts a `meeting.activity` frame by source. Telemetry carries no rev,
  /// so it never participates in gap detection. Returns whether the frame
  /// was meeting activity at all.
  @discardableResult
  public static func apply(_ state: inout MeetingActivityState, _ frame: EventFrame) -> Bool {
    guard case .meetingActivity(let status) = frame.event else { return false }
    if let index = state.activity.firstIndex(where: { $0.source == status.source }) {
      state.activity[index] = status
    } else {
      state.activity.append(status)
    }
    state.edits += 1
    return true
  }

  /// Replaces activity with a `status` answer, unless anything edited it
  /// since `mark` was taken. A live edge that lands while `status` is in
  /// flight is newer than the answer, and a reconnect makes the answer
  /// another socket's — either way the answer is stale and is dropped.
  public static func catchUp(
    _ state: inout MeetingActivityState, _ list: [MeetingActivityStatus], ifEditsEqual mark: Int
  ) {
    guard state.edits == mark else { return }
    state.activity = list
  }
}
