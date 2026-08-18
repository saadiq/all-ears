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
}
