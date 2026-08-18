import EarsCore
import Foundation
import Testing

@testable import EarsMenuKit

@Suite("PublishingSettings")
struct PublishingSettingsTests {
  @Test("reads output_root, the cleanup template, week numbering, and presets in order")
  func resolvesFromConfig() {
    let config = ConfigValue.table([
      "output_root": .string("/out"),
      "week_numbering": .string("iso"),
      "cleanup": .table(["output": .string("{output_root}/{date}.md")]),
      "summarize": .table([
        "preset": .array([
          .table(["name": .string("brief")]),
          .table(["name": .string("notes"), "out": .string("{output_root}/vault/{title}.md")]),
        ])
      ]),
    ])
    let settings = PublishingSettings.resolve(from: config)
    #expect(settings.outputRoot == "/out")
    #expect(settings.cleanupOutput == "{output_root}/{date}.md")
    #expect(settings.weekNumbering == .iso)
    #expect(settings.presets.map(\.name) == ["brief", "notes"])
    #expect(settings.presets.map(\.out) == [nil, "{output_root}/vault/{title}.md"])
  }

  @Test("an absent [cleanup] output falls back to the same default cleanup itself uses")
  func fallsBackToCleanupDefault() {
    let settings = PublishingSettings.resolve(from: .table(["output_root": .string("/out")]))
    #expect(settings.cleanupOutput == LLMStagesConfigSchema.defaultCleanupOutput)
    #expect(settings.presets.isEmpty)
  }

  @Test("a preset with an empty name is dropped, and an empty out reads as absent")
  func dropsEmptyEntries() {
    let config = ConfigValue.table([
      "summarize": .table([
        "preset": .array([
          .table(["name": .string("")]),
          .table(["name": .string("brief"), "out": .string("")]),
        ])
      ])
    ])
    let settings = PublishingSettings.resolve(from: config)
    #expect(settings.presets.map(\.name) == ["brief"])
    #expect(settings.presets[0].out == nil)
  }
}

@Suite("SessionArtifactLocator")
struct SessionArtifactLocatorTests {
  // 2026-07-17T10:30:00Z == 1_784_284_200 — verified with
  // `TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-07-17T10:30:00Z" +%s`
  static let started = instant(1_784_284_200)
  /// A rerun-narrowed range start, a day later — must never drive the dates.
  static let rangeStart = instant(1_784_370_600)

  func frontmatter(
    title: String? = "standup",
    started: Instant? = SessionArtifactLocatorTests.started,
    sources: [SourceID] = [SourceID("mic")]
  ) -> TranscriptFrontmatter {
    TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      session: "0d5e7f6a",
      title: title,
      started: started,
      sources: sources,
      range: TimeRange(start: Self.rangeStart, end: Self.rangeStart.advanced(by: 600)),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: Self.rangeStart,
      durationSeconds: 600,
      speechSeconds: 400,
      wordCount: 900,
      vocab: [])
  }

  /// Where `transcribe --session` put the raw transcript this locator reads.
  let transcriptPath = "/data/sessions/0d5e7f6a/transcript.md"

  func settings(
    cleanupOutput: String = LLMStagesConfigSchema.defaultCleanupOutput,
    presets: [PublishingSettings.Preset] = []
  ) -> PublishingSettings {
    PublishingSettings(
      outputRoot: "/out", cleanupOutput: cleanupOutput, weekNumbering: .us, presets: presets)
  }

  @Test("the raw transcript is addressed by session id in the data store, not output_root")
  func rawTranscriptLivesInTheDataStore() {
    let url = SessionArtifactLocator.rawTranscript(dataRoot: "/data", sessionID: "0d5e7f6a")
    #expect(url.path == "/data/sessions/0d5e7f6a/transcript.md")
  }

  @Test("the published transcript is [cleanup] output expanded against the transcript")
  func publishedTranscriptExpandsTheTemplate() {
    let paths = SessionArtifactLocator.published(
      frontmatter: frontmatter(), transcriptPath: transcriptPath, settings: settings())
    #expect(paths.clean.path == "/out/2026/07/17/2026-07-17 - standup.md")
  }

  /// The fixture's range starts a day after its `started:`, so the two dates
  /// tell each other apart: with `started:` present the path files under it
  /// (the test above), and only its absence falls through to the range. A
  /// `--from`/`--to` rerun narrows the range without moving the session, so
  /// preferring the range would refile a re-cleaned transcript under the wrong
  /// day.
  @Test("without started:, date tokens fall back to the range start")
  func datesFallBackToTheRange() {
    let paths = SessionArtifactLocator.published(
      frontmatter: frontmatter(started: nil), transcriptPath: transcriptPath,
      settings: settings())
    #expect(paths.clean.path == "/out/2026/07/18/2026-07-18 - standup.md")
  }

  /// Separators become `_` and the leading dots are trimmed, so the title
  /// stays one path component and cannot climb out of its directory.
  @Test("a title that would escape its directory is sanitised, not obeyed")
  func hostileTitleIsSanitised() {
    let paths = SessionArtifactLocator.published(
      frontmatter: frontmatter(title: "../../etc/passwd"), transcriptPath: transcriptPath,
      settings: settings())
    #expect(paths.clean.path == "/out/2026/07/17/2026-07-17 - etc_passwd.md")
    #expect(paths.clean.deletingLastPathComponent().path == "/out/2026/07/17")
  }

  /// `{title}` degrades to `{slug}` — the transcript's own path-safe source
  /// list — before it reaches the fallback name.
  @Test("a titleless transcript files under its source slug")
  func titleDegradesToSlug() {
    let paths = SessionArtifactLocator.published(
      frontmatter: frontmatter(
        title: nil, sources: [SourceID("mic"), SourceID("browser:meet:t1")]),
      transcriptPath: transcriptPath, settings: settings())
    #expect(paths.clean.path == "/out/2026/07/17/2026-07-17 - mic_browser_meet_t1.md")
  }

  /// With neither title nor sources, `{title}` degrades all the way to the
  /// input document's stem — `cleanup`'s own `documentStem` of the path it was
  /// handed, which for a session run is `sessions/<id>/transcript.md`.
  @Test("an untitled, sourceless transcript still resolves to a usable path")
  func missingContextDegrades() {
    let paths = SessionArtifactLocator.published(
      frontmatter: frontmatter(title: nil, sources: []), transcriptPath: transcriptPath,
      settings: settings())
    #expect(paths.clean.path == "/out/2026/07/17/2026-07-17 - transcript.md")
  }

  @Test("summaries are siblings of the published transcript, sharing its stem")
  func summaryStemFollowsTheCleanedTranscript() {
    let paths = SessionArtifactLocator.published(
      frontmatter: frontmatter(), transcriptPath: transcriptPath, settings: settings())
    #expect(paths.summaryDirectory.path == "/out/2026/07/17")
    #expect(paths.summaryStem == "2026-07-17 - standup")
  }

  @Test("a preset naming its own out is expanded there, outside the sibling sweep")
  func explicitPresetOutIsExpanded() {
    let paths = SessionArtifactLocator.published(
      frontmatter: frontmatter(),
      transcriptPath: transcriptPath,
      settings: settings(presets: [
        PublishingSettings.Preset(name: "brief", out: nil),
        PublishingSettings.Preset(name: "notes", out: "{output_root}/vault/{date} - {title}.md"),
      ]))
    #expect(paths.explicitSummaries.map(\.path) == ["/out/vault/2026-07-17 - standup.md"])
  }

  @Test("sibling summaries match the bare and per-preset forms, and nothing else")
  func siblingSummariesMatchBothForms() {
    let names = SessionArtifactLocator.siblingSummaries(
      filenames: [
        "2026-07-17 - standup.md",
        "2026-07-17 - standup.summary.md",
        "2026-07-17 - standup.brief.summary.md",
        "2026-07-17 - standup.decisions.summary.md",
        "2026-07-17 - standup.summary.json",
        "2026-07-17 - other.summary.md",
      ],
      stem: "2026-07-17 - standup")
    #expect(
      names == [
        "2026-07-17 - standup.brief.summary.md",
        "2026-07-17 - standup.decisions.summary.md",
        "2026-07-17 - standup.summary.md",
      ])
  }

  /// A stem is a filename component, so a directory listing that happens to
  /// contain a nested-looking name can't widen the sweep.
  @Test("a sibling name carrying a path separator is not a sibling")
  func siblingSweepStaysInOneDirectory() {
    let names = SessionArtifactLocator.siblingSummaries(
      filenames: ["2026-07-17 - standup.x/../../escape.summary.md"],
      stem: "2026-07-17 - standup")
    #expect(names.isEmpty)
  }
}

@Suite("RecentSessions")
struct RecentSessionsTests {
  @Test("select keeps ended sessions, newest first, capped")
  func selectsEndedNewestFirst() {
    let sessions = [
      makeSession(id: "live", state: .active, started: 5_000),
      makeSession(id: "old", state: .ended, started: 1_000),
      makeSession(id: "new", state: .ended, started: 3_000),
      makeSession(id: "mid", state: .ended, started: 2_000),
    ]
    #expect(RecentSessions.select(from: sessions, limit: 2).map(\.id) == ["new", "mid"])
  }
}
