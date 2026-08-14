import Foundation

/// Finds the note a user was already jotting into during a call, when the
/// path a `[[summarize.preset]]`'s `notes` template constructs isn't where
/// they actually put it.
///
/// A path template is a fine way to *write* a file and a poor way to *find*
/// one. `notes` is doing the second job: it is an exact-match lookup for a
/// file a human created and named, keyed on a string a machine generated on
/// the other side of the call. Anything that moves either side — a session
/// whose title never resolved past the platform's meeting id, a vault whose
/// filing convention grew a directory level, a note named "Matt Barras" for
/// an attendee the roster calls "Matthew Barras" — misses, and a miss is
/// silent: the fold-in prompt runs against an empty notes section and the
/// jottings are simply absent from the note that replaces them.
///
/// So the template stays the ideal, and this widens it to a search when the
/// ideal isn't there. Every signal it scores on is one a person would use to
/// recognise their own note:
///
/// - it is filed under the **right day**, whether that is in the filename or
///   in a directory component;
/// - its name mentions **someone who was on the call**, matched loosely
///   enough that "Matt" finds "Matthew";
/// - it was **edited while the call was happening**, which is close to
///   decisive on its own — few files are touched during any given meeting.
///
/// Nothing is scored on being *near* the constructed path beyond sharing its
/// directory subtree, and a candidate with no positive signal is not
/// returned. An unmatched note leaves the run exactly where it was before
/// this type existed; a *wrongly* matched one would overwrite a note about
/// something else, so silence is the only safe failure.
public enum NotesLocator {

  /// What the search concluded.
  public enum Resolution: Sendable, Hashable {
    /// The template's own path exists. No searching happened.
    case exact(String)
    /// A different file scored well enough to be this call's notes.
    /// ``reason`` explains why, for the warning that accompanies using it.
    case matched(String, reason: String)
    /// Nothing plausible. The caller proceeds with no notes, as before.
    case notFound
  }

  /// Everything the search matches against, all of it already known to
  /// `summarize` from the transcript's frontmatter.
  public struct Context: Sendable, Hashable {
    /// The path the `notes` template expanded to — the ideal, and the root of
    /// the subtree searched when it isn't there.
    public var expandedPath: String
    /// The session's day as `YYYY-MM-DD`, the filing key the vault is
    /// organised by.
    public var date: String
    /// Names to look for in a filename. The local participant is deliberately
    /// **not** among them: a note about a call is named after the other
    /// person, so matching on your own name would only ever fire on notes
    /// about something else.
    public var names: [String]
    /// The call itself. A note modified inside this window was almost
    /// certainly being written during it.
    public var start: Instant?
    public var end: Instant?

    public init(
      expandedPath: String, date: String, names: [String] = [], start: Instant? = nil,
      end: Instant? = nil
    ) {
      self.expandedPath = expandedPath
      self.date = date
      self.names = names
      self.start = start
      self.end = end
    }
  }

  /// One file the search is considering.
  public struct Candidate: Sendable, Hashable {
    public var path: String
    public var modified: Instant?

    public init(path: String, modified: Instant? = nil) {
      self.path = path
      self.modified = modified
    }
  }

  /// How far below the template path's own directory to look. One level
  /// covers the case that prompted this — a vault that files a day's notes in
  /// a `2026-08-12/` folder the template doesn't know about — without turning
  /// a per-week directory into a scan of the whole vault.
  public static let searchDepth = 2

  /// How long after a call ends a note can still be saved and count as having
  /// been written during it. Jottings are typically saved on the way out of
  /// the meeting, sometimes a few minutes after.
  public static let editGraceSeconds: Double = 15 * 60

  /// Weight of "this filename names someone who was on the call", per name
  /// token matched. Above ``editWeight`` because a name is *about* the call's
  /// subject, where an edit time is only circumstantial — a note touched
  /// mid-call may still be about something else entirely.
  public static let nameTokenWeight = 2
  /// Weight of "this file was edited during the call".
  public static let editWeight = 1

  /// Resolves `context`'s notes path against the filesystem.
  public static func locate(
    _ context: Context, fileManager: FileManager = .default
  ) -> Resolution {
    if fileManager.fileExists(atPath: context.expandedPath) {
      return .exact(context.expandedPath)
    }
    let root = URL(fileURLWithPath: context.expandedPath).deletingLastPathComponent()
    let candidates = markdownFiles(under: root, fileManager: fileManager)
    guard let best = best(among: candidates, context: context) else { return .notFound }
    return .matched(best.path, reason: reason(for: best, context: context))
  }

  /// The highest-scoring candidate, or `nil` when none carries a positive
  /// signal or two tie at the top.
  ///
  /// A tie is treated as no answer rather than broken arbitrarily: two
  /// equally plausible notes mean the evidence does not identify one, and
  /// picking either would overwrite a file on a coin toss.
  public static func best(among candidates: [Candidate], context: Context) -> Candidate? {
    let scored =
      candidates
      .map { (candidate: $0, score: score($0, context: context)) }
      .filter { $0.score > 0 }
      .sorted { $0.score > $1.score }
    guard let top = scored.first else { return nil }
    if scored.count > 1, scored[1].score == top.score { return nil }
    return top.candidate
  }

  /// `candidate`'s total score against `context`; `0` means "no reason to
  /// think this is the note".
  public static func score(_ candidate: Candidate, context: Context) -> Int {
    // Filed under the right day is a precondition, not a score: a note from
    // another day is not this call's notes however well it scores otherwise.
    guard candidate.path.contains(context.date) else { return 0 }
    return nameScore(candidate, context: context) + editScore(candidate, context: context)
  }

  private static func nameScore(_ candidate: Candidate, context: Context) -> Int {
    let fileTokens = tokens(in: stem(of: candidate.path))
    guard !fileTokens.isEmpty else { return 0 }
    var matched = 0
    for name in context.names {
      for nameToken in tokens(in: name)
      where fileTokens.contains(where: { tokensMatch($0, nameToken) }) {
        matched += 1
      }
    }
    return matched * nameTokenWeight
  }

  private static func editScore(_ candidate: Candidate, context: Context) -> Int {
    guard let modified = candidate.modified, let start = context.start else { return 0 }
    let end = (context.end ?? start).advanced(by: editGraceSeconds)
    return modified >= start && modified <= end ? editWeight : 0
  }

  /// Human-readable justification for a fuzzy match, so the warning that
  /// carries it says which signals fired rather than only that something did.
  private static func reason(for candidate: Candidate, context: Context) -> String {
    var signals: [String] = []
    if nameScore(candidate, context: context) > 0 { signals.append("names a participant") }
    if editScore(candidate, context: context) > 0 { signals.append("edited during the call") }
    if signals.isEmpty { signals.append("filed under \(context.date)") }
    return signals.joined(separator: ", ")
  }

  /// Two name tokens refer to the same person's name, allowing for the short
  /// forms people file notes under: exact ignoring case, or one a prefix of
  /// the other at three characters or more ("Matt" ↔ "Matthew").
  ///
  /// Three is the shortest prefix that is worth anything — at two, "Al"
  /// matches "Alan" and "Alexandra" alike, and initials would match nearly
  /// everyone.
  static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    let shorter = lhs.count <= rhs.count ? lhs : rhs
    let longer = lhs.count <= rhs.count ? rhs : lhs
    guard shorter.count >= 3 else { return false }
    return longer.hasPrefix(shorter)
  }

  /// Lowercased word tokens, splitting on everything that isn't a letter or
  /// digit, with the one-and-two-character noise dropped (`-`, `&`, `of`).
  static func tokens(in value: String) -> [String] {
    value.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { $0.count >= 3 }
  }

  /// A path's filename without its extension.
  private static func stem(of path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  /// Every `.md` file at or below `root`, to ``searchDepth``.
  ///
  /// Hidden directories are skipped: `.obsidian` and `.trash` hold a vault's
  /// own machinery and a user's deleted notes, and neither is ever the file
  /// being looked for.
  private static func markdownFiles(under root: URL, fileManager: FileManager) -> [Candidate] {
    var found: [Candidate] = []
    var frontier = [(url: root, depth: 0)]
    while let (directory, depth) = frontier.popLast() {
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
          options: [.skipsHiddenFiles])
      else { continue }
      for entry in entries {
        let values = try? entry.resourceValues(forKeys: [
          .isDirectoryKey, .contentModificationDateKey,
        ])
        if values?.isDirectory == true {
          if depth + 1 < searchDepth { frontier.append((entry, depth + 1)) }
          continue
        }
        guard entry.pathExtension.lowercased() == "md" else { continue }
        found.append(
          Candidate(
            path: entry.path,
            modified: values?.contentModificationDate.map {
              Instant(secondsSinceEpoch: $0.timeIntervalSince1970)
            }))
      }
    }
    return found
  }
}
