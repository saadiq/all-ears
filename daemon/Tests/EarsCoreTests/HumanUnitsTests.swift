import Foundation
import Testing

@testable import EarsCore

@Suite("HumanUnits")
struct HumanUnitsTests {
  // MARK: - bytes

  @Test("bytes render in decimal units, one decimal below ten")
  func bytesRendering() {
    #expect(HumanUnits.bytes(0) == "0 B")
    #expect(HumanUnits.bytes(999) == "999 B")
    #expect(HumanUnits.bytes(1_000) == "1.0 KB")
    #expect(HumanUnits.bytes(5_200) == "5.2 KB")
    #expect(HumanUnits.bytes(52_428) == "52 KB")
    #expect(HumanUnits.bytes(4_161_098) == "4.2 MB")
    #expect(HumanUnits.bytes(9_904_279) == "9.9 MB")
    #expect(HumanUnits.bytes(33_100_000) == "33 MB")
    #expect(HumanUnits.bytes(2_500_000_000) == "2.5 GB")
  }

  // MARK: - duration

  @Test("durations render as seconds, minutes, or hours+minutes")
  func durationRendering() {
    #expect(HumanUnits.duration(seconds: 0) == "0s")
    #expect(HumanUnits.duration(seconds: 45) == "45s")
    #expect(HumanUnits.duration(seconds: 60) == "1m")
    #expect(HumanUnits.duration(seconds: 1_577) == "26m")
    #expect(HumanUnits.duration(seconds: 1_860) == "31m")
    #expect(HumanUnits.duration(seconds: 3_600) == "1h")
    #expect(HumanUnits.duration(seconds: 4_320) == "1h 12m")
    #expect(HumanUnits.duration(seconds: 86_400) == "24h")
  }

  @Test("a negative duration clamps to zero rather than rendering nonsense")
  func negativeDurationClamps() {
    #expect(HumanUnits.duration(seconds: -5) == "0s")
  }

  // MARK: - clock / local date

  /// 2026-08-17T16:01:32Z.
  private let started = Instant(secondsSinceEpoch: 1_786_982_492)

  @Test("clock renders the local wall time HH:MM in the given zone")
  func clockRendersLocalTime() {
    let utc = TimeZone(identifier: "UTC")!
    #expect(HumanUnits.clock(started, timeZone: utc) == "16:01")
    // UTC+2 — the issue's example renders 16:01Z as 18:01 local.
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    #expect(HumanUnits.clock(started, timeZone: berlin) == "18:01")
  }

  @Test("localDate renders the civil date in the given zone, crossing midnight correctly")
  func localDateCrossesMidnight() {
    // 2026-08-17T23:30:00Z is already the 18th in Auckland (UTC+12).
    let lateEvening = Instant(secondsSinceEpoch: 1_787_009_400)
    let utc = TimeZone(identifier: "UTC")!
    let auckland = TimeZone(identifier: "Pacific/Auckland")!
    #expect(HumanUnits.localDate(lateEvening, timeZone: utc) == "2026-08-17")
    #expect(HumanUnits.localDate(lateEvening, timeZone: auckland) == "2026-08-18")
  }

  // MARK: - grouped integers

  @Test("grouped inserts thousands separators")
  func groupedRendering() {
    #expect(HumanUnits.grouped(0) == "0")
    #expect(HumanUnits.grouped(177) == "177")
    #expect(HumanUnits.grouped(5_745) == "5,745")
    #expect(HumanUnits.grouped(1_234_567) == "1,234,567")
  }
}
