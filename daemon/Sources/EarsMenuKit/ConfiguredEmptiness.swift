import EarsCore

/// The empty-transcript thresholds the daemon gates its on-end chain on, read
/// from the config layers the menu already loads.
///
/// The menu needs them for the same reason it needs ``ConfiguredOnEndChain``:
/// to say what a recent session's *outcome* is. A session the daemon stopped
/// after transcribe has its transcript and will never have a note, so without
/// these the menu reports "transcribed, no note" against a chain that finished
/// exactly as designed — a gap that is not one, and one that never resolves.
///
/// Unlike the chain, absence carries no meaning here: an unset threshold is
/// the shipped default, which is what the daemon does with it
/// (`DaemonConfigResolution`).
public enum ConfiguredEmptiness {
  public static func resolve(from config: ConfigValue) -> TranscriptEmptinessPolicy {
    var policy = TranscriptEmptinessPolicy.defaults
    guard case .table(let root) = config,
      case .table(let earsd)? = root["earsd"],
      case .table(let sessions)? = earsd["sessions"]
    else { return policy }

    if case .int(let words)? = sessions["min_words"] {
      policy.minWords = words
    }
    // `.int` as well as `.double`: TOML's `5` and `5.0` are different
    // literals, and the schema accepts either (`ConfigValueKind.satisfies`).
    switch sessions["min_speech_seconds"] {
    case .double(let seconds)?: policy.minSpeechSeconds = seconds
    case .int(let seconds)?: policy.minSpeechSeconds = Double(seconds)
    default: break
    }
    return policy
  }
}
