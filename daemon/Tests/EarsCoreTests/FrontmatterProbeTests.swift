import Testing

@testable import EarsCore

@Suite("FrontmatterProbe")
struct FrontmatterProbeTests {
  @Test("finds a top-level key in block-style YAML a vault linter reformatted")
  func blockStyleYAML() {
    let markdown = """
      ---
      schema: 1
      kind: clean
      note: "[[daily-notes/2026/08/34/2026-08-17 - Michael Schwanzer]]"
      attendees:
        - Tom Elliot (me)
        - Michael Schwanzer
      ---
      body
      """
    #expect(
      FrontmatterProbe.value(of: "note", in: markdown)
        == "[[daily-notes/2026/08/34/2026-08-17 - Michael Schwanzer]]")
  }

  @Test("flow-style frontmatter and single quotes work too")
  func flowStyle() {
    let markdown = "---\nnote: '[[calls/x]]'\ntitle: T\n---\n"
    #expect(FrontmatterProbe.value(of: "note", in: markdown) == "[[calls/x]]")
  }

  @Test("an absent key, a nested key, or no frontmatter at all is nil")
  func absentCases() {
    #expect(FrontmatterProbe.value(of: "note", in: "---\ntitle: T\n---\n") == nil)
    #expect(FrontmatterProbe.value(of: "note", in: "no frontmatter") == nil)
    // A nested `note:` under some other key must not be read as top-level.
    let nested = "---\nmeta:\n  note: nope\n---\n"
    #expect(FrontmatterProbe.value(of: "note", in: nested) == nil)
    // An empty value is absence, not "".
    #expect(FrontmatterProbe.value(of: "note", in: "---\nnote:\n---\n") == nil)
  }
}
