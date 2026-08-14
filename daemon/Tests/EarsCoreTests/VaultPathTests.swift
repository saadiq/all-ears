import Foundation
import Testing

@testable import EarsCore

@Suite("VaultPath")
struct VaultPathTests {
  /// Builds `<temp>/<label>/<vault>/...` with a `.obsidian` marker at
  /// `<vault>`, and returns the vault root.
  private static func makeVault(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("VaultPathTests-\(label)-\(UUID().uuidString)")
    let vault = root.appendingPathComponent("Everything")
    try FileManager.default.createDirectory(
      at: vault.appendingPathComponent(VaultPath.markerName), withIntermediateDirectories: true)
    return vault
  }

  private static func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "x".write(to: url, atomically: true, encoding: .utf8)
  }

  @Test("a file inside a vault resolves to its vault-relative path")
  func insideVault() throws {
    let vault = try Self.makeVault("inside")
    defer { try? FileManager.default.removeItem(at: vault.deletingLastPathComponent()) }
    let transcript = vault.appendingPathComponent(
      "Transcripts/2026/08/12/2026-08-12 - meet 96DC3F7J7x0B.md")
    try Self.touch(transcript)

    #expect(
      VaultPath.vaultRelative(transcript.path)
        == "Transcripts/2026/08/12/2026-08-12 - meet 96DC3F7J7x0B.md")
    #expect(
      VaultPath.linkTarget(transcript.path)
        == "Transcripts/2026/08/12/2026-08-12 - meet 96DC3F7J7x0B.md")
  }

  @Test("a file at the vault root resolves to its bare name")
  func atVaultRoot() throws {
    let vault = try Self.makeVault("root")
    defer { try? FileManager.default.removeItem(at: vault.deletingLastPathComponent()) }
    let note = vault.appendingPathComponent("Inbox.md")
    try Self.touch(note)

    #expect(VaultPath.vaultRelative(note.path) == "Inbox.md")
  }

  @Test("the nearest enclosing vault wins over an outer one")
  func nearestVaultWins() throws {
    let outer = try Self.makeVault("nested")
    defer { try? FileManager.default.removeItem(at: outer.deletingLastPathComponent()) }
    let inner = outer.appendingPathComponent("Projects/Inner")
    try FileManager.default.createDirectory(
      at: inner.appendingPathComponent(VaultPath.markerName), withIntermediateDirectories: true)
    let note = inner.appendingPathComponent("Notes/thing.md")
    try Self.touch(note)

    #expect(VaultPath.vaultRelative(note.path) == "Notes/thing.md")
  }

  @Test("a file in no vault has no vault-relative form, and links by absolute path")
  func outsideAnyVault() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VaultPathTests-outside-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("loose.md")
    try Self.touch(file)

    #expect(VaultPath.vaultRelative(file.path) == nil)
    // Deliberately still a path: a bare name would look like a working
    // wikilink while resolving to nothing (or to some unrelated note).
    #expect(VaultPath.linkTarget(file.path) == file.standardizedFileURL.path)
  }

  @Test("a plain file beside a .obsidian *file* is not treated as being in a vault")
  func markerMustBeADirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VaultPathTests-marker-file-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "not a vault".write(
      to: directory.appendingPathComponent(VaultPath.markerName), atomically: true, encoding: .utf8)
    let file = directory.appendingPathComponent("note.md")
    try Self.touch(file)

    #expect(VaultPath.vaultRelative(file.path) == nil)
  }
}
