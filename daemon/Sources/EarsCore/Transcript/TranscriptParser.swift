import Foundation
import Yams

/// Errors surfaced while parsing a rendered transcript document back into a
/// ``TranscriptDocument``.
public enum TranscriptParsingError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The document doesn't open with the `---\n...\n---\n` frontmatter fence
  /// ``TranscriptRenderer/renderMarkdown(_:)`` always writes.
  case missingFrontmatterFences
  /// A required frontmatter field is missing.
  case missingField(String)
  /// A frontmatter field's value doesn't parse as its expected type.
  case malformedField(field: String, value: String)
  /// The JSON sidecar isn't valid JSON, or doesn't match the sidecar schema.
  case malformedJSON(String)

  public var description: String {
    switch self {
    case .missingFrontmatterFences:
      return "transcript is missing its '---' frontmatter fences"
    case .missingField(let field):
      return "transcript frontmatter is missing required field '\(field)'"
    case .malformedField(let field, let value):
      return "transcript frontmatter field '\(field)' has an unparseable value: '\(value)'"
    case .malformedJSON(let detail):
      return "transcript JSON sidecar is malformed: \(detail)"
    }
  }
}

/// Parses a rendered `.transcript.md` (or `.clean.md`/`.summary.md` — all
/// three share one schema, see ``TranscriptRenderer``) document, and
/// optionally its `.transcript.json` sidecar, back into a
/// ``TranscriptDocument``. `EarsCore/Transcript/` is otherwise
/// write-direction-only (`TranscriptRenderer`/`SidecarJSONRenderer`); this is
/// the read direction `cleanup`/`summarize` need.
///
/// The frontmatter block goes through a real YAML parse (Yams): the schema's
/// *fields* are fixed, but the *style* is whatever valid YAML the file
/// carries — this suite's block-style output, its older flow-style output,
/// or a vault linter's reformatting of either. The Markdown body and the
/// JSON sidecar remain narrow, hand-matched parsers of this suite's own
/// renderers.
///
/// **Known lossy fields:**
/// - Neither the Markdown body nor the JSON sidecar writes
///   `Segment.confidence` (``SidecarJSONRenderer``'s doc comment:
///   "intentionally dropped"). A parsed `Segment.confidence` is therefore
///   always `nil`, regardless of what the original transcription run
///   measured. Any confidence-based decision (e.g. `HighConfidenceSkipPolicy`)
///   has no effect against a re-read, persisted transcript — only at the
///   moment `transcribe` first produces segments.
/// - The JSON sidecar has no `sourceProvenance` field at all
///   (``SidecarJSONRenderer/segmentValue(_:)`` never writes one) — only the
///   Markdown heading's optional `<!-- source: ... -->` comment carries it.
///   ``parse(markdown:jsonSidecar:)`` therefore recovers `sourceProvenance`
///   from the Markdown body even when a JSON sidecar supplies everything
///   else, by merging the two positionally (same segment order both
///   renderers share) — ``parseJSONSidecar(_:)`` called alone cannot recover
///   it and always reports `false`.
/// - Without a `sourceProvenance` marker, the Markdown body alone never
///   records *which* source a turn came from (`MarkdownBodyRenderer` omits
///   the source entirely unless `sourceProvenance` is set). The Markdown-only
///   fallback (`jsonSidecar == nil`) resolves an unmarked turn's source to
///   `frontmatter.sources.first` — correct for the common single-source case,
///   ambiguous (and only a guess) for a genuinely multi-source document with
///   unmarked turns, which needs the JSON sidecar for correct attribution.
///
/// These are limitations of the on-disk format as it exists today, not
/// something this parser works around.
public enum TranscriptParser {
  /// Parses `markdown`'s frontmatter, and its segments from `jsonSidecar` when
  /// given (full fidelity: start/end/words) or, when `jsonSidecar` is `nil`,
  /// reconstructed from the Markdown body alone (reduced fidelity: no
  /// per-segment `end` time or word timings — see
  /// ``parseMarkdownSegments(_:rangeStart:)``).
  public static func parse(markdown: String, jsonSidecar: String? = nil) throws
    -> TranscriptDocument
  {
    let frontmatter = try parseFrontmatter(markdown)
    let fallbackSource = frontmatter.sources.first ?? SourceID("unknown")
    let segments: [TranscriptSegment]
    if let jsonSidecar {
      var jsonSegments = try parseJSONSidecar(jsonSidecar)
      // Overlay the fields only the Markdown body carries (see the type doc's
      // "Known lossy fields"): sourceProvenance, and isBackchannel — the
      // sidecar deliberately stores every backchannel as a full segment, so
      // without this overlay one parse-with-sidecar round trip erases the
      // demotion and every downstream re-render (cleanup, summarize, the
      // published note) loses it (journal #180). Only when the turn counts
      // agree, so a mismatched/hand-edited pair degrades to `false` rather
      // than misattributing flags to the wrong turns.
      if let markdownTurns = try? parseMarkdownSegments(
        markdown, rangeStart: frontmatter.range.start, fallbackSource: fallbackSource),
        markdownTurns.count == jsonSegments.count
      {
        for index in jsonSegments.indices {
          jsonSegments[index].sourceProvenance = markdownTurns[index].sourceProvenance
          jsonSegments[index].isBackchannel = markdownTurns[index].isBackchannel
        }
      }
      segments = jsonSegments
    } else {
      segments = try parseMarkdownSegments(
        markdown, rangeStart: frontmatter.range.start, fallbackSource: fallbackSource)
    }
    return TranscriptDocument(frontmatter: frontmatter, segments: segments)
  }

  // MARK: - Frontmatter

  public static func parseFrontmatter(_ markdown: String) throws -> TranscriptFrontmatter {
    guard markdown.hasPrefix("---\n") else { throw TranscriptParsingError.missingFrontmatterFences }
    let afterOpenFence = markdown.dropFirst(4)
    guard let closeFenceRange = afterOpenFence.range(of: "\n---\n") else {
      throw TranscriptParsingError.missingFrontmatterFences
    }
    let block = String(afterOpenFence[afterOpenFence.startIndex..<closeFenceRange.lowerBound])

    // A real YAML parse (Yams), not a grammar matched to our own emitter:
    // published artifacts live in the user's vault, where other tooling
    // rewrites frontmatter freely between block and flow style. Any valid
    // YAML mapping is accepted; the emitter's block style and the older flow
    // files are both just YAML. Scalars are read as their raw text (`Node`
    // composition does no type resolution), so timestamps and ids reach the
    // same string codecs they always did.
    let mapping: Node.Mapping
    do {
      guard let root = try Yams.compose(yaml: block), let composed = root.mapping else {
        throw TranscriptParsingError.malformedField(
          field: "frontmatter", value: "not a YAML mapping")
      }
      mapping = composed
    } catch let error as YamlError {
      throw TranscriptParsingError.malformedField(field: "frontmatter", value: "\(error)")
    }

    func node(_ name: String) throws -> Node {
      guard let value = mapping[name] else { throw TranscriptParsingError.missingField(name) }
      return value
    }
    func scalar(_ name: String, _ node: Node) throws -> String {
      guard let value = node.scalar?.string else {
        throw TranscriptParsingError.malformedField(field: name, value: "\(node)")
      }
      return value
    }
    func optionalScalar(_ name: String) -> String? {
      mapping[name]?.scalar?.string
    }
    func strings(_ name: String, _ node: Node) throws -> [String] {
      guard let sequence = node.sequence else {
        throw TranscriptParsingError.malformedField(field: name, value: "\(node)")
      }
      return try sequence.map { try scalar(name, $0) }
    }
    func int(_ name: String, _ node: Node) throws -> Int {
      guard let value = Int(try scalar(name, node)) else {
        throw TranscriptParsingError.malformedField(field: name, value: "\(node)")
      }
      return value
    }
    func double(_ name: String, _ node: Node) throws -> Double {
      guard let value = Double(try scalar(name, node)) else {
        throw TranscriptParsingError.malformedField(field: name, value: "\(node)")
      }
      return value
    }
    func instant(_ name: String, _ node: Node) throws -> Instant {
      let raw = try scalar(name, node)
      guard let value = ISO8601InstantCodec.parse(raw) else {
        throw TranscriptParsingError.malformedField(field: name, value: raw)
      }
      return value
    }
    func submapping(_ name: String) throws -> Node.Mapping {
      guard let value = try node(name).mapping else {
        throw TranscriptParsingError.malformedField(field: name, value: "\(try node(name))")
      }
      return value
    }
    func require(_ mapping: Node.Mapping, _ key: String, _ context: String) throws -> Node {
      guard let value = mapping[key] else {
        throw TranscriptParsingError.missingField("\(context).\(key)")
      }
      return value
    }

    let schema = try int("schema", node("schema"))
    let kindRaw = try scalar("kind", node("kind"))
    guard let kind = TranscriptKind(rawValue: kindRaw) else {
      throw TranscriptParsingError.malformedField(field: "kind", value: kindRaw)
    }
    let derivedFrom = optionalScalar("derived_from")
    let preset = optionalScalar("preset")
    // `range_run:` (a synthesized range-run identifier) and `session:` (the
    // session UUID) are each optional: a session transcript carries only
    // `session:`, a plain range transcript only `range_run:`.
    let rangeRun = optionalScalar("range_run")
    let session = optionalScalar("session")
    // The path-template context (see `TranscriptFrontmatter.title`/`started`):
    // both optional, both absent on a document with no session context.
    let title = optionalScalar("title")
    // Round-tripped rather than dropped: a `cleanup` rerun over a transcript
    // `summarize` has already linked must not silently unlink it.
    let note = optionalScalar("note")
    // Both post-date the original schema, so both are optional: a transcript
    // written before they existed parses unchanged.
    let attendees = try mapping["attendees"].map { try strings("attendees", $0) } ?? []
    let warnings = try mapping["warnings"].map { try strings("warnings", $0) } ?? []
    let started = try mapping["started"].map { try instant("started", $0) }
    let sources = try strings("sources", node("sources")).map { SourceID($0) }

    let rangeMapping = try submapping("range")
    let range = TimeRange(
      start: try instant("range.start", require(rangeMapping, "start", "range")),
      end: try instant("range.end", require(rangeMapping, "end", "range")))

    let modelMapping = try submapping("model")
    let model = TranscriptModelInfo(
      name: try scalar("model.name", require(modelMapping, "name", "model")),
      backend: try scalar("model.backend", require(modelMapping, "backend", "model")),
      version: try scalar("model.version", require(modelMapping, "version", "model")))

    let diarizationMapping = try submapping("diarization")
    let diarization = TranscriptDiarizationInfo(
      enabled: try require(diarizationMapping, "enabled", "diarization").bool ?? false,
      backend: diarizationMapping["backend"]?.scalar?.string)

    let generated = try instant("generated", node("generated"))
    let durationSeconds = try double("duration_seconds", node("duration_seconds"))
    let speechSeconds = try double("speech_seconds", node("speech_seconds"))
    let wordCount = try int("word_count", node("word_count"))
    let vocab = try strings("vocab", node("vocab"))
    let audioStoreTokens = try mapping["audio_stores"].map { try strings("audio_stores", $0) } ?? []
    let audioStores = try audioStoreTokens.map { token -> TranscriptAudioStore in
      // `<source>=<store>`; the store token never contains `=` and a source id
      // never does, so splitting on the first `=` recovers both.
      guard let separator = token.firstIndex(of: "=") else {
        throw TranscriptParsingError.malformedField(field: "audio_stores", value: token)
      }
      return TranscriptAudioStore(
        source: SourceID(String(token[token.startIndex..<separator])),
        store: String(token[token.index(after: separator)...]))
    }

    return TranscriptFrontmatter(
      schema: schema,
      kind: kind,
      rangeRun: rangeRun,
      session: session,
      title: title,
      started: started,
      note: note,
      attendees: attendees,
      warnings: warnings,
      sources: sources,
      range: range,
      model: model,
      diarization: diarization,
      generated: generated,
      durationSeconds: durationSeconds,
      speechSeconds: speechSeconds,
      wordCount: wordCount,
      vocab: vocab,
      derivedFrom: derivedFrom,
      preset: preset,
      audioStores: audioStores)
  }

  // MARK: - JSON sidecar (full-fidelity segments)

  public static func parseJSONSidecar(_ json: String) throws -> [TranscriptSegment] {
    let root: Any
    do {
      root = try JSONSerialization.jsonObject(with: Data(json.utf8))
    } catch {
      throw TranscriptParsingError.malformedJSON(error.localizedDescription)
    }
    guard let object = root as? [String: Any], let rawSegments = object["segments"] as? [Any] else {
      throw TranscriptParsingError.malformedJSON("missing top-level 'segments' array")
    }
    return try rawSegments.map(segment(from:))
  }

  private static func segment(from raw: Any) throws -> TranscriptSegment {
    guard let dict = raw as? [String: Any],
      let start = dict["start"] as? Double,
      let end = dict["end"] as? Double,
      let source = dict["source"] as? String,
      let speaker = dict["speaker"] as? String,
      let text = dict["text"] as? String
    else {
      throw TranscriptParsingError.malformedJSON("malformed segment object")
    }
    let words = (dict["words"] as? [Any] ?? []).compactMap(wordTiming(from:))
    return TranscriptSegment(
      source: SourceID(source),
      speaker: speaker,
      segment: Segment(start: start, end: end, text: text, words: words, confidence: nil))
  }

  private static func wordTiming(from raw: Any) -> WordTiming? {
    guard let dict = raw as? [String: Any],
      let text = dict["w"] as? String,
      let start = dict["start"] as? Double,
      let end = dict["end"] as? Double
    else { return nil }
    return WordTiming(text: text, start: start, end: end, confidence: dict["conf"] as? Double)
  }

  // MARK: - Markdown-body fallback (reduced fidelity: no end time/words)

  /// Reconstructs an approximate segment list directly from the Markdown
  /// body when no JSON sidecar is available. Each turn's heading gives only
  /// a `HH:MM:SS` time-of-day for its start (``MarkdownBodyRenderer`` never
  /// writes an end time or word timings) — so every returned `Segment.end`
  /// equals its `start` (zero duration) and `words` is always empty. Callers
  /// that need real durations/word timings must use the JSON sidecar.
  ///
  /// - Parameter fallbackSource: Used for a turn with no `sourceProvenance`
  ///   comment, since the Markdown heading itself carries no source id in
  ///   that case (see the type doc's "Known lossy fields").
  public static func parseMarkdownSegments(
    _ markdown: String, rangeStart: Instant, fallbackSource: SourceID
  ) throws
    -> [TranscriptSegment]
  {
    guard let bodyRange = markdown.range(of: "\n---\n") else { return [] }
    let body = markdown[bodyRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return [] }

    let blocks = body.components(separatedBy: "\n\n")
    var segments: [TranscriptSegment] = []
    for block in blocks {
      // A block is one turn plus any backchannels attached beneath it. The
      // turn's own text may not contain a line beginning "> [", which is the
      // reserved backchannel form (see ``MarkdownBodyRenderer``).
      var lines = block.components(separatedBy: "\n")
      guard !lines.isEmpty else {
        throw TranscriptParsingError.malformedField(field: "segment heading", value: block)
      }
      let labelLine = lines.removeFirst()
      var backchannelLines: [String] = []
      while let last = lines.last, last.hasPrefix("> [") {
        backchannelLines.insert(lines.removeLast(), at: 0)
      }

      segments.append(
        try turn(
          label: labelLine, text: lines.joined(separator: "\n"), rangeStart: rangeStart,
          fallbackSource: fallbackSource))
      for line in backchannelLines {
        segments.append(
          try backchannel(line, rangeStart: rangeStart, fallbackSource: fallbackSource))
      }
    }
    return segments
  }

  /// One turn from its label line and body text. Accepts both the current
  /// `**[HH:MM:SS] speaker**` form and the `## [HH:MM:SS] speaker` heading
  /// written before that change, so transcripts already on disk keep parsing.
  private static func turn(
    label: String, text: String, rangeStart: Instant, fallbackSource: SourceID
  ) throws -> TranscriptSegment {
    let marker: String
    if label.hasPrefix("**[") {
      marker = "**["
    } else if label.hasPrefix("## [") {
      marker = "## ["
    } else {
      throw TranscriptParsingError.malformedField(field: "segment heading", value: label)
    }

    guard let closeBracket = label.firstIndex(of: "]") else {
      throw TranscriptParsingError.malformedField(field: "segment heading", value: label)
    }
    let timeString = label[label.index(label.startIndex, offsetBy: marker.count)..<closeBracket]
    var rest = label[label.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)

    var source = fallbackSource
    var sourceProvenance = false
    if let commentRange = rest.range(of: "<!-- source: ") {
      let afterMarker = rest[commentRange.upperBound...]
      if let endMarker = afterMarker.range(of: " -->") {
        source = SourceID(String(afterMarker[afterMarker.startIndex..<endMarker.lowerBound]))
        sourceProvenance = true
      }
      rest = String(rest[rest.startIndex..<commentRange.lowerBound]).trimmingCharacters(
        in: .whitespaces)
    }
    // The bold form closes with `**`; the heading form has no trailing marker.
    if rest.hasSuffix("**") { rest = String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces) }

    let startOffset = try timeOfDayOffset(timeString, rangeStart: rangeStart)
    return TranscriptSegment(
      source: source,
      speaker: rest,
      segment: Segment(start: startOffset, end: startOffset, text: text),
      sourceProvenance: sourceProvenance)
  }

  /// One backchannel from its `> [HH:MM:SS] speaker: text` line.
  private static func backchannel(
    _ line: String, rangeStart: Instant, fallbackSource: SourceID
  ) throws -> TranscriptSegment {
    guard let closeBracket = line.firstIndex(of: "]") else {
      throw TranscriptParsingError.malformedField(field: "backchannel", value: line)
    }
    let timeString = line[line.index(line.startIndex, offsetBy: 3)..<closeBracket]
    let rest = line[line.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)
    guard let colon = rest.firstIndex(of: ":") else {
      throw TranscriptParsingError.malformedField(field: "backchannel", value: line)
    }
    let speaker = String(rest[rest.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
    let text = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

    let startOffset = try timeOfDayOffset(timeString, rangeStart: rangeStart)
    return TranscriptSegment(
      source: fallbackSource,
      speaker: speaker,
      segment: Segment(start: startOffset, end: startOffset, text: text),
      isBackchannel: true)
  }

  /// Resolves a Markdown heading's `HH:MM:SS` time-of-day back to a seconds
  /// offset from `rangeStart`, assuming the same UTC calendar day as
  /// `rangeStart` — `MarkdownBodyRenderer` renders only time-of-day, dropping
  /// the date, so a range crossing midnight cannot be perfectly recovered
  /// from Markdown alone (another reason the JSON sidecar is the
  /// full-fidelity source).
  private static func timeOfDayOffset(_ timeString: Substring, rangeStart: Instant) throws -> Double
  {
    let parts = timeString.split(separator: ":")
    guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2])
    else {
      throw TranscriptParsingError.malformedField(
        field: "segment heading time", value: String(timeString))
    }
    let dayStart = rangeStart.secondsSinceEpoch - Double(Int(rangeStart.secondsSinceEpoch) % 86400)
    let secondOfDay = Double(h * 3600 + m * 60 + s)
    return (dayStart + secondOfDay) - rangeStart.secondsSinceEpoch
  }

}
