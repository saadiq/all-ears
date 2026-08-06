import AppKit
import Foundation

enum SystemActions {
  static let daemonLabel = "net.tomelliot.ears.earsd"

  /// `launchctl kickstart -k` — same restart the Makefile documents.
  ///
  /// - Returns: `nil` on success, else why the restart did not happen. The
  ///   caller bounces the socket either way, so a discarded failure here
  ///   showed the user the menu getting *worse* after a repair action — down
  ///   to "⚠ Daemon not running" — with nothing saying the restart never ran.
  ///   The common case is a LaunchAgent that was never loaded (a `swift build`
  ///   install rather than `make install`), where kickstart exits non-zero
  ///   with "Could not find service".
  static func restartDaemon() async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(daemonLabel)"]
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = Pipe()
    return await withCheckedContinuation { continuation in
      // Set the handler before `run()`, so a child that exits immediately
      // cannot leave the continuation hanging.
      process.terminationHandler = { finished in
        guard finished.terminationStatus != 0 else {
          continuation.resume(returning: nil)
          return
        }
        let captured = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
        let detail = String(decoding: captured, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.resume(
          returning: "launchctl kickstart failed (exit \(finished.terminationStatus))"
            + (detail.isEmpty ? "" : ": \(detail)"))
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(returning: "could not run launchctl: \(error.localizedDescription)")
      }
    }
  }

  static func openLogs() {
    openFolder(NSHomeDirectory() + "/Library/Logs/ears")
  }

  /// The Notifications pane, where a denied grant is the only thing that can
  /// turn results back on — the prompt is one-shot, so the app cannot re-ask.
  /// The identifier is the System Settings *extension* bundle id used since
  /// Ventura, not the old `com.apple.preference.notifications` pane, which no
  /// longer resolves on the macOS 15 floor this app targets.
  static func openNotificationSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    else { return }
    NSWorkspace.shared.open(url)
  }

  /// The Login Items pane, where a `.requiresApproval` registration is
  /// finished. Same System Settings *extension* identifier scheme as
  /// ``openNotificationSettings()``.
  static func openLoginItemsSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    else { return }
    NSWorkspace.shared.open(url)
  }

  static func openFolder(_ path: String) {
    guard !path.isEmpty else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }
}
