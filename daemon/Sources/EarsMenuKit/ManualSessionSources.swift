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
/// Deliberately narrower than `earsd/DaemonConfigResolution.resolveSource`,
/// which owns the full version: this reads the two fields a user actually
/// edits, `id` and `enabled`. An entry the daemon skips for a config error
/// (an unrecognised `class`, a malformed `app:` id) is one it already logged
/// at boot, and naming it here is no worse than `ears session start --source`
/// naming it.
public enum ManualSessionSources {
  /// Every enabled `[[earsd.source]]` id in the resolved config, in declaration
  /// order. Empty when the config declares no capturable source — the caller
  /// reports that rather than starting a session that records nothing.
  public static func resolve(from config: ConfigValue) -> [SourceID] {
    guard case .table(let root) = config,
      case .table(let earsd)? = root["earsd"],
      case .array(let entries)? = earsd["source"]
    else { return [] }
    return entries.compactMap { entry in
      guard case .table(let fields) = entry,
        case .string(let id)? = fields["id"], !id.isEmpty
      else { return nil }
      if case .bool(false)? = fields["enabled"] { return nil }
      return SourceID(id)
    }
  }
}
