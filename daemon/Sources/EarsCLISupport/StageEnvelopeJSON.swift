import Foundation

/// The one JSON printer every batch stage's `--json` result envelope goes
/// through (issue #63), so all three envelopes share the same wire shape
/// rules: a single line (no pretty-printing — the whole stdout document must
/// be exactly one JSON document, and the daemon's strict parse reads one
/// line), deterministic key order (`.sortedKeys`, so identical runs produce
/// identical bytes), and readable paths (`.withoutEscapingSlashes`).
///
/// Only the *printer* is shared. The envelope structs themselves are `Codable`
/// types owned by each tool (`TranscribeResultEnvelope`,
/// `CleanupResultEnvelope`, `SummarizeResultEnvelope`) — the cross-repo
/// contract is the checked-in JSON Schemas in `shared/stage-envelopes/`, not
/// a shared Swift type; the daemon grows its own decoder in the consumer
/// issue.
public enum StageEnvelopeJSON {
  /// Encodes `envelope` as one line of JSON, or `nil` if encoding fails.
  ///
  /// Encoding a flat struct of strings/bools/ints/finite doubles cannot fail
  /// in practice; if it ever does, the caller emits *nothing*, which both
  /// contracts treat as loud failure ("empty stdout ⇒ no result") — never a
  /// plausible-looking partial document.
  public static func encodeLine(_ envelope: some Encodable) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(envelope) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
