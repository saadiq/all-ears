public enum IconVariant: String, Sendable, Hashable {
  case idle, recording, paused, busy, attention
}

public enum Verb: Sendable, Hashable {
  case startRecording
  case startDetected(source: String, episode: String, label: String)
  case pause(session: String)
  case resume(session: String)
  case rename(session: String, currentTitle: String)
  case end(session: String)
}

/// One pipeline status row. `id` is the job id the row was rendered from, and
/// is the row's identity in the menu: two concurrent jobs render byte-identical
/// text whenever their sessions share a title (two manual starts in the same
/// minute), and SwiftUI's `ForEach` silently drops rows that collide on
/// identity — so a job in flight would simply vanish from the menu.
public struct PipelineLine: Sendable, Hashable, Identifiable {
  public var id: String
  public var text: String
  /// Whether the row carries a Dismiss action. True for every row the daemon
  /// might never clear on its own: failed rows persist by design until the
  /// user dismisses them, and an in-flight row is stranded if its terminal
  /// job event is dropped by a bounded queue.
  public var dismissible: Bool

  public init(id: String, text: String, dismissible: Bool = false) {
    self.id = id
    self.text = text
    self.dismissible = dismissible
  }
}

public struct MenuContent: Sendable, Hashable {
  public var icon: IconVariant
  public var header: String
  public var verbs: [Verb]
  public var pipeline: [PipelineLine]

  public init(icon: IconVariant, header: String, verbs: [Verb], pipeline: [PipelineLine]) {
    self.icon = icon
    self.header = header
    self.verbs = verbs
    self.pipeline = pipeline
  }
}
