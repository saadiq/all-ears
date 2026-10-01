import Testing

@testable import EarsMenuKit

@Suite("PromptedEpisodes")
struct PromptedEpisodesTests {
  @Test("marking an episode twice records it once")
  func markIsIdempotent() {
    var history = PromptedEpisodes()
    history.mark("a#1")
    history.mark("a#1")
    #expect(history.episodes == ["a#1"])
    #expect(history.set == ["a#1"])
  }

  @Test("past the cap the oldest episodes are evicted first")
  func capEvictsOldest() {
    var history = PromptedEpisodes()
    for index in 0...PromptedEpisodes.cap { history.mark("a#\(index)") }
    #expect(history.episodes.count == PromptedEpisodes.cap)
    #expect(history.episodes.first == "a#1")
    #expect(history.episodes.last == "a#\(PromptedEpisodes.cap)")
  }

  @Test("the same daemon boot keeps the history")
  func sameBootKeeps() {
    var history = PromptedEpisodes(episodes: ["a#1"], bootID: "boot-1")
    history.activate(bootID: "boot-1")
    #expect(history.episodes == ["a#1"])
  }

  @Test("a different daemon boot clears the history and adopts the new id")
  func newBootClears() {
    var history = PromptedEpisodes(episodes: ["a#1"], bootID: "boot-1")
    history.activate(bootID: "boot-2")
    #expect(history.episodes.isEmpty)
    #expect(history.bootID == "boot-2")
  }

  @Test("the first activation adopts the boot id and starts empty")
  func firstActivation() {
    var history = PromptedEpisodes(episodes: ["a#1"], bootID: nil)
    history.activate(bootID: "boot-1")
    #expect(history.episodes.isEmpty)
    #expect(history.bootID == "boot-1")
  }
}
