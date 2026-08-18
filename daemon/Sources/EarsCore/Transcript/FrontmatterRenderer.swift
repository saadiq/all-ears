import Yams

/// Renders a ``TranscriptFrontmatter`` to the block-style YAML block shown in
/// `docs/data-formats.md`, in exactly the field order the doc shows (with
/// `derived_from` inserted right after `kind` when present, since that's the
/// only field the doc mentions without pinning a position — see
/// ``TranscriptFrontmatter/derivedFrom``). Does not include the surrounding
/// `---` fences; ``TranscriptRenderer`` owns document-level assembly.
///
/// Emission goes through Yams (a real YAML implementation) rather than a
/// hand-rolled emitter; block style is the suite's standard, matching what
/// vault tooling normalises frontmatter to, so a published file's shape is
/// stable under it. What stays ours is the *decision* layer: field order,
/// which fields are omitted when empty, and when a free-form string is
/// double-quoted (``needsQuoting(_:)``) so no scalar can be re-read as a
/// number, bool, or timestamp by a generic YAML consumer.
enum FrontmatterRenderer {
  static func render(_ frontmatter: TranscriptFrontmatter) -> String {
    var pairs: [(Node, Node)] = []
    func add(_ key: String, _ value: Node) { pairs.append((Node(key), value)) }

    add("schema", plain(String(frontmatter.schema)))
    add("kind", plain(frontmatter.kind.rawValue))
    if let preset = frontmatter.preset {
      add("preset", scalar(preset))
    }
    if let derivedFrom = frontmatter.derivedFrom {
      add("derived_from", scalar(derivedFrom))
    }
    if let rangeRun = frontmatter.rangeRun {
      add("range_run", plain(rangeRun))
    }
    if let session = frontmatter.session {
      add("session", plain(session))
    }
    // The path-template context a downstream stage reads back
    // (`TranscriptFrontmatter.title`/`started`): present only for a document
    // that has session context to carry.
    if let title = frontmatter.title {
      add("title", scalar(title))
    }
    // The inverse of the note's own `transcript:` link — see
    // ``TranscriptFrontmatter/note``. Rendered next to `title` so the two
    // human-facing identity lines sit together, above the capture metadata.
    if let note = frontmatter.note {
      add("note", scalar(note))
    }
    // Who was on the call, as the roster observed it — kept next to the other
    // human-facing identity lines and above the capture metadata, because it
    // is the part a reader of the raw file actually wants.
    if !frontmatter.attendees.isEmpty {
      add("attendees", sequence(frontmatter.attendees.map(scalar)))
    }
    if let started = frontmatter.started {
      add("started", plain(UTCCalendar.iso8601(started)))
    }
    add("sources", sequence(frontmatter.sources.map(sourceValue)))
    add(
      "range",
      mapping([
        ("start", plain(UTCCalendar.iso8601(frontmatter.range.start))),
        ("end", plain(UTCCalendar.iso8601(frontmatter.range.end))),
      ]))
    add(
      "model",
      mapping([
        ("name", scalar(frontmatter.model.name)),
        ("backend", scalar(frontmatter.model.backend)),
        ("version", quoted(frontmatter.model.version)),
      ]))
    var diarizationPairs: [(String, Node)] = [
      ("enabled", plain(frontmatter.diarization.enabled ? "true" : "false"))
    ]
    if let backend = frontmatter.diarization.backend {
      diarizationPairs.append(("backend", scalar(backend)))
    }
    add("diarization", mapping(diarizationPairs))
    add("generated", plain(UTCCalendar.iso8601(frontmatter.generated)))
    add("duration_seconds", plain(RenderNumber.string(frontmatter.durationSeconds)))
    add("speech_seconds", plain(RenderNumber.string(frontmatter.speechSeconds)))
    add("word_count", plain(String(frontmatter.wordCount)))
    add("vocab", sequence(frontmatter.vocab.map(scalar)))
    if !frontmatter.audioStores.isEmpty {
      // `"<source>=<store>"` tokens: always quoted (they carry `=`, and a
      // source id may carry `:`), so they can never be misread as anything
      // but plain text.
      add(
        "audio_stores",
        sequence(frontmatter.audioStores.map { quoted("\($0.source.rawValue)=\($0.store)") }))
    }
    // Last, and always quoted: warnings are free prose (they carry commas,
    // parentheses and `:`).
    if !frontmatter.warnings.isEmpty {
      add("warnings", sequence(frontmatter.warnings.map { quoted($0) }))
    }

    return emit(.mapping(Node.Mapping(pairs)))
  }

  /// One `key: value` frontmatter line through the same emitter and quoting
  /// rules as ``render(_:)`` — what ``TranscriptFrontmatterEditor`` splices
  /// into an existing block, so a stamped line and a freshly rendered one
  /// can never disagree.
  static func line(_ key: String, _ value: String) -> String {
    emit(.mapping(Node.Mapping([(Node(key), scalar(value))])))
  }

  /// Serializes a node tree we just built. `width: -1` disables libYAML's
  /// line wrapping (a wrapped warning would be three scalars to a naive
  /// diff); `allowUnicode` keeps names as written instead of escaped. A
  /// well-formed tree of scalars/sequences/mappings cannot fail to emit, so
  /// the `try!` is an invariant, not a hope.
  private static func emit(_ node: Node) -> String {
    // swift-format-ignore: NeverForceUnwrap
    let yaml = try! Yams.serialize(node: node, width: -1, allowUnicode: true)
    return yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
  }

  private static func plain(_ string: String) -> Node {
    .scalar(Node.Scalar(string))
  }

  private static func quoted(_ string: String) -> Node {
    .scalar(Node.Scalar(string, .implicit, .doubleQuoted))
  }

  private static func sequence(_ nodes: [Node]) -> Node {
    .sequence(Node.Sequence(nodes))
  }

  private static func mapping(_ pairs: [(String, Node)]) -> Node {
    .mapping(Node.Mapping(pairs.map { (Node($0.0), $0.1) }))
  }

  /// `SourceID`s are quoted only when they contain `:` (i.e. `app:`/
  /// `browser:`/`device:` sources) — matching `docs/data-formats.md`, where
  /// the bare `mic` source needs no quoting.
  private static func sourceValue(_ id: SourceID) -> Node {
    id.rawValue.contains(":") ? quoted(id.rawValue) : plain(id.rawValue)
  }

  /// Quotes a free-form string scalar when leaving it bare could be
  /// ambiguous to a YAML parser: empty, flow/quote-significant characters,
  /// leading/trailing whitespace, a leading digit (numbers, dates, and
  /// version-like strings such as `"0.x"` all start with a digit), or a
  /// YAML reserved word. Fields with a known-safe shape (the range-run id,
  /// `kind`, numeric fields) bypass this and render plain directly.
  static func scalar(_ string: String) -> Node {
    needsQuoting(string) ? quoted(string) : plain(string)
  }

  private static let specialCharacters: Set<Character> = [
    ":", ",", "#", "[", "]", "{", "}", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`",
  ]
  private static let reservedWords: Set<String> = ["true", "false", "null", "~", "yes", "no"]

  private static func needsQuoting(_ string: String) -> Bool {
    guard let first = string.first else { return true }
    if string.contains(where: { specialCharacters.contains($0) }) { return true }
    if first == " " || string.last == " " { return true }
    if first == "-" { return true }
    if first.isNumber { return true }
    if reservedWords.contains(string.lowercased()) { return true }
    return false
  }
}
