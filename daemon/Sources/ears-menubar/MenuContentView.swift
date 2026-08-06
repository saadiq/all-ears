import EarsMenuKit
import SwiftUI

struct MenuContentView: View {
  let model: AppModel

  var body: some View {
    Text(model.content.header)
    ForEach(model.content.verbs, id: \.self) { verb in
      Button(label(for: verb)) { model.perform(verb) }
    }
    if !model.content.pipeline.isEmpty {
      Divider()
      ForEach(model.content.pipeline, id: \.self) { line in
        if let jobID = line.dismissibleJobID {
          Menu(line.text) {
            Button("Dismiss") { model.dismiss(jobID: jobID) }
          }
        } else {
          Text(line.text)
        }
      }
    }
    Divider()
    // Recent Sessions + Daemon submenus land in Tasks 11/13.
    Button("Quit All Ears") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
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
      .opacity(variant == .paused ? 0.55 : 1)
  }
}

extension IconVariant {
  var systemImage: String {
    switch self {
    case .idle: return "ear"
    case .recording: return "ear.and.waveform"
    case .paused: return "ear.and.waveform"
    case .busy: return "ear.badge.checkmark"
    case .attention: return "ear.trianglebadge.exclamationmark"
    }
  }
}
