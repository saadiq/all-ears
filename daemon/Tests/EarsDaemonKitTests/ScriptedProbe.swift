import EarsCaptureKit
import Foundation

/// A probe whose answer repeats its script's last entry once exhausted, so a
/// finished script holds steady instead of reading as "everything went quiet".
/// Shared by ``MeetingActivityMonitorTests`` and the real-socket
/// ``EarsDaemonTests`` case that drives a whole daemon end to end.
final class ScriptedProbe: AppAudioActivityProbing, @unchecked Sendable {
  private let lock = NSLock()
  private var script: [[String: Bool]]
  private var polled = 0
  init(_ script: [[String: Bool]]) { self.script = script }

  /// How many times the monitor has polled. A test driving a `ManualClock`
  /// has to know the first poll landed *before* it advances the clock:
  /// otherwise the tracker's pending sample is stamped with the already
  /// advanced time, every later poll measures a zero-length debounce against
  /// a frozen clock, and no edge is ever confirmed — a hang, not a failure.
  var polls: Int {
    lock.lock()
    defer { lock.unlock() }
    return polled
  }

  func inputActivity(bundleIDs: Set<String>) -> [String: Bool] {
    lock.lock()
    defer { lock.unlock() }
    polled += 1
    guard let first = script.first else { return [:] }
    if script.count > 1 { script.removeFirst() }
    return first
  }
}
