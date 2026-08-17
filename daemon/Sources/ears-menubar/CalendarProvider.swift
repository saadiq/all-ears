import EarsCore
import EarsMenuKit
import EventKit
import Foundation

/// The EventKit shim: requests calendar access lazily on first use and maps
/// today's nearby events into the pure ``CalendarEventInfo`` shape
/// ``CalendarMatching`` consumes. All EventKit types stay inside this file —
/// `EarsMenuKit` never imports EventKit, so the matching logic tests without
/// a calendar grant.
///
/// `@MainActor` rather than `Sendable`: `EKEventStore` doesn't conform to
/// `Sendable`, and the app model that owns this provider is already
/// main-actor, so there is no isolation to cross.
@MainActor
final class CalendarProvider {
  private let store = EKEventStore()

  /// Events overlapping a window around now (4 h back, 2 h forward), or
  /// `nil` when access is denied or the request fails — the caller starts
  /// the session unenriched either way (calendar is a garnish, never a gate).
  func eventsAroundNow() async -> [CalendarEventInfo]? {
    let granted = (try? await store.requestFullAccessToEvents()) ?? false
    guard granted else { return nil }
    let now = Date()
    let predicate = store.predicateForEvents(
      withStart: now.addingTimeInterval(-4 * 3_600),
      end: now.addingTimeInterval(2 * 3_600),
      calendars: nil)
    return store.events(matching: predicate).map { event in
      let matchText = [event.location, event.notes, event.url?.absoluteString]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
      let attendees: [CalendarAttendee] = (event.attendees ?? []).compactMap { participant in
        guard participant.participantType == .person, let name = participant.name,
          !name.isEmpty
        else { return nil }
        return CalendarAttendee(name: name, isCurrentUser: participant.isCurrentUser)
      }
      return CalendarEventInfo(
        title: event.title ?? "",
        start: Instant(secondsSinceEpoch: event.startDate.timeIntervalSince1970),
        end: Instant(secondsSinceEpoch: event.endDate.timeIntervalSince1970),
        matchText: matchText,
        attendees: attendees,
        // Carried through rather than filtered here: which rows can be the
        // meeting is `CalendarMatching`'s call, and it is the tier-0 pure
        // layer that gets to be tested without a calendar grant.
        isAllDay: event.isAllDay)
    }
  }
}
