import EarsCore

/// Pulls typed scalar fields out of a `ConfigValue.table`, shared by
/// ``SourceDescriptorTOML`` and ``SessionDescriptorTOML``'s decoders so
/// neither repeats the same "missing or wrong kind" boilerplate.
struct TOMLFieldReader {
  let table: [String: ConfigValue]

  func string(_ key: String) throws(DescriptorTOMLError) -> String {
    guard case .string(let value)? = table[key] else {
      throw .missingField(key)
    }
    return value
  }

  func int(_ key: String) throws(DescriptorTOMLError) -> Int {
    guard case .int(let value)? = table[key] else {
      throw .missingField(key)
    }
    return value
  }

  func bool(_ key: String) throws(DescriptorTOMLError) -> Bool {
    guard case .bool(let value)? = table[key] else {
      throw .missingField(key)
    }
    return value
  }

  func array(_ key: String) throws(DescriptorTOMLError) -> [ConfigValue] {
    guard case .array(let value)? = table[key] else {
      throw .missingField(key)
    }
    return value
  }

  /// An optional array field, where **an empty array is a value, not the
  /// absent sentinel**: only a missing key decodes to `nil`. The "empty =>
  /// absent" convention below cannot be used for `session.on_end_stages`,
  /// whose whole point is that `[]` ("run no stages") differs from undeclared
  /// ("apply the daemon's default").
  func optionalArray(_ key: String) throws(DescriptorTOMLError) -> [ConfigValue]? {
    guard let entry = table[key] else { return nil }
    guard case .array(let value) = entry else { throw .invalidField(key) }
    return value
  }

  /// An optional string field: an empty string or an absent key both decode
  /// to `nil`, matching the "empty => absent" sentinel convention this
  /// codebase already uses for optional path-like fields (`socket_path`,
  /// `log.file`).
  func optionalString(_ key: String) -> String? {
    guard case .string(let value)? = table[key], !value.isEmpty else {
      return nil
    }
    return value
  }
}
