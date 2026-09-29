import AppKit

/// The Rename Session modal.
///
/// A separate type because it is the one place the app runs AppKit UI of its
/// own: a modal run loop, an activation policy dance, and a text field —
/// none of which `AppModel` has any other reason to know about.
enum RenamePrompt {
  /// Runs the modal and returns the new title, or `nil` if the user cancelled
  /// or left it empty.
  @MainActor
  static func run(currentTitle: String) -> String? {
    // LSUIElement apps are not frontmost, so a modal they present would open
    // behind whatever is.
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Rename Session"
    let field = NSTextField(string: currentTitle)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    // The daemon stores whatever it is sent, so a whitespace-only entry would
    // blank the session's title rather than read as "left it empty".
    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }
}
