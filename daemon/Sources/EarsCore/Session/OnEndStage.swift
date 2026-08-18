/// One stage of the on-end pipeline, in chain order. The raw values are the
/// config vocabulary (`[earsd.sessions] on_end_stages`) *and* the spawned
/// binary names.
public enum OnEndStage: String, Sendable, Hashable, CaseIterable {
  case transcribe
  case cleanup
  case summarize

  /// Resolves the raw `on_end_stages` config list into a valid chain, with a
  /// human-readable problem per entry dropped. Pure and lenient, matching the
  /// per-source config policy ("skipped and reported, never takes down the
  /// daemon"):
  ///
  /// - Unknown stage names are dropped with a problem.
  /// - `cleanup`/`summarize` without `transcribe` are dropped with a problem —
  ///   the LLM stages consume the transcribe stage's output, so a chain
  ///   without it has nothing to run on.
  /// - Duplicates collapse; config order is irrelevant. The result is always
  ///   in canonical chain order (`allCases`).
  public static func resolveList(_ raw: [String]) -> (stages: [OnEndStage], problems: [String]) {
    var problems: [String] = []
    var requested = Set<OnEndStage>()
    for name in raw {
      guard let stage = OnEndStage(rawValue: name) else {
        problems.append(
          "unknown on_end_stages entry '\(name)' "
            + "(valid: \(allCases.map(\.rawValue).joined(separator: ", ")))")
        continue
      }
      requested.insert(stage)
    }
    if !requested.contains(.transcribe) && !requested.isEmpty {
      let dropped = allCases.filter { requested.contains($0) }.map(\.rawValue)
      problems.append(
        "on_end_stages \(dropped) require the transcribe stage; dropping the on-end chain")
      requested = []
    }
    return (allCases.filter { requested.contains($0) }, problems)
  }
}
