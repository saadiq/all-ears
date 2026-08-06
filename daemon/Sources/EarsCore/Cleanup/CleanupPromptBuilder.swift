/// Builds the ``LLMPrompt`` `cleanup` sends to an ``LLMBackend`` for one
/// segment/chunk of transcript text.
///
/// Two guardrails from `docs/specs/llm-stages.md` live here:
///
/// - **Minimal-change prompt:** "instruct for the smallest edit that fixes
///   errors; keep filler words unless removal is explicitly configured."
///   The instructions text below says exactly that, and only opts into
///   filler removal when ``removeFiller`` is set.
/// - **Stable-prefix/dynamic split for cache reuse:** "split a stable
///   prompt prefix from the dynamic input (system prompt + vocabulary +
///   instructions as the prefix; the transcript as the suffix) so a caching
///   backend can reuse the KV-cache/prompt cache across chunks and runs."
///   ``stablePrefix`` depends only on this builder's configuration (system
///   prompt, vocabulary, filler policy) and is therefore byte-identical
///   across every ``build(transcript:)`` call for a given builder,
///   regardless of the transcript text passed in.
///
/// The vocabulary (merged global + session known-word list, per
/// `docs/data-formats.md`) is injected as an explicit correction backstop --
/// the same list a ``BiasingTranscriber`` uses at transcription time, reused
/// here per `docs/specs/model-interface.md`'s "known-word biasing
/// summary".
public struct CleanupPromptBuilder: Sendable {
  public var systemPrompt: String
  public var vocabulary: [String]
  public var removeFiller: Bool

  public init(
    systemPrompt: String = CleanupPromptBuilder.defaultSystemPrompt,
    vocabulary: [String] = [],
    removeFiller: Bool = false
  ) {
    self.systemPrompt = systemPrompt
    self.vocabulary = vocabulary
    self.removeFiller = removeFiller
  }

  public static let defaultSystemPrompt = """
    You clean up a raw speech transcript for readability. Make the smallest \
    edits that fix errors: correct mis-transcriptions and homophones, fix \
    punctuation and casing. Preserve meaning, timestamps, and speaker turns \
    exactly -- never invent, drop, or reorder content. Output only the \
    corrected text, nothing else.
    """

  /// The part of the prompt identical across every call this builder makes:
  /// the system prompt, the filler-word policy, and the vocabulary
  /// correction backstop (when non-empty).
  public var stablePrefix: String {
    var sections = [systemPrompt]
    if removeFiller {
      sections.append(
        "Remove filler words (\"um\", \"uh\", \"like\") where they add no meaning.")
    } else {
      sections.append("Keep filler words as-is; do not remove them.")
    }
    if !vocabulary.isEmpty {
      var vocabSection = "Known words/names that may be mis-transcribed -- correct to these\n"
      vocabSection += "when the audio clearly matches:\n"
      vocabSection += vocabulary.map { "- \($0)" }.joined(separator: "\n")
      sections.append(vocabSection)
    }
    return sections.joined(separator: "\n\n") + "\n\n"
  }

  /// Builds the full prompt for one segment/chunk's `transcript` text -- the
  /// dynamic suffix, sent verbatim with no additional wrapping so the
  /// backend's completion corresponds 1:1 with the input `cleanup` will run
  /// through ``CleanupValidator``.
  public func build(transcript: String) -> LLMPrompt {
    LLMPrompt(stablePrefix: stablePrefix, dynamicSuffix: transcript)
  }

  // MARK: - Batched turns

  /// The stable prefix for a batched call: ``stablePrefix`` plus the marker
  /// protocol ``parseChunkResponse(_:)`` parses back. Separate from
  /// ``stablePrefix`` so the single-turn shape keeps a prompt with no marker
  /// instructions in it, and so each shape's prefix stays byte-identical
  /// across calls for prompt-cache reuse.
  public var chunkStablePrefix: String {
    stablePrefix + Self.chunkProtocolInstructions + "\n\n"
  }

  /// Builds one prompt covering several turns, rendered with the turn markers
  /// the response is parsed back on.
  public func build(chunk turns: [CleanupChunkTurn]) -> LLMPrompt {
    LLMPrompt(stablePrefix: chunkStablePrefix, dynamicSuffix: Self.renderChunk(turns))
  }

  /// The marker contract, stated to the model exactly as
  /// ``parseChunkResponse(_:)`` enforces it. Turn-for-turn correspondence is
  /// what makes a batched call safe: every returned turn is still validated
  /// against *its own* original by ``CleanupValidator``, so a merge, split, or
  /// drop shows up as a per-turn rejection rather than as silently shifted
  /// text.
  private static let chunkProtocolInstructions = """
    The transcript below is split into numbered turns. Each turn is one line \
    beginning with a marker like [[3|Alice]] -- the turn number, then the \
    speaker.

    Return exactly one line per turn, in the same order, each beginning with \
    that turn's marker copied verbatim, followed by the corrected text. Never \
    merge, split, reorder, add, or drop turns: a turn with nothing to fix is \
    returned unchanged. Correct each turn using the surrounding turns as \
    context, but only ever edit the turn's own words. Output only the marked \
    lines, nothing else.
    """

  /// Renders `turns` in the marker format ``chunkProtocolInstructions``
  /// describes. Newlines inside a turn's text collapse to spaces so that one
  /// turn is always exactly one line -- the invariant the parser leans on.
  public static func renderChunk(_ turns: [CleanupChunkTurn]) -> String {
    turns.map { turn in
      "[[\(turn.index)|\(sanitizeMarkerField(turn.speaker))]] \(collapseNewlines(turn.text))"
    }
    .joined(separator: "\n")
  }

  /// Parses a batched response back into `turn number -> corrected text`.
  ///
  /// Deliberately forgiving about everything except the turn numbers: leading
  /// prose, blank lines, and a model that re-wraps a long turn onto several
  /// lines (continuation lines fold into the turn above) are all tolerated,
  /// because the caller does not have to trust this parse -- an unparsed turn
  /// falls back to its original, and a mis-parsed one still has to satisfy
  /// ``CleanupValidator`` against its own original. A repeated turn number
  /// keeps the first occurrence.
  public static func parseChunkResponse(_ response: String) -> [Int: String] {
    var parsed: [Int: String] = [:]
    var current: Int? = nil

    for rawLine in response.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if let (index, text) = parseMarkedLine(line) {
        current = index
        if parsed[index] == nil { parsed[index] = text }
        continue
      }
      // A continuation line: text the model wrapped off the end of the turn
      // above. Anything before the first marker is preamble and is dropped.
      guard let index = current else { continue }
      let continuation = line.trimmingCharacters(in: .whitespaces)
      guard !continuation.isEmpty else { continue }
      parsed[index] = [parsed[index], continuation].compactMap { $0 }.joined(separator: " ")
    }

    return parsed.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  /// `[[12|Alice]] text` -> `(12, "text")`, or nil when the line carries no
  /// well-formed marker. Hand-parsed rather than regex-matched: the shape is
  /// fixed and this runs once per line of every chunk.
  private static func parseMarkedLine(_ line: String) -> (Int, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[[") else { return nil }
    let afterOpen = trimmed.dropFirst(2)
    guard let closeRange = afterOpen.range(of: "]]") else { return nil }
    let marker = afterOpen[..<closeRange.lowerBound]
    // The number runs to the field separator, or to the end for a bare
    // `[[12]]` marker (which a model may well return instead of the full one).
    let numberPart = marker.split(separator: "|", maxSplits: 1).first ?? marker[...]
    guard let index = Int(numberPart.trimmingCharacters(in: .whitespaces)) else { return nil }
    let text = afterOpen[closeRange.upperBound...].trimmingCharacters(in: .whitespaces)
    return (index, text)
  }

  /// Keeps a speaker label from breaking out of its marker.
  private static func sanitizeMarkerField(_ value: String) -> String {
    collapseNewlines(value).replacingOccurrences(of: "]", with: " ")
      .replacingOccurrences(of: "|", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  private static func collapseNewlines(_ value: String) -> String {
    value.split(whereSeparator: \.isNewline).joined(separator: " ")
  }
}

/// One turn as it is presented to the model inside a batched cleanup call.
public struct CleanupChunkTurn: Sendable, Hashable {
  /// The turn's marker number, unique within its chunk. `CleanupPipeline`
  /// numbers from 1 per chunk, so a marker never grows with transcript length.
  public var index: Int
  /// The speaker label, shown as context only -- it is never edited, and the
  /// parser ignores it on the way back.
  public var speaker: String
  public var text: String

  public init(index: Int, speaker: String, text: String) {
    self.index = index
    self.speaker = speaker
    self.text = text
  }
}
