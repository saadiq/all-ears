import CoreAudio
import Foundation

/// Answers "is any live process with this bundle id currently running audio
/// *input* (using the microphone)?" — the meeting-detection signal. A seam
/// so the monitor is testable with a scripted fake; the Core Audio
/// conformance below is the only real one.
public protocol AppAudioActivityProbing: Sendable {
  func inputActivity(bundleIDs: Set<String>) -> [String: Bool]
}

/// The production probe: enumerates the HAL's process objects
/// (`kAudioHardwarePropertyProcessObjectList`), reads each one's bundle id
/// (`kAudioProcessPropertyBundleID`) and input-running flag
/// (`kAudioProcessPropertyIsRunningInput`), and ORs the flags per watched
/// bundle id. Read-only global HAL properties — no tap is created and no TCC
/// grant is required.
public struct CoreAudioAppActivityProbe: AppAudioActivityProbing {
  public init() {}

  public func inputActivity(bundleIDs: Set<String>) -> [String: Bool] {
    var result: [String: Bool] = [:]
    for id in bundleIDs { result[id] = false }
    for object in processObjectList() {
      guard let bundle = stringProperty(object, kAudioProcessPropertyBundleID),
        bundleIDs.contains(bundle)
      else { continue }
      if uint32Property(object, kAudioProcessPropertyIsRunningInput) == 1 {
        result[bundle] = true
      }
    }
    return result
  }

  private func processObjectList() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
      dataSize > 0
    else { return [] }
    var objects = [AudioObjectID](
      repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objects)
    guard status == noErr else { return [] }
    // Truncate to what the second call actually wrote: a process that exited
    // between the size query and the fetch shrinks the list, leaving the tail
    // of the buffer at its `0` fill — `kAudioObjectUnknown`, which the loop
    // above would then probe once per poll for properties it can never have.
    return Array(objects.prefix(Int(dataSize) / MemoryLayout<AudioObjectID>.size))
  }

  private func stringProperty(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  private func uint32Property(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
    return status == noErr ? value : 0
  }
}
