import AppKit
import EarsMenuKit
import ServiceManagement
import SwiftUI

struct MenuContentView: View {
  let model: AppModel

  var body: some View {
    Text(model.content.header)
    if let error = model.actionError {
      Text("⚠ \(error)")
    }
    if let warning = model.notifications.menuLine {
      Menu(warning) {
        Button("Open Notification Settings") { SystemActions.openNotificationSettings() }
      }
    }
    ForEach(model.content.verbs, id: \.self) { verb in
      Button(label(for: verb)) { model.perform(verb) }
    }
    if !model.content.pipeline.isEmpty {
      Divider()
      ForEach(model.content.pipeline) { line in
        if line.dismissible {
          Menu(line.text) {
            Button("Dismiss") { model.dismiss(jobID: line.id) }
          }
        } else {
          Text(line.text)
        }
      }
    }
    Divider()
    Menu("Recent Sessions") {
      if model.recents.isEmpty {
        Text("No ended sessions")
      }
      ForEach(model.recents) { item in
        // The warning marker rides the row, not just the notification: a
        // user who denied the notification grant would otherwise never learn
        // that a name in the transcript may be the wrong person's.
        Menu(item.session.warnings.isEmpty ? item.session.title : "⚠ \(item.session.title)") {
          ForEach(item.session.warnings, id: \.self) { warning in
            Text(warning)
          }
          Button("Open Summary") { open(item.summaries.first) }
            .disabled(item.summaries.isEmpty)
          Button("Open Transcript") { open(item.clean ?? item.transcript) }
            .disabled(item.clean == nil && item.transcript == nil)
          // Reveals the published tier first — the cleaned transcript and
          // the summaries are the files a user files and syncs. The raw
          // transcript is an intermediate in the hidden data store, so it
          // is the last resort, not the first.
          Button("Show in Finder") { reveal(item.clean ?? item.summaries.first ?? item.transcript) }
            .disabled(item.clean == nil && item.summaries.isEmpty && item.transcript == nil)
        }
      }
    }
    Divider()
    Menu("Daemon") {
      Text(model.daemonLine)
      Button("Restart Daemon") { model.restartDaemon() }
      Button("Open Logs") { SystemActions.openLogs() }
      Button("Open Data Folder") { SystemActions.openFolder(model.dataRoot) }
    }
    Divider()
    LaunchAtLoginToggle()
    Button("Quit All Ears") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func open(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.open(url)
  }

  private func reveal(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func label(for verb: Verb) -> String {
    switch verb {
    case .startRecording: return "Start Recording"
    case .pause: return "Pause"
    case .resume: return "Resume"
    case .rename: return "Rename Session…"
    case .end: return "End Session"
    }
  }
}

struct MenuBarLabel: View {
  let variant: IconVariant

  var body: some View {
    Image(systemName: variant.systemImage)
  }
}

extension IconVariant {
  /// Every variant gets a glyph of its own. Paused in particular must not be
  /// the recording glyph dimmed: a menu bar template image renders monochrome
  /// against arbitrary wallpaper, and mistaking paused for recording is the
  /// mistake this icon exists to prevent.
  var systemImage: String {
    switch self {
    case .idle: return "ear"
    case .recording: return "ear.and.waveform"
    case .paused: return "pause.circle"
    case .busy: return "ear.badge.checkmark"
    case .attention: return "ear.trianglebadge.exclamationmark"
    }
  }
}

/// The Launch at Login switch, plus whatever the user has to be told for it to
/// mean anything.
///
/// Two states used to read identically — as the checkmark silently refusing to
/// stick. `register()` succeeding with status `.requiresApproval` (the
/// documented outcome when the item was previously disabled in System
/// Settings, and common on first registration) is a *success* the user must
/// finish by hand; and `register()` throwing is a real failure, likely here
/// because `make install` falls back to ad-hoc signing when no Developer ID
/// identity is present, and `SMAppService` will not register an ad-hoc-signed
/// bundle. Both are now said out loud.
struct LaunchAtLoginToggle: View {
  @State private var status = SMAppService.mainApp.status
  @State private var failure: String?

  var body: some View {
    if Bundle.main.bundleIdentifier != nil {
      Toggle(
        "Launch at Login",
        isOn: Binding(
          get: { status == .enabled || status == .requiresApproval },
          set: { wanted in
            do {
              if wanted {
                try SMAppService.mainApp.register()
              } else {
                try SMAppService.mainApp.unregister()
              }
              failure = nil
            } catch {
              failure = error.localizedDescription
            }
            status = SMAppService.mainApp.status
          }
        )
      )
      if status == .requiresApproval {
        Menu("⚠ Approve All Ears in Login Items") {
          Button("Open Login Items Settings") { SystemActions.openLoginItemsSettings() }
        }
      }
      if let failure {
        Text("⚠ \(failure)")
      }
    }
  }
}
