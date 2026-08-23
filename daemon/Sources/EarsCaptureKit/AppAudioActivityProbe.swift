import CoreAudio
import Foundation

/// Answers "is any live process with this bundle id currently running audio
/// *input* (using the microphone)?" — the meeting-detection signal. A seam
/// so the monitor is testable with a scripted fake; the Core Audio
/// conformance below is the only real one.
public protocol AppAudioActivityProbing: Sendable {
  func inputActivity(bundleIDs: Set<String>) -> [String: Bool]
}

/// The production probe over ``HALObjects``: ORs each process object's
/// input-running flag per watched bundle id.
public struct CoreAudioAppActivityProbe: AppAudioActivityProbing {
  public init() {}

  public func inputActivity(bundleIDs: Set<String>) -> [String: Bool] {
    var result: [String: Bool] = [:]
    for id in bundleIDs { result[id] = false }
    for object in HALObjects.processObjects() {
      // The input-running flag first: it is a bare `UInt32` read, where the
      // bundle id allocates and hands back a CFString. This loop runs over
      // *every* process the HAL knows, once a second, for the life of the
      // daemon — and all but the handful actually recording answer `0` here,
      // so testing it first skips the string for nearly all of them.
      guard HALObjects.isRunningInput(object),
        let bundle = HALObjects.bundleID(of: object),
        bundleIDs.contains(bundle)
      else { continue }
      result[bundle] = true
    }
    return result
  }
}
