/// Decides which on-end stages an ended session actually runs.
///
/// The daemon supplies the *mechanism* (spawn these tools, in this order,
/// gated on transcribe succeeding); the session's starter supplies the
/// *policy*. A client that wants post-processing asks for it in
/// `session.start`; one that intends to run `transcribe` itself with its own
/// flags passes `[]` and gets a daemon that stays out of its way.
///
/// When nothing was declared the daemon falls back to a per-trigger default,
/// and that default is deliberately conservative: browser-extension and
/// app-detected sessions inherit the configured chain (the extension has no
/// other way to ask, and its whole flow assumes a transcript appears), while
/// every other trigger runs nothing. So `ears session start`/`session end`
/// remains inert unless asked — an operator's scripted capture never silently
/// grows a Parakeet load and a per-preset LLM bill it did not have before.
///
/// Pure, and in EarsCore rather than the daemon, because the read side needs
/// it too: `ears`'s pipeline view has to know which stages were ever asked
/// for before it can call a missing artifact a gap.
public enum OnEndChainPolicy {
  /// - Parameters:
  ///   - declared: the session's own `on_end_stages`, `nil` when undeclared.
  ///   - trigger: the session's provenance, which selects the default.
  ///   - configured: the resolved `[earsd.sessions] on_end_stages` chain.
  /// - Returns: the stages to run, plus one human-readable problem per
  ///   declared entry dropped (unknown name, or LLM stages with no
  ///   `transcribe` to feed them) — reported like a bad config entry rather
  ///   than failing the session.
  public static func stages(
    declared: [String]?, trigger: TriggerKind, configured: [OnEndStage]
  ) -> (stages: [OnEndStage], problems: [String]) {
    guard let declared else {
      let inherits = trigger == .browserExtension || trigger == .appDetected
      return (inherits ? configured : [], [])
    }
    return OnEndStage.resolveList(declared)
  }
}
