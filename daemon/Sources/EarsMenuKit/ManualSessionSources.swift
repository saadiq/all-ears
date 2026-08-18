import EarsCore

/// The source ids a menu-bar-started session declares.
///
/// A manual `session.start` records exactly the sources it names — the daemon
/// takes a manual session's list verbatim (`SessionRegistry.initialSources`)
/// and silently skips any id it holds no descriptor for — so the menu has to
/// name the real ones. It cannot ask the daemon: `subscribe`'s snapshot lists
/// live capture actors, and a daemon at idle has none (it builds them when a
/// session starts). So the list comes from the config layers `earsd` itself
/// resolves, which the menu bar app already loads.
///
/// Which entries count is ``CaptureSourceEntry``'s call — the same predicate
/// `earsd` resolves its own capture descriptors through. A narrower copy here
/// (reading only `id` and `enabled`, say) would name entries the daemon skips
/// for a config error — an unrecognised `class`, a `browser`/`device` class,
/// a malformed `app:` id — and a session naming only those starts, counts up,
/// and records nothing.
public enum ManualSessionSources {
  /// Every capturable `[[earsd.source]]` id in the resolved config, in
  /// declaration order. Empty when the config declares no capturable source —
  /// the caller reports that rather than starting a session that records
  /// nothing.
  public static func resolve(from config: ConfigValue) -> [SourceID] {
    guard case .table(let root) = config,
      case .table(let earsd)? = root["earsd"],
      case .array(let entries)? = earsd["source"]
    else { return [] }
    return CaptureSourceEntry.capturableIDs(in: entries)
  }
}

/// The post-processing chain a menu-bar-started session declares.
///
/// "Click Stop, get a summary" is this app's promise, so the app asks for the
/// chain explicitly at `session.start` rather than relying on the daemon
/// defaulting manual sessions into one — the daemon's default is deliberately
/// inert for non-browser triggers (``EarsCore/OnEndChainPolicy``), and
/// a CLI user's scripted capture should stay that way.
///
/// What it asks for is the operator's own `[earsd.sessions] on_end_stages`,
/// not a hardcoded chain: someone who set `["transcribe"]` to skip the LLM
/// stages, or `[]` to do their own post-processing, gets what they configured.
/// Names are passed through unvalidated — the daemon resolves and reports them
/// (`OnEndStage.resolveList`), and duplicating that vocabulary here would be a
/// second place to keep in sync.
public enum ManualSessionStages {
  public static func resolve(from config: ConfigValue) -> [String] {
    guard case .table(let root) = config,
      case .table(let earsd)? = root["earsd"],
      case .table(let sessions)? = earsd["sessions"],
      case .array(let entries)? = sessions["on_end_stages"]
    else { return [] }
    return entries.compactMap { entry in
      guard case .string(let name) = entry, !name.isEmpty else { return nil }
      return name
    }
  }
}
