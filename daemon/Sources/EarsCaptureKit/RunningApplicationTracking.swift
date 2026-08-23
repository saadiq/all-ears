import AppKit

/// A running (or just-changed) process's bundle id and pid — the shape
/// ``SystemAudioCaptureBackend``'s per-app tap rebuild needs to follow an
/// app's processes as they come and go.
public enum RunningApplicationEvent: Sendable, Hashable {
  case launched(bundleID: String, pid: pid_t)
  case terminated(bundleID: String, pid: pid_t)
}

/// Resolves a bundle id to its live PID(s), and observes app launch/
/// terminate. A bundle id can have zero, one, or several live PIDs over a
/// source's lifetime (helper processes, multiple windows/instances) — this
/// seam is what lets both consumers re-resolve that set rather than
/// snapshotting it once.
public protocol RunningApplicationTracking: Sendable {
  /// Live PIDs for every currently-running process with this bundle id.
  func livePIDs(forBundleID bundleID: String) -> [pid_t]

  /// A stream of every subsequent launch/terminate event, system-wide.
  /// Callers filter to the bundle id(s) they care about.
  ///
  /// Known gap: the production stream is `NSWorkspace`'s, which posts only
  /// for LaunchServices-tracked applications. A pid set that ``livePIDs``
  /// resolved through the HAL — a media daemon — is therefore resolved once
  /// at backend build and never re-resolved: it stays empty if the daemon had
  /// not yet touched audio, and stale if the daemon relaunches. Closing it
  /// means sourcing events from a listener on the HAL's process-object list.
  func events() -> AsyncStream<RunningApplicationEvent>
}

/// The production ``RunningApplicationTracking``: `NSWorkspace.shared`, with
/// the HAL's process objects as the pid fallback. The workspace lists only
/// launched *applications*; a media daemon that carries a bundle id —
/// FaceTime's `com.apple.avconferenced`, which owns the call's audio while
/// FaceTime.app only draws it — is invisible there, yet the HAL knows it the
/// moment it touches audio, and a tap built on that pid scopes to it like any
/// app. The fallback is taken only when the workspace has nothing, so an
/// app's pid set is never mixed with a stale HAL entry.
public struct RealRunningApplicationTracker: RunningApplicationTracking {
  public init() {}

  public func livePIDs(forBundleID bundleID: String) -> [pid_t] {
    let applications = NSWorkspace.shared.runningApplications
      .filter { $0.bundleIdentifier == bundleID }
      .map(\.processIdentifier)
    guard applications.isEmpty else { return applications }
    return HALObjects.processObjects()
      .filter { HALObjects.bundleID(of: $0) == bundleID }
      .compactMap(HALObjects.pid(of:))
  }

  public func events() -> AsyncStream<RunningApplicationEvent> {
    AsyncStream { continuation in
      let center = NSWorkspace.shared.notificationCenter
      let launchToken = center.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
      ) { notification in
        guard
          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          let bundleID = app.bundleIdentifier
        else { return }
        continuation.yield(.launched(bundleID: bundleID, pid: app.processIdentifier))
      }
      let terminateToken = center.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
      ) { notification in
        guard
          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          let bundleID = app.bundleIdentifier
        else { return }
        continuation.yield(.terminated(bundleID: bundleID, pid: app.processIdentifier))
      }
      // NSObjectProtocol observer tokens aren't Sendable, but they're
      // immutable handles only ever passed back to `removeObserver` --
      // never read or mutated concurrently -- so capturing them into this
      // one-shot termination closure is safe despite the compiler's
      // conservative check.
      nonisolated(unsafe) let tokens = (launchToken, terminateToken)
      continuation.onTermination = { _ in
        center.removeObserver(tokens.0)
        center.removeObserver(tokens.1)
      }
    }
  }
}
