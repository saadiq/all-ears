import Testing

@testable import EarsConfig

@Suite("Default socket path")
struct DefaultSocketPathTests {
  @Test("derives <data_root>/runtime/earsd.sock")
  func derivesUnderDataRoot() {
    #expect(
      DefaultSocketPath.resolve(dataRoot: "/Users/tom/Library/Application Support/ears")
        == "/Users/tom/Library/Application Support/ears/runtime/earsd.sock")
  }

  @Test("a trailing slash on data_root doesn't produce a doubled slash")
  func trailingSlashNormalized() {
    #expect(
      DefaultSocketPath.resolve(dataRoot: "/custom/data/")
        == "/custom/data/runtime/earsd.sock")
  }

  @Test("a path within the sun_path cap has no length error")
  func shortPathHasNoLengthError() {
    #expect(DefaultSocketPath.lengthError(forPath: "/tmp/earsd.sock") == nil)
  }

  @Test("a path exactly at the sun_path cap has no length error")
  func exactCapHasNoLengthError() {
    let path = "/tmp/" + String(repeating: "x", count: DefaultSocketPath.maxPathBytes - 5)
    #expect(path.utf8.count == DefaultSocketPath.maxPathBytes)
    #expect(DefaultSocketPath.lengthError(forPath: path) == nil)
  }

  @Test("one byte over the cap yields a message naming path, length, cap, and the fix")
  func overCapYieldsDescriptiveMessage() throws {
    let path = "/tmp/" + String(repeating: "x", count: DefaultSocketPath.maxPathBytes - 4)
    #expect(path.utf8.count == DefaultSocketPath.maxPathBytes + 1)
    let message = try #require(DefaultSocketPath.lengthError(forPath: path))
    #expect(message.contains("socket path too long for sun_path"))
    #expect(message.contains("(\(path.utf8.count) bytes, max \(DefaultSocketPath.maxPathBytes))"))
    #expect(message.contains(path))
    #expect(message.contains("set socket_path to a shorter path or move data_root"))
  }

  @Test("the cap is measured in UTF-8 bytes, not characters")
  func capCountsUTF8Bytes() {
    // 35 four-byte scalars + "/tmp/" = 145 bytes from 40 characters.
    let path = "/tmp/" + String(repeating: "🎤", count: 35)
    #expect(path.utf8.count > DefaultSocketPath.maxPathBytes)
    #expect(DefaultSocketPath.lengthError(forPath: path) != nil)
  }
}
