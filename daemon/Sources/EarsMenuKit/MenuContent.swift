public enum IconVariant: String, Sendable, Hashable {
  case idle, recording, paused, busy, attention
}

public enum Verb: Sendable, Hashable {
  case startRecording
  case pause(session: String)
  case resume(session: String)
  case rename(session: String, currentTitle: String)
  case end(session: String)
}

public struct PipelineLine: Sendable, Hashable {
  public var text: String
  public var dismissibleJobID: String?

  public init(text: String, dismissibleJobID: String? = nil) {
    self.text = text
    self.dismissibleJobID = dismissibleJobID
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
