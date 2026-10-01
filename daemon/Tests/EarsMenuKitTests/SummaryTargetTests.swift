import Foundation
import Testing

@testable import EarsMenuKit

@Suite("SummaryTarget")
struct SummaryTargetTests {
  @Test("the reported file opens while it exists")
  func writtenFileOpens() {
    #expect(
      SummaryTarget.written("/n/a.summary.md", exists: { _ in true })
        == URL(fileURLWithPath: "/n/a.summary.md"))
  }

  @Test("a moved or deleted file, or no reported path, falls back to the caller's scan")
  func missingWrittenFileFallsBack() {
    #expect(SummaryTarget.written("/n/a.summary.md", exists: { _ in false }) == nil)
    #expect(SummaryTarget.written(nil, exists: { _ in true }) == nil)
  }
}
