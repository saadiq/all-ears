import Foundation

/// When a transcript carries too little speech to be worth spending an LLM
/// stage on — the shared definition of "empty" behind the daemon's on-end
/// chain gate and `ears session show`'s skipped rows.
///
/// A session that captured only background audio still produces a valid
/// transcript: the 2026-08-20 `c08595c8` session ran 605 seconds and rendered
/// one word (`Yeah.`) over 0.556s of speech. Run through `cleanup` and
/// `summarize`, that transcript became a published note speculating about
/// whether the meeting had happened at all, written over an unrelated daily
/// note. The measurements that would have stopped it were already in the
/// transcript's own frontmatter (``TranscriptFrontmatter/wordCount`` and
/// ``TranscriptFrontmatter/speechSeconds``); this is the predicate that reads
/// them.
///
/// A transcript is empty when *either* measurement falls below its threshold —
/// a long recording of near-silence and a four-second session both qualify,
/// for different reasons. Either half is disabled by setting its threshold to
/// `0`, since no transcript has a negative word count or a negative speech
/// duration; setting both to `0` restores unconditional running of the whole
/// chain.
public struct TranscriptEmptinessPolicy: Sendable, Hashable {
  /// `[earsd.sessions] min_words`: a transcript with fewer words than this is
  /// empty. `0` disables the word half of the test.
  public var minWords: Int
  /// `[earsd.sessions] min_speech_seconds`: a transcript with less detected
  /// speech than this is empty. `0` disables the speech half of the test.
  public var minSpeechSeconds: Double

  public init(minWords: Int, minSpeechSeconds: Double) {
    self.minWords = minWords
    self.minSpeechSeconds = minSpeechSeconds
  }

  /// The shipped thresholds: low enough that a genuinely brief exchange still
  /// runs the full chain, high enough to catch both of the sessions that
  /// prompted the gate (0 words / 0s, and 1 word / 0.556s).
  public static let defaults = TranscriptEmptinessPolicy(minWords: 10, minSpeechSeconds: 5)

  /// Whether either half of the test is live. `false` means every transcript
  /// reads as substantive, which is the pre-gate behaviour.
  public var isEnabled: Bool { minWords > 0 || minSpeechSeconds > 0 }

  /// Judges one transcript's measurements against these thresholds.
  public func verdict(wordCount: Int, speechSeconds: Double) -> TranscriptEmptinessVerdict {
    TranscriptEmptinessVerdict(
      isEmpty: wordCount < minWords || speechSeconds < minSpeechSeconds,
      wordCount: wordCount,
      speechSeconds: speechSeconds,
      policy: self)
  }

  /// ``verdict(wordCount:speechSeconds:)`` read straight off a parsed
  /// transcript's frontmatter.
  public func verdict(frontmatter: TranscriptFrontmatter) -> TranscriptEmptinessVerdict {
    verdict(wordCount: frontmatter.wordCount, speechSeconds: frontmatter.speechSeconds)
  }
}

/// One transcript's emptiness judgement, carrying the numbers that produced it
/// so a caller can log *why* it skipped without re-deriving anything.
public struct TranscriptEmptinessVerdict: Sendable, Hashable {
  public var isEmpty: Bool
  public var wordCount: Int
  public var speechSeconds: Double
  public var policy: TranscriptEmptinessPolicy

  /// The measurements against the thresholds, for the daemon log and the
  /// `ears session show` detail — e.g.
  /// `1 word, 0.6s speech; thresholds 10 words / 5.0s`.
  public var summary: String {
    "\(wordCount) word\(wordCount == 1 ? "" : "s"), \(Self.seconds(speechSeconds))s speech; "
      + "thresholds \(policy.minWords) word\(policy.minWords == 1 ? "" : "s") "
      + "/ \(Self.seconds(policy.minSpeechSeconds))s"
  }

  /// One decimal place, so `0.556` reads as `0.6` and a threshold of `5`
  /// reads as `5.0` — the numbers are evidence for a decision, not a
  /// measurement anyone reuses.
  private static func seconds(_ value: Double) -> String {
    guard value.isFinite else { return "0.0" }
    return String(format: "%.1f", value)
  }
}
