import Testing

@testable import EarsMenuKit

@Suite("PromptedEpisodePolicy")
struct PromptedEpisodePolicyTests {
  @Test("no stored boot id (first launch, or pre-boot-scoping history) resets")
  func noStoredBootID() {
    #expect(PromptedEpisodePolicy.shouldReset(storedBootID: nil, currentBootID: "boot-2"))
  }

  @Test("a stored boot id that differs from the current one resets")
  func differentBootID() {
    #expect(
      PromptedEpisodePolicy.shouldReset(storedBootID: "boot-1", currentBootID: "boot-2"))
  }

  @Test("a stored boot id matching the current one keeps the history")
  func sameBootID() {
    #expect(
      !PromptedEpisodePolicy.shouldReset(storedBootID: "boot-1", currentBootID: "boot-1"))
  }
}
