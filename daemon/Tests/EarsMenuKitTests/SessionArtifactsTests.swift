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
  func endedSession(id: String = "0d5e7f6a", title: String = "standup") -> Session {
    let start = instant(1_784_284_200)
    return Session(
      id: id, title: title, state: .ended, started: start,
      ended: start.advanced(by: 600),
      intervals: [SessionInterval(start: start, end: start.advanced(by: 600))],
      sources: [SourceID("mic")])
  }

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

  @Test("the published transcript is [cleanup] output expanded against the session")
  func publishedTranscriptExpandsTheTemplate() {
    let paths = SessionArtifactLocator.published(for: endedSession(), settings: settings())
    #expect(paths.clean.path == "/out/2026/07/17/2026-07-17 - standup.md")
  }

  /// Date tokens come from `Session.started`, which is what `transcribe`
  /// stamps as the transcript's `started:` and therefore what `cleanup`
  /// expands. Deriving them from the first interval instead — as this
  /// locator once did — files a session that was paused at the start under
  /// the wrong day.
  @Test("date tokens come from the session start, not its first interval")
  func datesComeFromSessionStart() {
    var session = endedSession()
    session.intervals = [
      SessionInterval(start: session.started.advanced(by: 86_400), end: session.ended)
    ]
    let paths = SessionArtifactLocator.published(for: session, settings: settings())
    #expect(paths.clean.path == "/out/2026/07/17/2026-07-17 - standup.md")
  }

  /// Separators become `_` and the leading dots are trimmed, so the title
  /// stays one path component and cannot climb out of its directory.
  @Test("a title that would escape its directory is sanitised, not obeyed")
  func hostileTitleIsSanitised() {
    let paths = SessionArtifactLocator.published(
      for: endedSession(title: "../../etc/passwd"), settings: settings())
    #expect(paths.clean.path == "/out/2026/07/17/2026-07-17 - etc_passwd.md")
    #expect(paths.clean.deletingLastPathComponent().path == "/out/2026/07/17")
  }

  /// `{title}` degrades to `{slug}` and `{slug}` to the fallback name, which
  /// for a session run is the raw transcript's stem — matching `cleanup`'s
  /// own `documentStem` of `sessions/<id>/transcript.md`.
  @Test("an untitled, sourceless session still resolves to a usable path")
  func missingContextDegrades() {
    var session = endedSession(title: "")
    session.sources = []
    let paths = SessionArtifactLocator.published(for: session, settings: settings())
    #expect(paths.clean.path == "/out/2026/07/17/2026-07-17 - transcript.md")
  }

  @Test("summaries are siblings of the published transcript, sharing its stem")
  func summaryStemFollowsTheCleanedTranscript() {
    let paths = SessionArtifactLocator.published(for: endedSession(), settings: settings())
    #expect(paths.summaryDirectory.path == "/out/2026/07/17")
    #expect(paths.summaryStem == "2026-07-17 - standup")
  }

  @Test("a preset naming its own out is expanded there, outside the sibling sweep")
  func explicitPresetOutIsExpanded() {
    let paths = SessionArtifactLocator.published(
      for: endedSession(),
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
