import Foundation
import Testing

@testable import EarsDataStore

/// ``SessionAttributionLog`` appends browser-recorded attribution
/// flight-recorder lines to `sessions/<id>/attribution.jsonl` beside
/// `events.jsonl` — same append-only JSONL discipline, but the lines are
/// pre-encoded by the browser and written verbatim (the daemon never
/// interprets the vocabulary).
@Suite("SessionAttributionLog")
struct SessionAttributionLogTests {
  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SessionAttributionLogTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // Sanitized synthetic lines only, per the flight-recorder privacy rule.
  private let lines = [
    #"{"schema":1,"type":"track-appeared","t":1000,"trackId":"trk-1","seam":"receiver-track","muted":true}"#,
    #"{"schema":1,"type":"dom-burst","t":1001,"deviceId":"spaces/demo/devices/1"}"#,
  ]

  @Test("append writes each line verbatim and reads them back in order")
  func appendAndReadBack() throws {
    let dataRoot = try makeDataRoot()
    let appended = try SessionAttributionLog.append(
      lines: lines, dataRoot: dataRoot, sessionID: "s-1")
    #expect(appended == 2)

    let url = SessionAttributionLog.fileURL(dataRoot: dataRoot, sessionID: "s-1")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == lines[0] + "\n" + lines[1] + "\n")
    #expect(SessionAttributionLog.readAllLines(dataRoot: dataRoot, sessionID: "s-1") == lines)
  }

  @Test("a second append accumulates — the file is append-only")
  func appendAccumulates() throws {
    let dataRoot = try makeDataRoot()
    _ = try SessionAttributionLog.append(lines: [lines[0]], dataRoot: dataRoot, sessionID: "s-1")
    _ = try SessionAttributionLog.append(lines: [lines[1]], dataRoot: dataRoot, sessionID: "s-1")
    #expect(SessionAttributionLog.readAllLines(dataRoot: dataRoot, sessionID: "s-1") == lines)
  }

  @Test("lines that are not single JSON objects are skipped, not written")
  func malformedLinesSkipped() throws {
    let dataRoot = try makeDataRoot()
    let appended = try SessionAttributionLog.append(
      lines: [
        lines[0],
        "not json",  // unparseable
        "[1,2]",  // an array, not an event object
        "{\"a\":1}\n{\"b\":2}",  // an embedded newline would corrupt the JSONL framing
        lines[1],
      ],
      dataRoot: dataRoot, sessionID: "s-1")
    #expect(appended == 2)
    #expect(SessionAttributionLog.readAllLines(dataRoot: dataRoot, sessionID: "s-1") == lines)
  }

  @Test("reading a session with no attribution log is an empty list")
  func missingFileReadsEmpty() throws {
    let dataRoot = try makeDataRoot()
    #expect(SessionAttributionLog.readAllLines(dataRoot: dataRoot, sessionID: "nope").isEmpty)
  }
}
