import Foundation

/// Resolves a file's position inside an Obsidian vault, so a link written into
/// one document can address another the way the vault itself does.
///
/// Obsidian wikilinks are **vault-rooted**, not filesystem-rooted:
/// `[[Transcripts/2026/08/12/2026-08-12 - meet 96DC3F7J7x0B.md]]` resolves,
/// `[[/Users/tom/obsidian/Everything/Transcripts/…]]` does not. Nothing else in
/// the pipeline needs to know it is writing into a vault — `cleanup` and
/// `summarize` deal in absolute paths throughout, and their path templates are
/// configured with absolute roots — so the vault is *detected* rather than
/// configured: a directory is a vault root if it contains `.obsidian`, and the
/// root is the nearest such ancestor.
///
/// Detection rather than a `[vault] root` config key because the fact is
/// already on disk, an out-of-date config key would produce links that resolve
/// to nothing, and a path outside any vault has a correct answer here (`nil`)
/// rather than a misconfiguration.
public enum VaultPath {
  /// The marker directory Obsidian creates at a vault's root.
  static let markerName = ".obsidian"

  /// `path` expressed relative to its enclosing vault's root, or `nil` when no
  /// ancestor is a vault root.
  ///
  /// The nearest ancestor wins, which is what a vault nested inside another
  /// vault's folder should do: the link is written for whichever vault the
  /// file actually lives in.
  public static func vaultRelative(
    _ path: String, fileManager: FileManager = .default
  ) -> String? {
    let fileURL = URL(fileURLWithPath: path).standardizedFileURL
    var directory = fileURL.deletingLastPathComponent()
    var components: [String] = [fileURL.lastPathComponent]

    // Walk up to `/`, where `deletingLastPathComponent()` is a fixed point.
    while true {
      if isVaultRoot(directory, fileManager: fileManager) {
        return components.joined(separator: "/")
      }
      let parent = directory.deletingLastPathComponent().standardizedFileURL
      guard parent.path != directory.path else { return nil }
      components.insert(directory.lastPathComponent, at: 0)
      directory = parent
    }
  }

  /// `path` as an Obsidian wikilink target: vault-relative where that is
  /// meaningful, and the absolute path otherwise.
  ///
  /// The fallback is deliberately still a path and not a bare filename. A file
  /// outside any vault has no wikilink that resolves, and a link naming the
  /// real location at least says where the thing is; a bare name would look
  /// like a working link and silently resolve to nothing — or, worse, to some
  /// other note that happens to share the name.
  public static func linkTarget(_ path: String, fileManager: FileManager = .default) -> String {
    vaultRelative(path, fileManager: fileManager)
      ?? URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func isVaultRoot(_ directory: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    let marker = directory.appendingPathComponent(markerName).path
    guard fileManager.fileExists(atPath: marker, isDirectory: &isDirectory) else { return false }
    return isDirectory.boolValue
  }
}
