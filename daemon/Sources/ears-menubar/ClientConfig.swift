import EarsConfig
import EarsCore
import EarsDataStore
import Foundation

struct ClientConfigError: Error, Sendable, CustomStringConvertible {
  var description: String
}

/// Where the daemon is and how to read its sessions back — the only config
/// this app reads. What a session records and runs comes from the daemon
/// itself (`status.configured`), never from here.
struct ClientConfig: Sendable {
  var socketPath: String
  var environment: SessionScanEnvironment

  /// The same layered resolution `ears` does, so the app dials the socket
  /// `ears` would.
  static func resolve() -> Result<ClientConfig, ClientConfigError> {
    let inputs = ConfigLoadInputs(
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    switch loadConfig(inputs) {
    case .failure(let error):
      return .failure(ClientConfigError(description: "config load failed: \(error)"))
    case .success(let loaded):
      let configured = string(loaded.value, "socket_path")
      let socketPath =
        configured.isEmpty
        ? DefaultSocketPath.resolve(dataRoot: string(loaded.value, "data_root")) : configured
      if let message = DefaultSocketPath.lengthError(forPath: socketPath) {
        return .failure(ClientConfigError(description: message))
      }
      return .success(
        ClientConfig(
          socketPath: socketPath, environment: SessionScanEnvironment.resolve(from: loaded.value)))
    }
  }

  private static func string(_ config: ConfigValue, _ key: String) -> String {
    guard case .table(let root) = config, case .string(let value)? = root[key] else { return "" }
    return value
  }
}
