import EarsCore

/// The notification category a detected-meeting prompt is posted under, and
/// the buttons it carries. The app registers these with
/// `UNUserNotificationCenter` at launch and reads them back off a click; the
/// identifiers live here rather than in that shim so both sides of the seam
/// name the same strings.
public enum MeetingPromptCategory {
  public static let identifier = "meeting-detected"
  /// Accepts the offer — the same effect as clicking the notification body.
  public static let start = "start-recording"
  /// Declines it. Nothing to undo: the episode is marked prompted when the
  /// notification is *posted*, so declining only closes the notification.
  public static let dismiss = "not-now"

  /// The notification id a prompt for `source` is posted under.
  ///
  /// Keyed on the **source**, not the episode: one standing offer per meeting
  /// app, which a newer episode replaces rather than stacks beside. Meeting
  /// apps flap their input stream while a call is being joined — observed with
  /// Zoom taking the mic, dropping it 17s later, and taking it again — and
  /// each of those edges is its own episode. Per-episode ids left two live
  /// alerts on screen offering the same call.
  ///
  /// Stable rather than freshly minted per post for the second reason too: an
  /// alert-style prompt does not fade on its own (see
  /// `NSUserNotificationAlertStyle` in the app's Info.plist), so the app must
  /// be able to name one to take it back once it is answered.
  public static func notificationIdentifier(source: String) -> String {
    "\(identifier):\(source)"
  }
}

/// One prompt-worthy detected meeting: what to post, and the episode the
/// caller marks prompted as it posts.
public struct MeetingPrompt: Sendable, Hashable {
  public var source: String
  public var episode: String
  public var label: String

  public init(source: String, episode: String, label: String) {
    self.source = source
    self.episode = episode
    self.label = label
  }

  public var title: String { "\(label) meeting detected" }
  public var body: String { "Start recording?" }
  public var notificationIdentifier: String {
    MeetingPromptCategory.notificationIdentifier(source: source)
  }
}

/// What one reconcile does: prompts to post, sources whose standing prompt to
/// withdraw, and episodes to remember as prompted (posted or dropped).
public struct MeetingPromptDecision: Sendable, Hashable {
  public var post: [MeetingPrompt]
  public var withdrawSources: [String]
  public var markPrompted: [String]

  public init(
    post: [MeetingPrompt] = [], withdrawSources: [String] = [], markPrompted: [String] = []
  ) {
    self.post = post
    self.withdrawSources = withdrawSources
    self.markPrompted = markPrompted
  }
}

/// Decides which detected meetings deserve a prompt right now. Policy, not
/// state: the caller owns the already-prompted set (persisted across app
/// restarts, keyed on the daemon's episode ids) and applies the decision.
///
/// An episode is marked prompted when its prompt is *posted*, whether or not
/// macOS shows it: with notifications denied the post is dropped, and the
/// episode still counts as offered. That is deliberate — the menu row offers
/// the same meeting regardless, and an episode re-prompted the moment
/// notifications come back on would arrive mid-call, long after the join it
/// was for. Turning notifications on applies from the next episode.
public enum MeetingPromptPolicy {
  public static func decide(
    activity: MeetingActivityState, menu: MenuState, alreadyPrompted: Set<String>
  ) -> MeetingPromptDecision {
    guard menu.connection == .connected else { return MeetingPromptDecision() }
    // Only a live session voids an offer. An episode going inactive must
    // *not*: meeting apps drop and retake the input stream while a call is
    // being joined — Zoom was observed taking the mic, releasing it 17s later,
    // and taking it again — so withdrawing on that edge cancelled the prompt
    // within seconds of posting it, twice, before the user could answer.
    // Waiting to be answered is the whole point of an alert-style prompt.
    //
    // An offer for a call that has since ended therefore stays on screen, and
    // that is the intended trade: the notification id is keyed on the source,
    // so a later episode replaces it rather than stacking, and accepting a
    // stale one costs a session the daemon auto-ends after `idle_grace_s`.
    if menu.activeSession != nil {
      // Dropped, not deferred: an episode that began while a session was live
      // never prompts later — marking it prompted now is what encodes the drop.
      return MeetingPromptDecision(
        withdrawSources: activity.activity.map(\.source.rawValue),
        markPrompted: activity.active.map(\.episode))
    }
    let prompts = activity.active
      .filter { !alreadyPrompted.contains($0.episode) }
      .map {
        MeetingPrompt(source: $0.source.rawValue, episode: $0.episode, label: $0.displayLabel)
      }
    return MeetingPromptDecision(post: prompts, markPrompted: prompts.map(\.episode))
  }

  /// Whether a frame that moved the menu from `before` to `after` calls for a
  /// fresh ``decide(activity:menu:alreadyPrompted:)``: meeting activity
  /// changed, or a session went live or stopped being live. The second is
  /// what withdraws every other source's standing prompt once an accepted
  /// offer (or a session started any other way) is recording — a session
  /// frame, not a meeting one, is what says so.
  public static func needsReconcile(
    activityChanged: Bool, before: MenuState, after: MenuState
  ) -> Bool {
    activityChanged || (before.activeSession == nil) != (after.activeSession == nil)
  }
}
