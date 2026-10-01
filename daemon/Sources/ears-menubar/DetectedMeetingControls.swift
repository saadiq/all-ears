import EarsCore
import EarsMenuKit

/// Starting a detected meeting, as control calls. Returns why it failed, or
/// `nil`, like ``SessionControls``: a start that silently does nothing
/// leaves the user believing a meeting is being recorded when it is not.
struct DetectedMeetingControls: Sendable {
  let connection: DaemonConnection

  /// Asks the daemon what it captures, then starts the meeting's app source
  /// beside `mic` — see ``DetectedSessionStart``.
  func start(source: SourceID, episode: String) async -> String? {
    guard let status = await connection.status() else { return "not connected to earsd" }
    switch DetectedSessionStart.params(from: status, source: source, episode: episode) {
    case .failure(let refusal):
      return refusal.description
    case .success(let params):
      switch await connection.startSession(params) {
      case .failure(let error): return error.message
      case .success: return nil
      }
    }
  }
}
