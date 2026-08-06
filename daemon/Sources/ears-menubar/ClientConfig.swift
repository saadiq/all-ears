import EarsConfig
import EarsCore
import Foundation

/// A resolved-config failure, wrapped so ``ClientConfig/resolve()`` can
/// return it through `Result`'s `Failure: Error` constraint while staying a
/// plain human-readable message — there's no richer taxonomy to preserve
/// here. Mirrors `ears/ControlClientRuntime.ConfigResolutionError` (that one
/// is internal to the `ears` target, hence the duplicate rather than a
/// shared import).
struct ConfigResolutionError: Error, CustomStringConvertible, Sendable {
  var description: String
}

/// Resolves the same config layers every tool honors: defaults → TOML →
/// EARS_* env. Mirrors ears' ControlClientRuntime (internal there).
struct ClientConfig: Sendable {
  var socketPath: String
  var dataRoot: String
  var outputRoot: String

  static func resolve() -> Result<ClientConfig, ConfigResolutionError> {
    let inputs = ConfigLoadInputs(
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    switch loadConfig(inputs) {
    case .failure(let error):
      return .failure(ConfigResolutionError(description: "config load failed: \(error)"))
    case .success(let loaded):
      let dataRoot = string(loaded.value, "data_root")
      let configured = string(loaded.value, "socket_path")
      let socketPath =
        configured.isEmpty ? DefaultSocketPath.resolve(dataRoot: dataRoot) : configured
      if let message = DefaultSocketPath.lengthError(forPath: socketPath) {
        return .failure(ConfigResolutionError(description: message))
      }
      return .success(
        ClientConfig(
          socketPath: socketPath, dataRoot: dataRoot,
          outputRoot: string(loaded.value, "output_root")))
    }
  }

  private static func string(_ value: ConfigValue, _ key: String) -> String {
    guard case .table(let table) = value, let entry = table[key],
      case .string(let text) = entry
    else { return "" }
    return text
  }
}
