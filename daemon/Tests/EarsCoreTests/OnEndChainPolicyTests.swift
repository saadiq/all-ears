import Testing

@testable import EarsCore

@Suite("OnEndChainPolicy")
struct OnEndChainPolicyTests {
  let configured: [OnEndStage] = [.transcribe, .cleanup, .summarize]

  @Test("an undeclared manual session runs nothing, whatever the config says")
  func undeclaredManualIsInert() {
    let resolved = OnEndChainPolicy.stages(
      declared: nil, trigger: .manual, configured: configured)
    #expect(resolved.stages.isEmpty)
    #expect(resolved.problems.isEmpty)
  }

  @Test("an undeclared browser session inherits the configured chain")
  func undeclaredBrowserInheritsConfig() {
    let resolved = OnEndChainPolicy.stages(
      declared: nil, trigger: .browserExtension, configured: configured)
    #expect(resolved.stages == configured)
  }

  @Test("a declared chain wins over the trigger's default, in both directions")
  func declarationWins() {
    let manual = OnEndChainPolicy.stages(
      declared: ["transcribe"], trigger: .manual, configured: [])
    #expect(manual.stages == [.transcribe])

    let browser = OnEndChainPolicy.stages(
      declared: [], trigger: .browserExtension, configured: configured)
    #expect(browser.stages.isEmpty)
  }

  @Test("a declared chain is validated like config, reporting what it drops")
  func declaredChainIsValidated() {
    let unknown = OnEndChainPolicy.stages(
      declared: ["transcribe", "summarise"], trigger: .manual, configured: [])
    #expect(unknown.stages == [.transcribe])
    #expect(unknown.problems.count == 1)

    let orphaned = OnEndChainPolicy.stages(
      declared: ["summarize"], trigger: .manual, configured: [])
    #expect(orphaned.stages.isEmpty)
    #expect(orphaned.problems.count == 1)
  }

  @Test("app-detected sessions inherit the configured chain when undeclared")
  func appDetectedInheritsConfiguredChain() {
    let result = OnEndChainPolicy.stages(
      declared: nil, trigger: .appDetected, configured: OnEndStage.allCases)
    #expect(result.stages == OnEndStage.allCases)
    #expect(result.problems.isEmpty)
  }

  /// An absent key and an explicit `[]` are different answers: nothing
  /// configured means the daemon's full chain, while `[]` is an operator
  /// saying "run none of it". A reader that collapsed the two would report a
  /// stage as missing on a machine that deliberately disabled it.
  @Test("an absent on_end_stages key means the full chain, an empty list means none")
  func absentKeyDiffersFromEmptyList() {
    #expect(OnEndChainPolicy.configured(fromRaw: nil) == OnEndStage.allCases)
    #expect(OnEndChainPolicy.configured(fromRaw: []).isEmpty)
  }

  @Test("a configured list resolves leniently, dropping what the daemon would drop")
  func configuredListResolvesLeniently() {
    #expect(OnEndChainPolicy.configured(fromRaw: ["transcribe"]) == [.transcribe])
    #expect(
      OnEndChainPolicy.configured(fromRaw: ["summarize", "transcribe", "nonsense"])
        == [.transcribe, .summarize])
    // LLM stages with no transcribe to feed them are the daemon's to complain
    // about; a read-only view just gets the chain that would actually run.
    #expect(OnEndChainPolicy.configured(fromRaw: ["cleanup"]).isEmpty)
  }

  /// The schema's default list is what most readers actually see: the full
  /// config schema materialises it, so the absent-key fallback above is only
  /// reachable for a reader loading a partial schema (`ears`'s scanner). The
  /// three readers of `[earsd.sessions] on_end_stages` therefore agree only
  /// while this literal names every stage — a new `OnEndStage` case must be
  /// added to the schema default too, or the scanner would run a longer chain
  /// than the daemon and menu bar believe in, with nothing failing.
  @Test("the schema's default on_end_stages names the whole stage vocabulary")
  func schemaDefaultNamesEveryStage() {
    guard case .table(let root) = EarsdConfigSchema.defaults,
      case .table(let earsd)? = root["earsd"],
      case .table(let sessions)? = earsd["sessions"],
      case .array(let entries)? = sessions["on_end_stages"]
    else {
      Issue.record("schema shape changed: [earsd.sessions] on_end_stages not found")
      return
    }
    let names = entries.compactMap { entry -> String? in
      guard case .string(let name) = entry else { return nil }
      return name
    }
    #expect(names == OnEndStage.allCases.map(\.rawValue))
  }
}
