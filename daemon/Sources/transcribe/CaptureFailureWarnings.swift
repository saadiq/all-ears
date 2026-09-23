import EarsDataStore
import Foundation

extension TranscribePipeline {
  /// One frontmatter warning per distinct `capture_failed` event in the
  /// session's `events.jsonl` — a source whose capture failed to start, or
  /// died mid-call. Without it, a lost source reads in the transcript as a
  /// participant who never spoke. A run with no session has no timeline and
  /// no warnings.
  static func captureFailureWarnings(sessionID: String?, dataRoot: URL) -> [String] {
    guard let sessionID else { return [] }
    var warnings: [String] = []
    for entry in SessionEventLog.readAll(dataRoot: dataRoot, sessionID: sessionID)
    where entry.event == "capture_failed" {
      let reason = entry.reason.map { " (\($0))" } ?? ""
      let warning =
        "source '\(entry.source ?? "unknown")' failed to capture\(reason); "
        + "its audio is missing from this transcript"
      if !warnings.contains(warning) { warnings.append(warning) }
    }
    return warnings
  }
}
