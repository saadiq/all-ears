import EarsCaptureKit
import Foundation

/// A probe whose answer repeats its script's last entry once exhausted, so a
/// finished script holds steady instead of reading as "everything went quiet".
/// Shared by ``MeetingActivityMonitorTests`` and the real-socket
/// ``EarsDaemonTests`` case that drives a whole daemon end to end.
final class ScriptedProbe: AppAudioActivityProbing, @unchecked Sendable {
  private let lock = NSLock()
  private var script: [[String: Bool]]
  init(_ script: [[String: Bool]]) { self.script = script }
  func inputActivity(bundleIDs: Set<String>) -> [String: Bool] {
    lock.lock()
    defer { lock.unlock() }
    guard let first = script.first else { return [:] }
    if script.count > 1 { script.removeFirst() }
    return first
  }
}
