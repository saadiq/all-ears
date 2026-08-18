import EarsCore
import EarsDataStore
import Foundation

/// The publishing config the menu needs to find what the on-end chain wrote:
/// `[cleanup] output`, each `[[summarize.preset]]`, and the two keys their
/// templates expand against.
///
/// Read from the same resolved config layers `earsd` and the stages read, in
/// the idiom ``ManualSessionSources``/``ManualSessionStages`` already use —
/// the menu cannot ask the daemon where a stage wrote, because `job.publish`
/// carries a state and a detail string, not paths.
public struct PublishingSettings: Sendable, Hashable {
  /// One configured summary preset. `out` is its own path template when it
  /// names one; `nil` means it takes the default sibling naming off the
  /// cleaned transcript (see
  /// ``SessionArtifactLocator/published(frontmatter:transcriptPath:settings:)``).
  public struct Preset: Sendable, Hashable {
    public var name: String
    public var out: String?

    public init(name: String, out: String? = nil) {
      self.name = name
      self.out = out
    }
  }

  public var outputRoot: String
  public var cleanupOutput: String
  public var weekNumbering: WeekNumbering
  public var presets: [Preset]

  public init(
    outputRoot: String, cleanupOutput: String, weekNumbering: WeekNumbering, presets: [Preset]
  ) {
    self.outputRoot = outputRoot
    self.cleanupOutput = cleanupOutput
    self.weekNumbering = weekNumbering
    self.presets = presets
  }

  public static func resolve(from config: ConfigValue) -> PublishingSettings {
    guard case .table(let root) = config else {
      return PublishingSettings(
        outputRoot: "", cleanupOutput: LLMStagesConfigSchema.defaultCleanupOutput,
        weekNumbering: .us, presets: [])
    }
    // An absent `[cleanup] output` falls back to the constant cleanup itself
    // falls back to, rather than a second copy of the template string.
    var cleanupOutput = LLMStagesConfigSchema.defaultCleanupOutput
    if case .table(let cleanup)? = root["cleanup"],
      case .string(let configured)? = cleanup["output"], !configured.isEmpty
    {
      cleanupOutput = configured
    }
    return PublishingSettings(
      outputRoot: string(root["output_root"]),
      cleanupOutput: cleanupOutput,
      weekNumbering: WeekNumbering(configValue: string(root["week_numbering"])),
      presets: presets(in: root))
  }

  private static func presets(in root: [String: ConfigValue]) -> [Preset] {
    guard case .table(let summarize)? = root["summarize"],
      case .array(let entries)? = summarize["preset"]
    else { return [] }
    return entries.compactMap { entry in
      guard case .table(let table) = entry else { return nil }
      let name = string(table["name"])
      guard !name.isEmpty else { return nil }
      let out = string(table["out"])
      return Preset(name: name, out: out.isEmpty ? nil : out)
    }
  }

  private static func string(_ value: ConfigValue?) -> String {
    guard case .string(let text)? = value else { return "" }
    return text
  }
}

/// Where the on-end chain's published artifacts land for one session, as
/// path templates alone can say — no filesystem access, so the shape is
/// unit-tested without a store on disk. Which of these exist is the caller's
/// question (see `RecentSessionsProvider`).
public struct PublishedArtifactPaths: Sendable, Hashable {
  /// `[cleanup] output` expanded: the readable transcript you file.
  public var clean: URL
  /// The directory `clean` lives in — where `summarize`'s default naming
  /// puts its output too.
  public var summaryDirectory: URL
  /// The filename stem those siblings share.
  public var summaryStem: String
  /// Presets that named their own `out`, already expanded. They can point
  /// anywhere (an Obsidian vault, say), so they are listed rather than swept.
  public var explicitSummaries: [URL]

  public init(
    clean: URL, summaryDirectory: URL, summaryStem: String, explicitSummaries: [URL]
  ) {
    self.clean = clean
    self.summaryDirectory = summaryDirectory
    self.summaryStem = summaryStem
    self.explicitSummaries = explicitSummaries
  }
}

/// Resolves a session's artifacts across the two tiers `docs/configuration.md`
/// describes: the raw transcript is an **intermediate**, addressed by session
/// id inside the data store, and the cleaned transcript and summaries are
/// **published**, landing wherever their path templates resolve to.
///
/// Nothing here reimplements a layout. Dates, tokens and title sanitisation
/// come from ``PathTemplate`` — the same type `cleanup` and `summarize`
/// expand — and the data-store path from ``DataStoreLayout``. An earlier
/// version of this file mirrored `transcribe`'s output paths by hand and
/// silently found nothing once that layout changed; sharing the expander is
/// what stops that recurring.
public enum SessionArtifactLocator {
  /// `<data-root>/sessions/<id>/transcript.md`.
  public static func rawTranscript(dataRoot: String, sessionID: String) -> URL {
    DataStoreLayout.sessionTranscriptFile(
      dataRoot: URL(fileURLWithPath: dataRoot), sessionID: sessionID)
  }

  /// Where the on-end chain published this transcript, resolved the way
  /// `cleanup` itself resolved it: through ``CleanupPublishedPath``'s context,
  /// built from the document's own frontmatter rather than from the session
  /// record. The stage expanded that context, so reading it back is the only
  /// derivation that cannot disagree with the writer — a session renamed after
  /// its chain ran still points at the file on disk.
  public static func published(
    frontmatter: TranscriptFrontmatter, transcriptPath: String, settings: PublishingSettings
  ) -> PublishedArtifactPaths {
    let context = CleanupPublishedPath.context(
      outputRoot: settings.outputRoot,
      weekNumbering: settings.weekNumbering,
      frontmatter: frontmatter,
      transcriptPath: transcriptPath)
    let clean = URL(fileURLWithPath: PathTemplate(settings.cleanupOutput).expand(context))
    return PublishedArtifactPaths(
      clean: clean,
      summaryDirectory: clean.deletingLastPathComponent(),
      summaryStem: CleanupPublishedPath.documentStem(clean),
      explicitSummaries: settings.presets.compactMap { preset in
        preset.out.map { URL(fileURLWithPath: PathTemplate($0).expand(context)) }
      })
  }

  /// The summaries sitting beside a published transcript: `<stem>.summary.md`
  /// from a lone preset, `<stem>.<preset>.summary.md` from several.
  ///
  /// Swept rather than predicted from the preset list, so a summary written
  /// under a preset that has since been renamed or removed from the config
  /// still opens from the menu. Sorted, so the menu's "Open Summary" picks
  /// the same file every time.
  public static func siblingSummaries(filenames: [String], stem: String) -> [String] {
    filenames.filter { name in
      guard !name.contains("/"), name.hasSuffix(".summary.md"), name.hasPrefix(stem) else {
        return false
      }
      // What sits between the stem and the suffix is either nothing (the lone
      // preset's form) or `.<preset>` — never a longer stem that merely
      // shares this one's prefix.
      let middle = name.dropFirst(stem.count).dropLast(".summary.md".count)
      return middle.isEmpty || (middle.hasPrefix(".") && !middle.dropFirst().contains("."))
    }
    .sorted()
  }
}

public enum RecentSessions {
  /// The menu's Recent Sessions list: ended sessions, most recently *ended*
  /// first — the order `ears status`'s recent tail uses, so the two surfaces
  /// agree about what "recent" means. Ordering by start instead would bury a
  /// long call under the short one it overran. A record with no end instant
  /// sorts on its start, the only instant it carries.
  public static func select(from sessions: [Session], limit: Int = 7) -> [Session] {
    Array(
      sessions.filter { $0.state == .ended }
        .sorted { ($0.ended ?? $0.started) > ($1.ended ?? $1.started) }
        .prefix(limit))
  }
}
