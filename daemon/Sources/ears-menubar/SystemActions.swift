import AppKit
import Foundation

enum SystemActions {
  static let daemonLabel = "net.tomelliot.ears.earsd"

  /// `launchctl kickstart -k` — same restart the Makefile documents.
  static func restartDaemon() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(daemonLabel)"]
    try? process.run()
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

  static func openFolder(_ path: String) {
    guard !path.isEmpty else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }
}
