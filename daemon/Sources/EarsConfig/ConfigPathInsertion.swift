import EarsCore

/// Shared primitives for building a config layer from flat, stringly-typed
/// key/value sources — the `EARS_*` environment (`EnvironmentLayer.swift`) and
/// the `--set`/`--set-string` CLI overrides (`CLIOverridesLayer.swift`). Both
/// turn a dotted key path plus a raw string value into a nested
/// ``ConfigValue`` tree, and both coerce unambiguous scalars to their typed
/// form, so factoring the two operations here keeps that behaviour identical
/// across the env and CLI layers rather than reimplemented (and liable to
/// drift) in each.
enum ConfigPathInsertion {
  /// Inserts `value` at `path` into `table`, creating intermediate tables as
  /// needed and merging into an existing table at a shared prefix so sibling
  /// keys survive. A non-table value already sitting at an intermediate path
  /// segment is replaced by a fresh table — the deeper key wins, matching how
  /// the layer merge treats a scalar/table type change.
  static func insert(
    _ value: ConfigValue, at path: [String], into table: inout [String: ConfigValue]
  ) {
    guard let first = path.first else { return }

    guard path.count > 1 else {
      table[first] = value
      return
    }

    var nested: [String: ConfigValue] = [:]
    if case .table(let existing)? = table[first] {
      nested = existing
    }
    insert(value, at: Array(path.dropFirst()), into: &nested)
    table[first] = .table(nested)
  }

  /// Coerces a raw string to a typed ``ConfigValue`` when it unambiguously
  /// parses as a bool, integer, or floating-point number, else leaves it a
  /// string. Both the environment and the CLI `--set` flag are string-valued
  /// at the source, so without this `--set log.oslog=false` would merge in as
  /// `.string("false")` and fail the schema's `Bool` check for `log.oslog`
  /// even though the intent is unambiguous. `--set-string` bypasses this to
  /// force a literal string (e.g. a version like `1.0`, or a numeric id).
  static func coerce(_ rawValue: String) -> ConfigValue {
    if let boolValue = boolLiteral(rawValue) {
      return .bool(boolValue)
    }
    if let intValue = Int(rawValue) {
      return .int(intValue)
    }
    if let doubleValue = Double(rawValue) {
      return .double(doubleValue)
    }
    return .string(rawValue)
  }

  private static func boolLiteral(_ rawValue: String) -> Bool? {
    switch rawValue.lowercased() {
    case "true": return true
    case "false": return false
    default: return nil
    }
  }
}
