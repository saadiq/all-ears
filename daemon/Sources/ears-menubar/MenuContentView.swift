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
        Menu(item.session.title) {
          Button("Open Summary") { open(item.summaries.first) }
            .disabled(item.summaries.isEmpty)
          Button("Open Transcript") { open(item.clean ?? item.transcript) }
            .disabled(item.clean == nil && item.transcript == nil)
          Button("Show in Finder") { reveal(item.transcript ?? item.summaries.first ?? item.clean) }
            .disabled(item.transcript == nil && item.summaries.isEmpty && item.clean == nil)
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

struct LaunchAtLoginToggle: View {
  @State private var enabled = SMAppService.mainApp.status == .enabled

  var body: some View {
    if Bundle.main.bundleIdentifier != nil {
      Toggle(
        "Launch at Login",
        isOn: Binding(
          get: { enabled },
          set: { wanted in
            do {
              if wanted {
                try SMAppService.mainApp.register()
              } else {
                try SMAppService.mainApp.unregister()
              }
            } catch {
              // status re-read below reflects reality
            }
            enabled = SMAppService.mainApp.status == .enabled
          }
        )
      )
    }
  }
}
