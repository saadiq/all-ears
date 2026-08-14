/// Translates ``TranscriptSegment``/``Segment``/``WordTiming`` into the
/// canonical `.transcript.json` sidecar schema from `docs/data-formats.md`.
///
/// `Segment`'s and `WordTiming`'s `Codable` conformances do **not** match the
/// wire format directly, so this is a deliberate translation layer rather
/// than a reuse of their `Encodable` output:
/// - `Segment` has no `source`/`speaker` — those live on ``TranscriptSegment``,
///   added by the attribution stage upstream of rendering.
/// - `Segment.confidence` has no place in the sidecar schema (only
///   `words[].conf` does); it is intentionally dropped here.
/// - `WordTiming.text`/`.confidence` are keyed `text`/`confidence` by
///   `Codable`, but the wire format uses the short keys `w`/`conf`.
enum SidecarJSONRenderer {
  static func render(
    _ segments: [TranscriptSegment], diarization: TranscriptDiarizationInfo,
    speakers: [SessionSpeaker] = []
  ) -> String {
    var pairs: [(key: String, value: JSONValue)] = [
      ("schema", .int(1)),
      ("diarization", diarizationValue(diarization)),
    ]
    // The speaker map that labelled this run — see
    // ``TranscriptDocument/speakers``. Omitted (not rendered empty) for a
    // document with no session context, matching the frontmatter's habit of
    // omitting keys with nothing to say.
    if !speakers.isEmpty {
      pairs.append(("speakers", .array(speakers.map(speakerValue))))
    }
    pairs.append(("segments", .array(segments.map(segmentValue))))
    return JSON.render(.object(pairs)) + "\n"
  }

  private static func speakerValue(_ speaker: SessionSpeaker) -> JSONValue {
    .object([
      ("source", .string(speaker.source.rawValue)),
      ("name", .string(speaker.name)),
      ("confidence", .string(speaker.confidence.rawValue)),
    ])
  }

  /// The run-level diarization state, mirroring the Markdown frontmatter's
  /// `diarization` mapping so the two artifacts agree: `{ enabled, backend? }`.
  /// `backend` is omitted when diarization did not run (nil), exactly as the
  /// frontmatter omits the key.
  private static func diarizationValue(_ diarization: TranscriptDiarizationInfo) -> JSONValue {
    var pairs: [(key: String, value: JSONValue)] = [
      ("enabled", .bool(diarization.enabled))
    ]
    if let backend = diarization.backend {
      pairs.append(("backend", .string(backend)))
    }
    return .object(pairs)
  }

  private static func segmentValue(_ turn: TranscriptSegment) -> JSONValue {
    .object([
      ("start", .number(turn.segment.start)),
      ("end", .number(turn.segment.end)),
      ("source", .string(turn.source.rawValue)),
      ("speaker", .string(turn.speaker)),
      ("text", .string(turn.segment.text)),
      ("words", .array(turn.segment.words.map(wordValue))),
    ])
  }

  private static func wordValue(_ word: WordTiming) -> JSONValue {
    var pairs: [(key: String, value: JSONValue)] = [
      ("w", .string(word.text)),
      ("start", .number(word.start)),
      ("end", .number(word.end)),
    ]
    if let confidence = word.confidence {
      pairs.append(("conf", .number(confidence)))
    }
    return .object(pairs)
  }
}
