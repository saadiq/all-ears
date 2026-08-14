import Foundation

/// Preserves a note before a `[[summarize.preset]]` with `out = "{notes}"`
/// writes over it.
///
/// The fold-in pattern reads a user's hand-typed jottings and replaces them
/// with a summary that incorporates them. When it works that is the whole
/// point. When it doesn't — a prompt that needs another pass, a transcript
/// whose speakers were mislabelled, a notes file matched to the wrong call —
/// the input is gone, and hand-typed notes exist nowhere else. There is no
/// undo for a file the user never saw being written.
///
/// So every overwrite leaves a copy behind first. This is cheap (notes are
/// kilobytes), out of the vault (a backup inside it would sync, index, and
/// show up in search results as a duplicate note), and never destructive in
/// its own right: an existing backup is never replaced, only sat beside, so
/// the *original* jottings survive however many times a preset is re-run
/// against them while a prompt is iterated on.
public enum NoteBackup {
  /// Where backups live: durable across reboots, outside the vault, and
  /// outside `/private/tmp`, which is reaped on a schedule that has nothing
  /// to do with when someone realises they want their notes back.
  public static let defaultDirectory = "~/.local/state/ears-note-backups"

  /// Copies `path` into the backup directory, if it exists.
  ///
  /// - Returns: the backup's path, or `nil` when there was nothing to back up
  ///   (no file at `path`). Throws only when a file exists and could not be
  ///   copied — which the caller treats as a reason not to overwrite.
  @discardableResult
  public static func preserve(
    _ path: String, directory: String = defaultDirectory, fileManager: FileManager = .default
  ) throws -> String? {
    guard fileManager.fileExists(atPath: path) else { return nil }
    let root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let source = URL(fileURLWithPath: path)
    let stem = source.deletingPathExtension().lastPathComponent
    let destination = availableName(stem: stem, in: root, fileManager: fileManager)
    try fileManager.copyItem(at: source, to: destination)
    return destination.path
  }

  /// `<stem>.handnotes.md`, or `<stem>.handnotes-2.md`, `-3`, … when earlier
  /// backups are already there.
  ///
  /// Numbering upward rather than overwriting keeps the *first* backup — the
  /// one holding the original hand-typed jottings, before any generated text
  /// replaced them — which is the copy that matters. A later re-run backs up
  /// the generated note it is about to replace, and that is worth keeping
  /// too, but never at the first one's expense.
  private static func availableName(stem: String, in root: URL, fileManager: FileManager) -> URL {
    let first = root.appendingPathComponent("\(stem).handnotes.md")
    guard fileManager.fileExists(atPath: first.path) else { return first }
    // Bounded so a pathological loop cannot spin: past a hundred backups of
    // one note, reusing the last name is a better failure than not returning.
    for suffix in 2...100 {
      let candidate = root.appendingPathComponent("\(stem).handnotes-\(suffix).md")
      if !fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    return root.appendingPathComponent("\(stem).handnotes-100.md")
  }
}
