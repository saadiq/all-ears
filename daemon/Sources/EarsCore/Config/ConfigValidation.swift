/// Validates a merged config tree against a declared ``ConfigSchema``, per
/// `docs/configuration.md`'s "no silent fallback" rule: every unknown key and
/// every type mismatch is reported, with its full key path and reason, rather
/// than one being picked and the rest ignored. Returns an empty array when the
/// tree is valid. Errors are sorted by key path for deterministic output.
///
/// Keys outside `schema.fields` that are listed in `schema.passthroughKeys`
/// (whole not-yet-implemented sections such as `[earsd]`) are left untouched:
/// neither type-checked nor rejected as unknown.
///
/// A field declaring `elementSchema` (an array-of-tables field, e.g.
/// `[[earsd.source]]`) validates each element of the array against that
/// nested schema, reporting errors with an indexed path segment
/// (`earsd.source[1].device_uid`) so a precise element is identifiable.
/// An element that isn't itself a table is reported as a type mismatch at the
/// indexed path.
///
/// A `.double` field also accepts an integer: TOML distinguishes `5` from
/// `5.0` and never widens one to the other, so requiring the decimal point
/// would turn `min_speech_seconds = 5` into a boot-time config error for no
/// reason anyone could act on. No other pair of kinds is interchangeable.
///
/// A field declaring `pathTemplateTokens` (a ``PathTemplate``-valued string,
/// e.g. `[cleanup] output`) has every `{token}` it names checked against that
/// set, so a mistyped token is a reported config error rather than a literal
/// brace in a written filename.
public func validateConfig(_ value: ConfigValue, against schema: ConfigSchema) -> [ConfigError] {
  guard case .table(let table) = value else {
    return []
  }
  let errors = validateTable(table, against: schema, keyPath: [])
  return errors.sorted { $0.keyPathString < $1.keyPathString }
}

private func validateTable(
  _ table: [String: ConfigValue],
  against schema: ConfigSchema,
  keyPath: [String]
) -> [ConfigError] {
  var errors: [ConfigError] = []

  for (key, value) in table {
    let path = keyPath + [key]

    guard let field = schema.fields[key] else {
      if !schema.passthroughKeys.contains(key) {
        errors.append(ConfigError(keyPath: path, reason: .unknownKey))
      }
      continue
    }

    guard value.kind.satisfies(field.type) else {
      errors.append(
        ConfigError(keyPath: path, reason: .typeMismatch(expected: field.type, got: value.kind))
      )
      continue
    }

    if let allowedTokens = field.pathTemplateTokens, case .string(let template) = value {
      for token in PathTemplate.unknownTokens(in: template, allowing: allowedTokens) {
        errors.append(
          ConfigError(
            keyPath: path,
            reason: .invalidValue("unknown path-template token '{\(token)}'"))
        )
      }
    }

    if let children = field.children, case .table(let nested) = value {
      errors.append(contentsOf: validateTable(nested, against: children, keyPath: path))
    }

    if let elementSchema = field.elementSchema, case .array(let elements) = value {
      errors.append(
        contentsOf: validateElements(elements, against: elementSchema, key: key, keyPath: keyPath)
      )
    }
  }

  return errors
}

/// Validates each element of an array-of-tables field, per `field.elementSchema`.
private func validateElements(
  _ elements: [ConfigValue],
  against elementSchema: ConfigSchema,
  key: String,
  keyPath: [String]
) -> [ConfigError] {
  var errors: [ConfigError] = []

  for (index, element) in elements.enumerated() {
    let elementPath = keyPath + ["\(key)[\(index)]"]

    guard case .table(let elementTable) = element else {
      errors.append(
        ConfigError(
          keyPath: elementPath, reason: .typeMismatch(expected: .table, got: element.kind))
      )
      continue
    }

    errors.append(
      contentsOf: validateTable(elementTable, against: elementSchema, keyPath: elementPath))
  }

  return errors
}
