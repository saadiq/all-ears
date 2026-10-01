/// The summaries `summarize` writes beside a published transcript:
/// `<stem>.summary.md` from a lone preset, `<stem>.<preset>.summary.md`
/// from several. A different session whose stem merely starts with this
/// one (`standup-2`) is not a match. Sorted, so callers pick the same file
/// every time.
public enum SummarySiblings {
  public static func select(filenames: [String], stem: String) -> [String] {
    let suffix = ".summary.md"
    return filenames.filter { name in
      guard !name.contains("/"), name.count >= stem.count + suffix.count,
        name.hasSuffix(suffix), name.hasPrefix(stem)
      else { return false }
      let middle = name.dropFirst(stem.count).dropLast(suffix.count)
      return middle.isEmpty || (middle.hasPrefix(".") && !middle.dropFirst().contains("."))
    }
    .sorted()
  }
}
