import Testing

@testable import EarsCore

@Suite("SummarySiblings")
struct SummarySiblingsTests {
  @Test("a lone preset and named presets match; longer stems sharing the prefix do not")
  func selectsOnlyThisStem() {
    let names = [
      "2026-08-03 standup.summary.md",
      "2026-08-03 standup.brief.summary.md",
      "2026-08-03 standup-2.summary.md",
      "2026-08-03 standup.brief.extra.summary.md",
      "2026-08-03 standup.md",
    ]
    #expect(
      SummarySiblings.select(filenames: names, stem: "2026-08-03 standup")
        == ["2026-08-03 standup.brief.summary.md", "2026-08-03 standup.summary.md"])
  }

  @Test("a stem that overlaps the suffix is not its own summary")
  func stemOverlappingSuffixDoesNotMatch() {
    #expect(SummarySiblings.select(filenames: ["notes.summary.md"], stem: "notes.summary").isEmpty)
  }
}
