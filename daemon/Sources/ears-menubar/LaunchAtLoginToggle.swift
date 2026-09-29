import ServiceManagement
import SwiftUI

/// The Launch at Login switch, plus whatever the user has to be told for it to
/// mean anything.
///
/// Two outcomes would otherwise read identically, as a checkmark silently
/// refusing to stick. `register()` succeeding with status `.requiresApproval`
/// (the documented outcome when the item was previously disabled in System
/// Settings, and common on first registration) is a *success* the user must
/// finish by hand; and `register()` throwing is a real failure, likely here
/// because `make menubar` falls back to ad-hoc signing when no Developer ID
/// identity is present, and `SMAppService` will not register an ad-hoc-signed
/// bundle. Both are said out loud.
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
