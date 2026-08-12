/// A configured output path with `{token}` placeholders — the single shared
/// mechanism behind `[cleanup] output` and `[[summarize.preset]]`'s
/// `notes`/`out`, per `docs/configuration.md`'s "Path templates".
///
/// Pure token expansion: no filesystem access, no clock read, no directory
/// creation. The tool that writes the file expands the template and creates
/// the parent directories, so path *shape* is unit-tested without touching
/// disk — the same split ``DataStoreLayout`` makes.
///
/// **Date tokens come from the session start, not the wall clock.** A call
/// that ends after midnight files under the day it started, and a rerun a
/// week later reproduces the same path. That context travels in the
/// transcript frontmatter (`title:`/`started:`), so a manual rerun and a
/// daemon-spawned run resolve identically.
///
/// **Missing context degrades, never fails.** `{title}` with no title falls
/// back to `{slug}`, and `{slug}` with no slug to the input file's basename,
/// so every template still yields a usable path. An *unknown* token is the
/// one hard error, and it is caught at config-validation time
/// (``unknownTokens(in:allowing:)``) rather than at write time — see
/// ``ConfigSchema/Field/pathTemplateTokens``.
public struct PathTemplate: Sendable, Hashable {
  /// The template as configured, `{token}`s intact.
  public let raw: String

  public init(_ raw: String) {
    self.raw = raw
  }

  /// Everything a template needs to expand. Assembled by the writing tool
  /// from its input document's frontmatter plus config.
  public struct Context: Sendable, Hashable {
    /// The configured `output_root`, already `~`-expanded.
    public var outputRoot: String
    /// The session (or range) start — the source of every date/time token.
    public var start: Instant
    public var weekNumbering: WeekNumbering
    /// The session UUID, when this artifact belongs to one.
    public var session: String?
    /// The path-safe source list (`mic_app_us.zoom.xos`) or session slug.
    public var slug: String?
    /// The session's display title, unsanitised.
    public var title: String?
    /// Last-resort stand-in for `{title}`/`{slug}`/`{session}`: the input
    /// file's basename, so a `--file` run with no session context still
    /// produces a distinguishable path.
    public var fallbackName: String
    /// The already-expanded companion notes path — only meaningful in a
    /// preset's `out` template (see ``presetOutTokens``).
    public var notes: String?

    public init(
      outputRoot: String,
      start: Instant,
      weekNumbering: WeekNumbering = .us,
      session: String? = nil,
      slug: String? = nil,
      title: String? = nil,
      fallbackName: String,
      notes: String? = nil
    ) {
      self.outputRoot = outputRoot
      self.start = start
      self.weekNumbering = weekNumbering
      self.session = session
      self.slug = slug
      self.title = title
      self.fallbackName = fallbackName
      self.notes = notes
    }
  }

  /// The tokens every configured template may use.
  public static let publishedTokens: Set<String> = [
    "output_root", "year", "month", "day", "date", "time", "week", "session", "slug", "title",
  ]

  /// ``publishedTokens`` plus `{notes}`, which only a `[[summarize.preset]]`
  /// `out` template may reference (it names that preset's own notes file, so
  /// there is nothing for it to mean anywhere else).
  public static let presetOutTokens: Set<String> = publishedTokens.union(["notes"])

  /// Every `{token}` in `raw` that isn't in `allowed`, in source order and
  /// without duplicates — the config-validation surface. A template with no
  /// unknown tokens expands predictably; one with an unknown token is a
  /// config error, not a silently literal `{titel}` in a filename.
  public static func unknownTokens(in raw: String, allowing allowed: Set<String>) -> [String] {
    var unknown: [String] = []
    var seen: Set<String> = []
    for token in tokens(in: raw) where !allowed.contains(token) && seen.insert(token).inserted {
      unknown.append(token)
    }
    return unknown
  }

  /// Expands every recognised token against `context`. Unrecognised tokens
  /// and unterminated braces are left verbatim: expansion is total, and
  /// rejecting a bad template is validation's job, not this function's.
  public func expand(_ context: Context) -> String {
    let civil = UTCCalendar.civilTime(for: context.start)
    var result = ""
    result.reserveCapacity(raw.count)

    var index = raw.startIndex
    while index < raw.endIndex {
      let character = raw[index]
      guard character == "{",
        let close = raw[index...].firstIndex(of: "}")
      else {
        result.append(character)
        index = raw.index(after: index)
        continue
      }
      let name = String(raw[raw.index(after: index)..<close])
      guard let value = substitution(for: name, civil: civil, context: context) else {
        result.append(character)
        index = raw.index(after: index)
        continue
      }
      result.append(value)
      index = raw.index(after: close)
    }
    return result
  }

  /// The replacement for one token name, or `nil` when the name isn't a
  /// token this type knows (the caller then emits the `{` literally).
  private func substitution(
    for name: String, civil: UTCCalendar.CivilTime, context: Context
  ) -> String? {
    switch name {
    case "output_root": return context.outputRoot
    case "year": return pad(civil.year, 4)
    case "month": return pad(civil.month, 2)
    case "day": return pad(civil.day, 2)
    case "date": return "\(pad(civil.year, 4))-\(pad(civil.month, 2))-\(pad(civil.day, 2))"
    case "time": return "\(pad(civil.hour, 2))-\(pad(civil.minute, 2))-\(pad(civil.second, 2))"
    case "week": return pad(context.weekNumbering.week(of: context.start), 2)
    // The three name-ish tokens share one degradation chain, so a template
    // written for sessions still yields a usable path for an ad-hoc run.
    case "session": return context.session ?? slugOrFallback(context)
    case "slug": return slugOrFallback(context)
    case "title": return Self.sanitizedTitle(context.title) ?? slugOrFallback(context)
    // An `out` template referencing `{notes}` on a preset with no `notes`
    // key is a config mistake validation can't see (the key is simply
    // absent); contributing nothing keeps expansion total.
    case "notes": return context.notes ?? ""
    default: return nil
    }
  }

  private func slugOrFallback(_ context: Context) -> String {
    let slug = context.slug ?? ""
    return slug.isEmpty ? context.fallbackName : slug
  }

  /// A session title reduced to one safe path component, following
  /// ``SourceID/pathSafe``'s idiom (unsafe → `_`) but scoped to a *display*
  /// title rather than an id: spaces and non-ASCII letters survive, only
  /// path separators, the characters filesystems and shells choke on, and
  /// control characters are replaced.
  ///
  /// Leading `.`/`_`/whitespace and trailing whitespace/`.` are trimmed, so a
  /// title can't produce a hidden file, a `..` traversal, or a
  /// trailing-dot name. Returns `nil` when nothing survives — the caller
  /// treats that exactly like an absent title.
  static func sanitizedTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let hostile: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    let replaced = String(
      title.map { character in
        if hostile.contains(character) { return "_" as Character }
        // Control characters (newlines and friends) never belong in a path
        // component; ASCII DEL included.
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
          scalar.value < 0x20 || scalar.value == 0x7F
        {
          return "_" as Character
        }
        return character
      })
    let trimmed = trim(replaced)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func trim(_ value: String) -> String {
    var slice = Substring(value)
    while let first = slice.first, first == "." || first == "_" || first == " " || first == "\t" {
      slice = slice.dropFirst()
    }
    while let last = slice.last, last == "." || last == " " || last == "\t" {
      slice = slice.dropLast()
    }
    return String(slice)
  }

  /// The `{token}` names appearing in `raw`, in source order (duplicates
  /// included). An unterminated `{` contributes nothing.
  private static func tokens(in raw: String) -> [String] {
    var names: [String] = []
    var index = raw.startIndex
    while index < raw.endIndex {
      guard raw[index] == "{", let close = raw[index...].firstIndex(of: "}") else {
        index = raw.index(after: index)
        continue
      }
      names.append(String(raw[raw.index(after: index)..<close]))
      index = raw.index(after: close)
    }
    return names
  }

  private func pad(_ value: Int, _ width: Int) -> String {
    Self.pad(value, width)
  }

  private static func pad(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    guard digits.count < width else { return digits }
    return String(repeating: "0", count: width - digits.count) + digits
  }
}
