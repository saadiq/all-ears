import Testing

@testable import EarsCore

@Suite("PathTemplate")
struct PathTemplateTests {
  /// 2026-08-05T09:04:07Z — the acceptance scenario's date (a Wednesday in
  /// US/ISO week 32).
  private let start = Instant(secondsSinceEpoch: 1_785_920_647)

  private func context(
    outputRoot: String = "/output-root",
    start: Instant? = nil,
    weekNumbering: WeekNumbering = .us,
    session: String? = nil,
    slug: String? = nil,
    title: String? = nil,
    fallbackName: String = "fallback",
    notes: String? = nil
  ) -> PathTemplate.Context {
    PathTemplate.Context(
      outputRoot: outputRoot,
      start: start ?? self.start,
      weekNumbering: weekNumbering,
      session: session,
      slug: slug,
      title: title,
      fallbackName: fallbackName,
      notes: notes)
  }

  @Test("the built-in default template expands to <output_root>/<y>/<m>/<d>/<date> - <title>.md")
  func defaultTemplateShape() {
    let template = PathTemplate("{output_root}/{year}/{month}/{day}/{date} - {title}.md")
    #expect(
      template.expand(context(title: "Kevin Weekly"))
        == "/output-root/2026/08/05/2026-08-05 - Kevin Weekly.md")
  }

  @Test("date and time components are zero-padded")
  func zeroPadding() {
    // 2026-01-02T03:04:05Z.
    let january = Instant(secondsSinceEpoch: 1_767_323_045)
    let template = PathTemplate("{year}/{month}/{day}/{date}/{time}")
    #expect(
      template.expand(context(start: january)) == "2026/01/02/2026-01-02/03-04-05")
  }

  @Test("{session} and {slug} expand to the run's identifiers")
  func sessionAndSlug() {
    let template = PathTemplate("{session}/{slug}")
    #expect(
      template.expand(context(session: "0d5e7f6a", slug: "mic_system"))
        == "0d5e7f6a/mic_system")
  }

  @Test("{title} falls back to {slug}, then to the input's basename")
  func titleDegradation() {
    let template = PathTemplate("{title}")
    #expect(template.expand(context(slug: "mic", title: "Standup")) == "Standup")
    #expect(template.expand(context(slug: "mic", title: nil)) == "mic")
    #expect(template.expand(context(slug: nil, title: nil)) == "fallback")
    // A title that sanitises down to nothing is treated as absent, not as an
    // empty path component.
    #expect(template.expand(context(slug: "mic", title: "  ///  ")) == "mic")
  }

  @Test("{session} degrades to the slug, then the basename, when there is no session")
  func sessionDegradation() {
    let template = PathTemplate("{session}")
    #expect(template.expand(context(session: nil, slug: "mic")) == "mic")
    #expect(template.expand(context(session: nil, slug: nil)) == "fallback")
  }

  @Test("{title} strips path separators and filesystem-hostile characters, keeping spaces")
  func titleSanitisation() {
    let template = PathTemplate("{title}")
    #expect(
      template.expand(context(title: "Q3 / Q4: plan?"))
        == "Q3 _ Q4_ plan_")
    // Unicode survives — this is a display title, not a source id.
    #expect(template.expand(context(title: "Café sync")) == "Café sync")
    // Leading dots would hide the file (or escape upwards); they are stripped.
    #expect(template.expand(context(title: "../etc/passwd")) == "etc_passwd")
  }

  @Test("{notes} expands to the already-expanded notes path when supplied")
  func notesToken() {
    let template = PathTemplate("{notes}")
    #expect(template.expand(context(notes: "/vault/daily/note.md")) == "/vault/daily/note.md")
    // No notes path in context: the token contributes nothing rather than
    // failing — an unset `notes` is a config-time concern, not an expansion one.
    #expect(template.expand(context(notes: nil)) == "")
  }

  @Test("literal text and unrecognised braces pass through untouched")
  func literalPassthrough() {
    #expect(PathTemplate("/plain/path.md").expand(context()) == "/plain/path.md")
    #expect(PathTemplate("{nope}/x").expand(context()) == "{nope}/x")
    #expect(PathTemplate("{unterminated/x").expand(context()) == "{unterminated/x")
  }

  // MARK: - Week numbering

  @Test("US weeks start on Sunday and week 1 contains Jan 1")
  func usWeekNumbering() {
    #expect(PathTemplate("{week}").expand(context(weekNumbering: .us)) == "32")
  }

  @Test("ISO weeks differ from US weeks in early January")
  func isoWeekNumberingDiverges() {
    // 2027-01-01 is a Friday: US calls it week 01 of 2027, ISO-8601 calls it
    // week 53 of 2026.
    let newYear2027 = Instant(secondsSinceEpoch: 1_798_761_600)
    let template = PathTemplate("{week}")
    #expect(template.expand(context(start: newYear2027, weekNumbering: .us)) == "01")
    #expect(template.expand(context(start: newYear2027, weekNumbering: .iso)) == "53")
  }

  @Test("US and ISO agree mid-year")
  func weekNumberingAgreesMidYear() {
    #expect(PathTemplate("{week}").expand(context(weekNumbering: .iso)) == "32")
  }

  @Test("a January date inside the previous ISO year still renders a padded week")
  func isoWeekPadding() {
    // 2026-01-01 is a Thursday — ISO week 01 of 2026, US week 01.
    let newYear2026 = Instant(secondsSinceEpoch: 1_767_225_600)
    #expect(PathTemplate("{week}").expand(context(start: newYear2026, weekNumbering: .iso)) == "01")
    #expect(PathTemplate("{week}").expand(context(start: newYear2026, weekNumbering: .us)) == "01")
  }

  // MARK: - Token validation

  @Test("unknownTokens names every token outside the allowed set, in order")
  func unknownTokensReported() {
    let unknown = PathTemplate.unknownTokens(
      in: "{output_root}/{yeer}/{titel}.md", allowing: PathTemplate.publishedTokens)
    #expect(unknown == ["yeer", "titel"])
  }

  @Test("a valid template reports no unknown tokens")
  func validTemplateHasNoUnknownTokens() {
    #expect(
      PathTemplate.unknownTokens(
        in: "{output_root}/{year}/{month}/{day}/{date} - {title}.md",
        allowing: PathTemplate.publishedTokens
      ).isEmpty)
  }

  @Test("{notes} is only allowed in a preset's out template")
  func notesTokenScoping() {
    #expect(
      PathTemplate.unknownTokens(in: "{notes}", allowing: PathTemplate.publishedTokens)
        == ["notes"])
    #expect(
      PathTemplate.unknownTokens(in: "{notes}", allowing: PathTemplate.presetOutTokens).isEmpty)
  }
}
