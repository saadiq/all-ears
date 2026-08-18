import Foundation
import Testing

@testable import EarsCore

@Suite("SessionRef")
struct SessionRefTests {
  private let utc = TimeZone(identifier: "UTC")!
  /// 2026-08-17T15:01:00Z.
  private let today = Instant(secondsSinceEpoch: 1_786_978_860)
  /// A day earlier, same wall time.
  private var yesterday: Instant { today.advanced(by: -86_400) }
  /// "now": 2026-08-17T18:30:00Z.
  private var now: Instant { Instant(secondsSinceEpoch: 1_786_991_400) }

  private func session(id: String, title: String, started: Instant) -> Session {
    Session(id: id, title: title, state: .ended, started: started, ended: started)
  }

  private var sessions: [Session] {
    [
      session(id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff", title: "Matt Silva", started: today),
      session(
        id: "3f00aaaa-bbbb-cccc-dddd-eeeeffff0000", title: "Weekly Product Meeting",
        started: today.advanced(by: 3 * 3_600)),
      session(
        id: "9c00aaaa-bbbb-cccc-dddd-eeeeffff0000", title: "Matt Silva", started: yesterday),
    ]
  }

  @Test("a unique id prefix resolves")
  func uniqueIDPrefix() {
    let resolution = SessionRef.resolve("3db6", in: sessions, now: now, timeZone: utc)
    #expect(resolution == .match(sessions[0]))
  }

  @Test("a shared id prefix is ambiguous, listing the candidates")
  func sharedIDPrefixIsAmbiguous() {
    let resolution = SessionRef.resolve("3", in: sessions, now: now, timeZone: utc)
    #expect(resolution == .ambiguous([sessions[0], sessions[1]]))
  }

  @Test("an HH:MM ref resolves against today's local start times only")
  func clockRefMatchesToday() {
    // Both Matt Silva sessions started at 15:01 local — but only one today.
    let resolution = SessionRef.resolve("15:01", in: sessions, now: now, timeZone: utc)
    #expect(resolution == .match(sessions[0]))
  }

  @Test("an HH:MM ref pads a single-digit hour")
  func clockRefPadsHour() {
    let early = session(
      id: "aa00aaaa-bbbb-cccc-dddd-eeeeffff0000", title: "Standup",
      started: Instant(secondsSinceEpoch: 1_786_953_900))  // 08:05Z today
    let resolution = SessionRef.resolve("8:05", in: sessions + [early], now: now, timeZone: utc)
    #expect(resolution == .match(early))
  }

  @Test("a name fragment resolves case-insensitively")
  func nameFragment() {
    let resolution = SessionRef.resolve("product", in: sessions, now: now, timeZone: utc)
    #expect(resolution == .match(sessions[1]))
  }

  @Test("a name fragment matching several sessions is ambiguous")
  func nameFragmentAmbiguous() {
    let resolution = SessionRef.resolve("matt", in: sessions, now: now, timeZone: utc)
    #expect(resolution == .ambiguous([sessions[0], sessions[2]]))
  }

  @Test("no match at all is notFound")
  func unknownRef() {
    #expect(SessionRef.resolve("zzz", in: sessions, now: now, timeZone: utc) == .notFound)
  }

  @Test("an exact full id wins even when it is also a prefix of nothing else")
  func exactID() {
    let resolution = SessionRef.resolve(
      "9c00aaaa-bbbb-cccc-dddd-eeeeffff0000", in: sessions, now: now, timeZone: utc)
    #expect(resolution == .match(sessions[2]))
  }
}
