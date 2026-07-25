import EarsCore

/// A malformed `--set`/`--set-string` argument. Carried so the caller can
/// reject the whole invocation with a precise, non-silent message naming every
/// bad entry, per `docs/configuration.md`'s "no silent fallback" rule, rather
/// than dropping an unparseable override on the floor.
public struct CLIOverrideError: Error, Sendable, Equatable {
  /// The raw arguments that didn't parse as `dotted.key=value` (no `=`, an
  /// empty key, or an empty path segment), in the order given.
  public var invalidArguments: [String]

  public init(invalidArguments: [String]) {
    self.invalidArguments = invalidArguments
  }
}

/// Builds the CLI `--set`/`--set-string` override layer: the generic,
/// highest-precedence escape hatch that lets any config key be overridden on
/// the command line without a dedicated flag per setting, mirroring the
/// `EARS_*` environment layer (`EnvironmentLayer.swift`) but on the CLI side.
/// Per `docs/configuration.md`'s layering model (defaults → file → env →
/// flags), this sits in the flags layer, so an override beats the config file,
/// the environment, and the built-in default for that key.
///
/// Each argument is `dotted.key=value`; the key is split on `.` into a nested
/// path and the value is coerced to bool/int/double when unambiguous (see
/// ``ConfigPathInsertion/coerce(_:)``). `stringOverrides` (`--set-string`)
/// skips coercion and stores the literal string, for values that must not be
/// typed (a version like `1.0`, a numeric id). The value is split on the
/// *first* `=` only, so a value may itself contain `=` (e.g.
/// `--set llm.command=llm -m gpt`). On a key collision a `--set-string` entry
/// wins over a `--set` entry, and within either list the last occurrence wins.
///
/// Returns `.failure` naming every malformed argument rather than silently
/// skipping it; the merged tree is still validated against the schema
/// afterwards by ``loadConfig(_:defaults:schema:)``, so an override with an
/// unknown key or wrong type for its slice is reported there.
public func configLayer(
  fromCLIOverrides overrides: [String], stringOverrides: [String] = []
) -> Result<ConfigValue, CLIOverrideError> {
  var root: [String: ConfigValue] = [:]
  var invalid: [String] = []

  func apply(_ arguments: [String], coerced: Bool) {
    for argument in arguments {
      guard let (path, rawValue) = parseAssignment(argument) else {
        invalid.append(argument)
        continue
      }
      let value = coerced ? ConfigPathInsertion.coerce(rawValue) : .string(rawValue)
      ConfigPathInsertion.insert(value, at: path, into: &root)
    }
  }

  // Typed `--set` first, then `--set-string` on top, so a literal-string
  // override wins over a coerced one for the same key.
  apply(overrides, coerced: true)
  apply(stringOverrides, coerced: false)

  guard invalid.isEmpty else {
    return .failure(CLIOverrideError(invalidArguments: invalid))
  }
  return .success(.table(root))
}

/// Splits `dotted.key=value` into its path components and raw value, or `nil`
/// if it has no `=`, an empty key, or any empty path segment (e.g. `a..b`).
private func parseAssignment(_ argument: String) -> (path: [String], value: String)? {
  guard let equalsIndex = argument.firstIndex(of: "=") else { return nil }
  let key = String(argument[argument.startIndex..<equalsIndex])
  let value = String(argument[argument.index(after: equalsIndex)...])

  guard !key.isEmpty else { return nil }
  let path = key.components(separatedBy: ".")
  guard !path.contains(where: \.isEmpty) else { return nil }
  return (path, value)
}
