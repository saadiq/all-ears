/// Renders a ``ConfigSchema`` and its built-in ``defaults`` into a
/// human-readable reference listing — every key with its dotted path, type,
/// default value, and (when declared) one-line description. This is the single
/// renderer behind `ears config describe`: rather than a hand-maintained list
/// of settings that drifts from the code, discoverability is a projection of
/// the same schema the loader validates against.
///
/// Output groups nested tables under a `[path]` header and array-of-tables
/// under a `[[path]]` header, mirroring the TOML the settings live in, so what
/// a user reads here matches what they'd write in `config.toml`. A leaf is one
/// line — `path : type = default` — with its description, if any, indented
/// beneath it. Keys are emitted in sorted order at every level, so the output
/// is deterministic.
public func describeConfig(schema: ConfigSchema, defaults: ConfigValue) -> String {
  var lines: [String] = []
  appendDescribeLines(
    schema: schema, defaults: defaults, pathPrefix: [], displayPrefix: "", into: &lines)
  return lines.joined(separator: "\n")
}

private func appendDescribeLines(
  schema: ConfigSchema,
  defaults: ConfigValue,
  pathPrefix: [String],
  displayPrefix: String,
  into lines: inout [String]
) {
  let sortedKeys = schema.fields.keys.sorted()

  // Leaf keys first, then nested groups — so bare keys precede any `[table]`
  // header at this level, matching TOML's own ordering rule and keeping a
  // group's own keys visually attached to its header.
  func isGroup(_ field: ConfigSchema.Field) -> Bool {
    (field.type == .table && field.children != nil) || field.elementSchema != nil
  }

  for key in sortedKeys where !isGroup(schema.fields[key]!) {
    let field = schema.fields[key]!
    let display = displayPrefix + key
    var line = "\(display) : \(field.type.rawValue)"
    if let childDefault = lookupConfigValue(defaults, at: [key]),
      let rendered = renderScalarDefault(childDefault)
    {
      line += " = \(rendered)"
    }
    lines.append(line)
    if let description = field.description {
      lines.append("    \(description)")
    }
  }

  for key in sortedKeys where isGroup(schema.fields[key]!) {
    let field = schema.fields[key]!
    let path = pathPrefix + [key]
    let display = displayPrefix + key
    let childDefaults = lookupConfigValue(defaults, at: [key])

    if let elementSchema = field.elementSchema {
      lines.append("[[\(display)]]" + descriptionSuffix(field))
      // Array elements have no per-element default to show; list the element
      // fields with a `path[].field` display so they're identifiable.
      appendDescribeLines(
        schema: elementSchema, defaults: .table([:]),
        pathPrefix: path, displayPrefix: display + "[].", into: &lines)
    } else if let children = field.children {
      lines.append("[\(display)]" + descriptionSuffix(field))
      appendDescribeLines(
        schema: children, defaults: childDefaults ?? .table([:]),
        pathPrefix: path, displayPrefix: display + ".", into: &lines)
    }
  }
}

/// A trailing `  — <description>` for a group header, or empty when the group
/// has no declared description.
private func descriptionSuffix(_ field: ConfigSchema.Field) -> String {
  guard let description = field.description else { return "" }
  return "  — \(description)"
}

/// Renders a scalar default for the listing. Arrays render as `[…]` with their
/// element count so an empty vs. populated default list is distinguishable
/// without dumping every element; a table has no scalar default to show.
private func renderScalarDefault(_ value: ConfigValue) -> String? {
  switch value {
  case .string(let string): return "\"\(string)\""
  case .int(let int): return String(int)
  case .bool(let bool): return String(bool)
  case .double(let double): return String(double)
  case .array(let elements): return elements.isEmpty ? "[]" : "[…\(elements.count)]"
  case .table: return nil
  }
}

/// Reads the child value at a single-key step of a table, or `nil` when the
/// value isn't a table or the key is absent.
private func lookupConfigValue(_ value: ConfigValue, at path: [String]) -> ConfigValue? {
  var current = value
  for key in path {
    guard case .table(let table) = current, let next = table[key] else { return nil }
    current = next
  }
  return current
}
