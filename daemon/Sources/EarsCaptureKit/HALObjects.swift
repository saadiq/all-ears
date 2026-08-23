import CoreAudio
import Foundation

/// Read-only global-scope property reads on HAL objects, and the two system
/// lists built from them: audio devices, and process objects — every process
/// Core Audio knows, each carrying its bundle id and input-running flag.
/// Shared by the mic device picker and the meeting-detection probe; neither
/// creates a tap, so no TCC grant is involved.
enum HALObjects {
  /// `kAudioHardwarePropertyProcessObjectList`.
  static func processObjects() -> [AudioObjectID] {
    systemObjectIDs(kAudioHardwarePropertyProcessObjectList)
  }

  /// An `[AudioObjectID]` property of the system object, sized by query.
  static func systemObjectIDs(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var address = address(selector)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
      dataSize > 0
    else { return [] }
    var objects = [AudioObjectID](
      repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &objects) == noErr
    else { return [] }
    // Truncate to what the second call actually wrote: an object that went
    // away between the size query and the fetch shrinks the list, leaving the
    // tail of the buffer at its `0` fill — `kAudioObjectUnknown`, which callers
    // would then probe for properties it can never have.
    return Array(objects.prefix(Int(dataSize) / MemoryLayout<AudioObjectID>.size))
  }

  static func bundleID(of object: AudioObjectID) -> String? {
    stringProperty(object, kAudioProcessPropertyBundleID)
  }

  static func isRunningInput(_ object: AudioObjectID) -> Bool {
    scalar(object, kAudioProcessPropertyIsRunningInput, zero: UInt32(0)) == 1
  }

  static func stringProperty(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> String? {
    var address = address(selector)
    var value: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  /// A fixed-size scalar property; `nil` when the object lacks it.
  private static func scalar<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, zero: T
  ) -> T? {
    var address = address(selector)
    var value = zero
    var dataSize = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
    return status == noErr ? value : nil
  }

  private static func address(_ selector: AudioObjectPropertySelector)
    -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }
}
