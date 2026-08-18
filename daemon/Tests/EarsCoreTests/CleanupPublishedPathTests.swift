import Foundation
import Testing

@testable import EarsCore

@Suite("CleanupPublishedPath")
struct CleanupPublishedPathTests {
  /// 2026-08-17T15:01:00Z.
  private let started = Instant(secondsSinceEpoch: 1_786_978_860)
  /// A later rerun-narrowed range start — must NOT drive the date tokens.
  private let rangeStart = Instant(secondsSinceEpoch: 1_787_065_260)

  private func frontmatter(
    session: String? = "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff",
    title: String? = "Matt Silva",
    started: Instant?
  ) -> TranscriptFrontmatter {
    TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      session: session,
      title: title,
      started: started,
      sources: [SourceID("mic"), SourceID("browser:meet:t1")],
      range: TimeRange(start: rangeStart, end: rangeStart.advanced(by: 60)),
      model: TranscriptModelInfo(name: "m", backend: "b", version: "v"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: rangeStart,
      durationSeconds: 60,
      speechSeconds: 30,
      wordCount: 100,
      vocab: [])
  }

  @Test("the default template expands to the date-foldered title path, keyed on started:")
  func defaultTemplateUsesSessionContext() {
    let context = CleanupPublishedPath.context(
      outputRoot: "/out",
      weekNumbering: .us,
      frontmatter: frontmatter(started: started),
      transcriptPath: "/data/sessions/3db61b03/transcript.md")
    let path = PathTemplate("{output_root}/{year}/{month}/{day}/{date} - {title}.md")
      .expand(context)
    #expect(path == "/out/2026/08/17/2026-08-17 - Matt Silva.md")
  }

  @Test("with no started:, dates fall back to the range start")
  func datesFallBackToRangeStart() {
    let context = CleanupPublishedPath.context(
      outputRoot: "/out",
      weekNumbering: .us,
      frontmatter: frontmatter(started: nil),
      transcriptPath: "/data/sessions/x/transcript.md")
    let path = PathTemplate("{date}.md").expand(context)
    #expect(path == "2026-08-18.md")
  }

  @Test("with no title, {title} degrades to the path-safe source slug")
  func titleDegradesToSlug() {
    let context = CleanupPublishedPath.context(
      outputRoot: "/out",
      weekNumbering: .us,
      frontmatter: frontmatter(title: nil, started: started),
      transcriptPath: "/data/sessions/x/transcript.md")
    #expect(PathTemplate("{title}").expand(context) == "mic_browser_meet_t1")
  }

  @Test("documentStem strips the known transcript suffixes, and only those")
  func documentStemStripsKnownSuffixes() {
    #expect(
      CleanupPublishedPath.documentStem(URL(fileURLWithPath: "/a/standup.transcript.md"))
        == "standup")
    #expect(
      CleanupPublishedPath.documentStem(URL(fileURLWithPath: "/a/standup.clean.md")) == "standup")
    #expect(CleanupPublishedPath.documentStem(URL(fileURLWithPath: "/a/notes.md")) == "notes")
  }
}
