import EarsCore
import Foundation

/// Picks the one `[[summarize.preset]]` a conversation belongs to, by asking
/// the configured LLM backend which preset's `when` description fits the
/// transcript.
///
/// A conversation has one type — it is a user-research call, or an investor
/// call, or a workshop, never several at once — but the on-end chain used to
/// run every configured preset over every session. With two presets writing to
/// the same daily note that is not merely wasteful: the later run overwrites
/// the earlier one's note, and which shape survives is decided by config
/// order. Selecting here costs one short classification call and spends the
/// expensive per-preset calls only on the preset that was actually wanted.
///
/// Every failure mode lands on a preset rather than on an error: an
/// unparseable answer, an answer naming no configured preset, and a backend
/// that throws all fall back to the caller's `fallback` and say so loudly.
/// Filing a call under the wrong shape is recoverable by rerunning
/// `summarize --preset <name>`; ending the chain with no note at all is the
/// outcome the whole stage exists to avoid.
enum PresetSelection {
  /// One preset that declared a `when`, and is therefore eligible to be
  /// chosen. A preset with no `when` describes no conversation and is never a
  /// candidate — it stays reachable through `--preset`/`--all-presets`.
  struct Candidate: Sendable, Equatable {
    var name: String
    var when: String
  }

  /// Which preset to run, and why — the reasoning is logged so `earsd.jsonl`
  /// shows why a session got the preset it got, rather than only which.
  struct Choice: Sendable, Equatable {
    var name: String
    /// The model's own one-line justification, when it gave one.
    var reason: String?
    /// Whether ``name`` is the fallback rather than a real classification.
    /// The caller logs these loudly; a clean choice needs no remark beyond
    /// the ordinary notice.
    var fellBack: Bool = false
    /// What the model actually said, kept for the fallback's log line — a
    /// fallback is only diagnosable if the rejected answer is quotable.
    var rawAnswer: String? = nil
  }

  /// How much transcript the classifier is shown, in characters.
  ///
  /// The head, not a sample or the whole thing: what kind of conversation
  /// this is gets established in its opening minutes — who joined, what they
  /// said they were there for — and the frontmatter that leads the file
  /// carries the title and the roster on top of that. An hour of detail after
  /// that point sharpens nothing and turns a cheap classification into an
  /// expensive one.
  static let maxTranscriptCharacters = 12_000

  static func select(
    candidates: [Candidate], fallback: String, transcript: String,
    backend: any LLMBackend
  ) async -> Choice {
    let answer: String
    do {
      answer = try await backend.complete(prompt(candidates: candidates, transcript: transcript))
        .text
    } catch {
      return Choice(
        name: fallback, reason: "classification failed: \(error)", fellBack: true)
    }
    guard let parsed = parse(answer, candidates: candidates) else {
      return Choice(name: fallback, fellBack: true, rawAnswer: answer)
    }
    return Choice(name: parsed.name, reason: parsed.reason)
  }

  /// The classification prompt: the candidate presets with their `when`
  /// descriptions, a fixed two-line answer shape, then the transcript.
  ///
  /// Two lines rather than one because the reason is what makes a wrong
  /// selection debuggable from the log alone — "chose workshop because the
  /// participants were reviewing slides together" is a fixable `when`
  /// description, where a bare `workshop` is a mystery. The name goes on the
  /// first line so the answer is parseable even when the model ignores the
  /// rest of the instruction.
  static func prompt(candidates: [Candidate], transcript: String) -> LLMPrompt {
    let menu = candidates.map { "- \($0.name): \($0.when)" }.joined(separator: "\n")
    let instructions = """
      You are classifying one conversation so that it is summarized with the \
      prompt written for its kind.

      Choose exactly one of these presets:

      \(menu)

      Answer with exactly two lines and nothing else:

      preset: <one of the names above, exactly as written>
      because: <one short sentence>


      """
    return LLMPrompt(stablePrefix: instructions, dynamicSuffix: excerpt(transcript))
  }

  /// The transcript as the classifier sees it: its head, bounded by
  /// ``maxTranscriptCharacters``, with the elision marked so the model knows
  /// it is reading an opening rather than a whole short call.
  static func excerpt(_ transcript: String) -> String {
    guard transcript.count > maxTranscriptCharacters else { return transcript }
    return String(transcript.prefix(maxTranscriptCharacters))
      + "\n\n…(transcript truncated; this is its opening)"
  }

  /// Reads a preset name and its reason out of whatever the model replied.
  ///
  /// Deliberately forgiving in one direction only: the answer is matched
  /// against the *configured* names, so anything this returns is a preset
  /// that exists. A `preset:` line is read when there is one; otherwise the
  /// whole reply is searched for a candidate name standing as its own word,
  /// which is what recovers the common "The preset is meeting." shape. A
  /// reply naming nothing configured returns `nil` for the caller to fall
  /// back on — guessing from a near-miss would file the note under a shape
  /// nobody asked for while looking like a clean classification in the log.
  static func parse(_ answer: String, candidates: [Candidate]) -> (name: String, reason: String?)? {
    let lines = answer.split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    let reason = lines.first { $0.lowercased().hasPrefix("because:") }
      .map { String($0.dropFirst("because:".count)).trimmingCharacters(in: .whitespaces) }
      .flatMap { $0.isEmpty ? nil : $0 }

    let claimed = lines.first { $0.lowercased().hasPrefix("preset:") }
      .map { String($0.dropFirst("preset:".count)) }
    if let claimed, let name = exactMatch(claimed, candidates: candidates) {
      return (name, reason)
    }
    guard let name = wordMatch(answer, candidates: candidates) else { return nil }
    return (name, reason)
  }

  /// A candidate whose name is the whole of `value`, once the decoration a
  /// model wraps a one-word answer in (quotes, backticks, bold markers,
  /// a trailing full stop) is stripped.
  private static func exactMatch(_ value: String, candidates: [Candidate]) -> String? {
    let stripped = value.trimmingCharacters(in: decoration).lowercased()
    return candidates.first { $0.name.lowercased() == stripped }?.name
  }

  /// The candidate that appears earliest in `answer` as a standalone word.
  /// Earliest, not longest or first-configured: a model that explains itself
  /// before answering still leads with the name it chose, and a `when`
  /// description quoted back later must not outrank it.
  private static func wordMatch(_ answer: String, candidates: [Candidate]) -> String? {
    let haystack = answer.lowercased()
    var best: (offset: Int, name: String)? = nil
    for candidate in candidates {
      var searchStart = haystack.startIndex
      while let found = haystack.range(
        of: candidate.name.lowercased(), range: searchStart..<haystack.endIndex)
      {
        let before =
          found.lowerBound == haystack.startIndex
          ? nil : haystack[haystack.index(before: found.lowerBound)]
        let after = found.upperBound == haystack.endIndex ? nil : haystack[found.upperBound]
        if !isWordCharacter(before) && !isWordCharacter(after) {
          let offset = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
          if best == nil || offset < best!.offset { best = (offset, candidate.name) }
          break
        }
        searchStart = found.upperBound
      }
    }
    return best?.name
  }

  private static func isWordCharacter(_ character: Character?) -> Bool {
    guard let character else { return false }
    return character.isLetter || character.isNumber
  }

  private static let decoration = CharacterSet(charactersIn: " \t\"'`*.·—-[]()")
}
