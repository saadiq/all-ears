import Foundation

/// Tolerant single-key extraction from a Markdown file's YAML frontmatter.
///
/// ``TranscriptParser`` is deliberately strict about the flow-style YAML this
/// suite writes — but a *published* artifact lives in the user's vault, where
/// other tooling (Obsidian and its linters) may rewrite the frontmatter into
/// block style the parser refuses. `ears session show` still needs the one
/// fact stamped in there (`note:`), so this probe scans top-level
/// `key: value` lines without judging the rest of the block. Read-only
/// consumers only; writers keep the strict parser's round-trip guarantees.
public enum FrontmatterProbe {
  /// The value of top-level `key:` in `markdown`'s frontmatter block, quotes
  /// stripped — or `nil` when the block, the key, or a scalar value is
  /// absent (a key opening a nested block yields `nil`, not its children).
  public static func value(of key: String, in markdown: String) -> String? {
    guard markdown.hasPrefix("---\n") else { return nil }
    let afterOpenFence = markdown.dropFirst(4)
    guard let closeFenceRange = afterOpenFence.range(of: "\n---\n") else { return nil }
    for line in afterOpenFence[..<closeFenceRange.lowerBound].split(separator: "\n") {
      // Indented lines are nested content; top-level keys start at column 0.
      guard let first = line.first, first != " ", first != "\t" else { continue }
      guard let colon = line.firstIndex(of: ":"), String(line[..<colon]) == key else { continue }
      let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !raw.isEmpty else { return nil }
      return unquote(raw)
    }
    return nil
  }

  private static func unquote(_ value: String) -> String {
    for quote: Character in ["\"", "'"]
    where value.count >= 2 && value.first == quote && value.last == quote {
      return String(value.dropFirst().dropLast())
    }
    return value
  }
}
