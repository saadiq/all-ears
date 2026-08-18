import EarsCore

/// The on-end chain the daemon would run for a session that inherits one,
/// read from the config layers the menu already loads.
///
/// The menu needs it to say what a recent session's *outcome* is: a session
/// with no summary is only waiting on one if a summarize stage was ever going
/// to run. Without the chain, "no note yet" and "this machine publishes no
/// notes" look identical, and the menu would keep reporting a gap that is not
/// one.
///
/// Absence carries meaning here, which is why the raw list travels as an
/// optional through to ``EarsCore/OnEndChainPolicy/configured(fromRaw:)`` —
/// see there for why an unset key and `[]` are different answers.
public enum ConfiguredOnEndChain {
  public static func resolve(from config: ConfigValue) -> [OnEndStage] {
    OnEndChainPolicy.configured(fromRaw: rawStages(config))
  }

  private static func rawStages(_ config: ConfigValue) -> [String]? {
    guard case .table(let root) = config,
      case .table(let earsd)? = root["earsd"],
      case .table(let sessions)? = earsd["sessions"],
      case .array(let entries)? = sessions["on_end_stages"]
    else { return nil }
    return entries.compactMap { entry in
      guard case .string(let name) = entry else { return nil }
      return name
    }
  }
}
