/// The kind of a ``ConfigValue``, independent of its payload — used to describe
/// expected-vs-actual types in validation error messages.
public enum ConfigValueKind: String, Sendable, Hashable, CaseIterable {
  case string
  case int
  case bool
  case double
  case array
  case table

  /// Whether a value of this kind is acceptable where `expected` is
  /// declared. Exact match, with one widening: an integer satisfies a
  /// floating-point field, since TOML's `5` and `5.0` are different literals
  /// and only one of them would otherwise parse.
  public func satisfies(_ expected: ConfigValueKind) -> Bool {
    self == expected || (expected == .double && self == .int)
  }

  /// A human-readable name for error messages, e.g. `"expected string, got
  /// integer"` — matches the phrasing in `docs/configuration.md`'s validation
  /// convention.
  public var description: String {
    switch self {
    case .int: "integer"
    case .double: "floating-point number"
    case .string, .bool, .array, .table: rawValue
    }
  }
}
