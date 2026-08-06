import EarsConfig
import EarsCore
import EarsMenuKit
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
///
/// Loaded against `earsd`'s own schema and defaults rather than Phase 0's:
/// starting a session means naming the sources the daemon captures, so the
/// menu needs the `[[earsd.source]]` slice — including its built-in default
/// (one enabled `mic`), which a zero-config install never spells out.
struct ClientConfig: Sendable {
  var socketPath: String
  var dataRoot: String
  var outputRoot: String
  /// The sources a manually started session declares — see
  /// ``ManualSessionSources``.
  var sources: [SourceID]
  /// The on-end chain a manually started session declares — see
  /// ``ManualSessionStages``.
  var onEndStages: [String]

  static func resolve() -> Result<ClientConfig, ConfigResolutionError> {
    let inputs = ConfigLoadInputs(
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    switch loadConfig(
      inputs, defaults: EarsdConfigSchema.effectiveDefaults,
      schema: EarsdConfigSchema.effectiveSchema)
    {
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
          outputRoot: string(loaded.value, "output_root"),
          sources: ManualSessionSources.resolve(from: loaded.value),
          onEndStages: ManualSessionStages.resolve(from: loaded.value)))
    }
  }

  private static func string(_ value: ConfigValue, _ key: String) -> String {
    guard case .table(let table) = value, let entry = table[key],
      case .string(let text) = entry
    else { return "" }
    return text
  }
}
