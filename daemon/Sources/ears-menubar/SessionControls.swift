import EarsCore
import EarsMenuKit

/// The session verbs, as control calls. Each returns why it failed, or `nil`:
/// the caller surfaces every failure, because a verb that silently does
/// nothing leaves the user believing a recording stopped when it did not.
struct SessionControls: Sendable {
  let connection: DaemonConnection

  /// Asks the daemon what it is configured to record, then starts exactly
  /// that — see ``StartRecording``.
  func startRecording() async -> String? {
    guard let status = await connection.status() else { return "not connected to earsd" }
    switch StartRecording.params(from: status) {
    case .failure(let refusal): return refusal.description
    case .success(let params): return await connection.perform(.sessionStart(params))?.message
    }
  }

  func pause(_ session: String) async -> String? {
    await connection.perform(.sessionPause(session: session))?.message
  }

  func resume(_ session: String) async -> String? {
    await connection.perform(.sessionResume(session: session))?.message
  }

  func end(_ session: String) async -> String? {
    await connection.perform(.sessionEnd(session: session))?.message
  }

  func rename(_ session: String, to title: String) async -> String? {
    await connection.perform(.sessionRename(SessionRenameParams(session: session, title: title)))?
      .message
  }
}
