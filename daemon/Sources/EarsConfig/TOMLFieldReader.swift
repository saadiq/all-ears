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

  /// An optional array field: an absent key decodes to `[]`.
  ///
  /// The tolerant counterpart to ``array(_:)``, for arrays added to a schema
  /// after files were already written under it. A `session.toml` from before
  /// `speaker`/`warnings` existed is a valid record of what that session knew,
  /// not a corrupt one, and refusing to load it would strand every session
  /// captured before the upgrade.
  func optionalArray(_ key: String) -> [ConfigValue] {
    guard case .array(let value)? = table[key] else { return [] }
    return value
  }

  /// An optional integer field: an absent key (or one of the wrong kind)
  /// decodes to 0 — for counters added to a schema after files were already
  /// written under it. `reconciler_version` is the motivating case: version 0
  /// means "before reconciliation was versioned", which is exactly what an
  /// old file is.
  func optionalInt(_ key: String) -> Int {
    guard case .int(let value)? = table[key] else { return 0 }
    return value
  }

  /// An optional boolean field: an absent key (or one of the wrong kind)
  /// decodes to `false`.
  func optionalBool(_ key: String) -> Bool {
    guard case .bool(let value)? = table[key] else { return false }
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
