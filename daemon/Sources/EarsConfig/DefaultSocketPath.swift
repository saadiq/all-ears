import Darwin

/// The default control-socket path when `socket_path` is left at its empty
/// "derive it" sentinel (`docs/configuration.md`: `socket_path = ""   # empty
/// => <data_root>/runtime/earsd.sock`).
///
/// Mirrors ``DefaultLogFilePath`` (`EarsLogging`)'s "empty sentinel -> derive
/// from `data_root`" shape, but lives here rather than there since the socket
/// path is a shared `earsd`/`ears` concern, not a logging one: `earsd` binds
/// here, `ears` connects here, and both resolve it from the same loaded
/// config so they always agree without either hard-coding the other's
/// default.
public enum DefaultSocketPath {
  /// - Parameter dataRoot: The resolved `data_root` config value (already
  ///   `~`-expanded).
  public static func resolve(dataRoot: String) -> String {
    let base = dataRoot.hasSuffix("/") ? String(dataRoot.dropLast()) : dataRoot
    return "\(base)/runtime/earsd.sock"
  }

  /// Usable UTF-8 bytes in `sockaddr_un.sun_path` (104 on Darwin) — computed
  /// from the OS header here as in `EarsIPC.UnixSocketPathLimit` (that module
  /// sits below this one, so the constant is derived twice from the same
  /// header rather than shared; it cannot drift). Measured empirically for
  /// issue #74: the full array is usable with no NUL terminator (`sun_len`
  /// -style addressing); one byte more and the Network framework traps on
  /// connect and silently fails to create the socket file on bind.
  public static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

  /// The config-layer length check every runtime applies to its resolved
  /// socket path before the transport ever sees it (issue #74): `nil` when
  /// `path` fits in `sun_path`, otherwise a user-facing message naming the
  /// path, its byte length, the cap, and which config values to change.
  public static func lengthError(forPath path: String) -> String? {
    let byteCount = path.utf8.count
    guard byteCount > maxPathBytes else { return nil }
    return "socket path too long for sun_path (\(byteCount) bytes, max \(maxPathBytes)): "
      + "\(path) — set socket_path to a shorter path or move data_root"
  }
}
