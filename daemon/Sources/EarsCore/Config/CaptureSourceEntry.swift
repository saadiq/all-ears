/// One `[[earsd.source]]` config entry, reduced to the question every reader of
/// that table actually asks: *will `earsd` capture this?*
///
/// It lives here, in the pure core, because two callers need the same answer
/// and the second copy is where they drift: `earsd` builds its capture
/// descriptors from these entries (`DaemonConfigResolution`), and the menu bar
/// app names sources in the sessions it starts (`ManualSessionSources`). A
/// manual session records exactly the sources it names and the daemon silently
/// skips any id it holds no descriptor for, so a menu that named an entry the
/// daemon rejects would start a session that captures nothing while the menu
/// reports "● Recording".
///
/// Deliberately never throws: a malformed entry is skipped and reported, never
/// fatal — `docs/specs/capture-daemon.md`'s per-source policy ("logs an error
/// and disables just that source — never takes down the daemon"), applied at
/// config-resolution time rather than backend-start time.
public enum CaptureSourceEntry {
  /// What one entry resolves to. ``skipped(id:reason:)`` carries the reason
  /// verbatim so `earsd` can log per-entry at boot; `id` is `"?"` when the
  /// entry is malformed enough to have no usable id.
  public enum Resolution: Sendable, Equatable {
    case capturable(id: SourceID, sourceClass: SourceClass)
    case skipped(id: String, reason: String)
  }

  public static func resolve(_ entry: ConfigValue) -> Resolution {
    guard case .table(let fields) = entry else {
      return .skipped(id: "?", reason: "[[earsd.source]] entry is not a table; skipping")
    }
    guard case .string(let rawID)? = fields["id"], !rawID.isEmpty else {
      return .skipped(id: "?", reason: "[[earsd.source]] entry has no 'id'; skipping")
    }
    guard case .string(let rawClass)? = fields["class"] else {
      return .skipped(id: rawID, reason: "source '\(rawID)' has no 'class'")
    }
    guard let sourceClass = SourceClass(rawValue: rawClass) else {
      return .skipped(id: rawID, reason: "source '\(rawID)' has unrecognised class '\(rawClass)'")
    }
    if case .bool(false)? = fields["enabled"] {
      return .skipped(id: rawID, reason: "source '\(rawID)' is disabled in config")
    }
    switch sourceClass {
    case .mic:
      break
    case .system:
      guard rawID == "system" else {
        return .skipped(
          id: rawID, reason: "source '\(rawID)' has class 'system' but id must be exactly 'system'")
      }
    case .app:
      guard let detail = SourceID(rawID).detail, !detail.isEmpty else {
        return .skipped(
          id: rawID, reason: "source '\(rawID)' has class 'app' but id must be 'app:<bundle-id>'")
      }
    case .browser, .device:
      return .skipped(
        id: rawID, reason: "source '\(rawID)' has class '\(rawClass)', which is not yet supported")
    }
    return .capturable(id: SourceID(rawID), sourceClass: sourceClass)
  }

  /// Every capturable id in an `[[earsd.source]]` array, in declaration order.
  public static func capturableIDs(in entries: [ConfigValue]) -> [SourceID] {
    entries.compactMap { entry in
      guard case .capturable(let id, _) = resolve(entry) else { return nil }
      return id
    }
  }
}
