import SwiftUI

@main
struct MenuBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model: AppModel

  init() {
    switch ClientConfig.resolve() {
    case .success(let config):
      let model = AppModel(config: config)
      _model = State(initialValue: model)
      model.start()
    case .failure(let error):
      _model = State(initialValue: AppModel(configError: error.description))
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView(model: model)
        .onAppear { model.menuWillOpen() }
    } label: {
      MenuBarLabel(variant: model.content.icon)
    }
    .menuBarExtraStyle(.menu)
  }
}

/// Keeps dev runs (`swift run ears-menubar`, no bundle) out of the Dock.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
