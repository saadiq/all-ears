/// Renders a ``TranscriptFrontmatter`` to the YAML block shown in
/// `docs/data-formats.md`, in exactly the field order the doc shows (with
/// `derived_from` inserted right after `kind` when present, since that's the
/// only field the doc mentions without pinning a position — see
/// ``TranscriptFrontmatter/derivedFrom``). Does not include the surrounding
/// `---` fences; ``TranscriptRenderer`` owns document-level assembly.
enum FrontmatterRenderer {
  static func render(_ frontmatter: TranscriptFrontmatter) -> String {
    var lines: [String] = []

    lines.append(YAML.line("schema", .plain(String(frontmatter.schema))))
    lines.append(YAML.line("kind", .plain(frontmatter.kind.rawValue)))
    if let preset = frontmatter.preset {
      lines.append(YAML.line("preset", scalar(preset)))
    }
    if let derivedFrom = frontmatter.derivedFrom {
      lines.append(YAML.line("derived_from", scalar(derivedFrom)))
    }
    if let rangeRun = frontmatter.rangeRun {
      lines.append(YAML.line("range_run", .plain(rangeRun)))
    }
    if let session = frontmatter.session {
      lines.append(YAML.line("session", .plain(session)))
    }
    // The path-template context a downstream stage reads back
    // (`TranscriptFrontmatter.title`/`started`): present only for a document
    // that has session context to carry.
    if let title = frontmatter.title {
      lines.append(YAML.line("title", scalar(title)))
    }
    // The inverse of the note's own `transcript:` link — see
    // ``TranscriptFrontmatter/note``. Rendered next to `title` so the two
    // human-facing identity lines sit together, above the capture metadata.
    if let note = frontmatter.note {
      lines.append(YAML.line("note", scalar(note)))
    }
    // Who was on the call, as the roster observed it — kept next to the other
    // human-facing identity lines and above the capture metadata, because it
    // is the part a reader of the raw file actually wants.
    if !frontmatter.attendees.isEmpty {
      lines.append(YAML.line("attendees", .flowArray(frontmatter.attendees.map(scalar))))
    }
    if let started = frontmatter.started {
      lines.append(YAML.line("started", .plain(UTCCalendar.iso8601(started))))
    }
    lines.append(YAML.line("sources", .flowArray(frontmatter.sources.map(sourceValue))))
    lines.append(
      YAML.line(
        "range",
        .flowMapping([
          ("start", .plain(UTCCalendar.iso8601(frontmatter.range.start))),
          ("end", .plain(UTCCalendar.iso8601(frontmatter.range.end))),
        ])
      )
    )
    lines.append(
      YAML.line(
        "model",
        .flowMapping([
          ("name", scalar(frontmatter.model.name)),
          ("backend", scalar(frontmatter.model.backend)),
          ("version", .quoted(frontmatter.model.version)),
        ])
      )
    )
    lines.append(
      YAML.line(
        "diarization",
        .flowMapping([
          ("enabled", .plain(frontmatter.diarization.enabled ? "true" : "false")),
          ("backend", frontmatter.diarization.backend.map(scalar)),
        ])
      )
    )
    lines.append(YAML.line("generated", .plain(UTCCalendar.iso8601(frontmatter.generated))))
    lines.append(
      YAML.line("duration_seconds", .plain(RenderNumber.string(frontmatter.durationSeconds))))
    lines.append(
      YAML.line("speech_seconds", .plain(RenderNumber.string(frontmatter.speechSeconds))))
    lines.append(YAML.line("word_count", .plain(String(frontmatter.wordCount))))
    lines.append(YAML.line("vocab", .flowArray(frontmatter.vocab.map(scalar))))
    if !frontmatter.audioStores.isEmpty {
      // `"<source>=<store>"` tokens: always quoted (they carry `=`, and a
      // source id may carry `:`), so they round-trip through the flow-array
      // grammar without ambiguity. Source ids never contain `=`.
      lines.append(
        YAML.line(
          "audio_stores",
          .flowArray(frontmatter.audioStores.map { .quoted("\($0.source.rawValue)=\($0.store)") })))
    }
    // Last, and always quoted: warnings are free prose (they carry commas,
    // parentheses and `:`), so the flow-array grammar needs them quoted to
    // round-trip.
    if !frontmatter.warnings.isEmpty {
      lines.append(
        YAML.line("warnings", .flowArray(frontmatter.warnings.map { .quoted($0) })))
    }

    return lines.joined(separator: "\n")
  }

  /// `SourceID`s are quoted only when they contain `:` (i.e. `app:`/
  /// `browser:`/`device:` sources) — matching `sources: [mic,
  /// "app:us.zoom.xos"]` in `docs/data-formats.md`, where the bare `mic`
  /// source needs no quoting.
  private static func sourceValue(_ id: SourceID) -> YAML.Value {
    id.rawValue.contains(":") ? .quoted(id.rawValue) : .plain(id.rawValue)
  }

  /// Quotes a free-form string scalar when leaving it bare could be
  /// ambiguous to a YAML parser: empty, flow/quote-significant characters,
  /// leading/trailing whitespace, a leading digit (numbers, dates, and
  /// version-like strings such as `"0.x"` all start with a digit), or a
  /// YAML reserved word. Fields with a known-safe shape (the range-run id,
  /// `kind`, numeric fields) bypass this and render `.plain` directly.
  static func scalar(_ string: String) -> YAML.Value {
    needsQuoting(string) ? .quoted(string) : .plain(string)
  }

  private static let specialCharacters: Set<Character> = [
    ":", ",", "#", "[", "]", "{", "}", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`",
  ]
  private static let reservedWords: Set<String> = ["true", "false", "null", "~", "yes", "no"]

  private static func needsQuoting(_ string: String) -> Bool {
    guard let first = string.first else { return true }
    if string.contains(where: { specialCharacters.contains($0) }) { return true }
    if first == " " || string.last == " " { return true }
    if first.isNumber { return true }
    if reservedWords.contains(string.lowercased()) { return true }
    return false
  }
}
