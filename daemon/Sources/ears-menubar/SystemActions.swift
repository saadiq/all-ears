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

  static func openFolder(_ path: String) {
    guard !path.isEmpty else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }
}
