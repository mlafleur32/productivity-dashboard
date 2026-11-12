// Calendar/EventKitCalendarSource.swift
//
// The only file in the project that imports EventKit. Wraps EKEventStore
// behind the CalendarSource protocol so the rest of the app (and tests)
// can stay framework-free.

import EventKit
import Foundation

final class EventKitCalendarSource: CalendarSource {
    private let store = EKEventStore()

    func currentAuthorization() -> CalendarAuthorization {
        // Demo mode / preview canvas: never read the real calendar.
        if RealIOGuard.isBlocked { return .denied }
        return map(EKEventStore.authorizationStatus(for: .event))
    }

    // "Full access" sounds broader than what we need (ARCHITECTURE.md scopes the
    // app to a read-only dashboard), but EventKit's post-macOS-14 model has
    // no read-only level: .writeOnly grants create-event but NOT read, and
    // .fullAccess grants read+write. We must request .fullAccess to read
    // events at all. This type never writes. The app's only calendar writes
    // (Stage 8) live in EventKitEventWriter, reachable solely through the
    // create-event confirmation gate.
    func requestAccess() async throws -> CalendarAuthorization {
        if RealIOGuard.isBlocked { return .denied }
        _ = try await store.requestFullAccessToEvents()
        return currentAuthorization()
    }

    func fetchUpcomingEvents(daysAhead: Int, limit: Int) async throws -> [CalendarEvent] {
        if RealIOGuard.isBlocked { return [] }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let all = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { ek in
                CalendarEvent(
                    // Occurrence-unique: repeating events share eventIdentifier.
                    id: "\(ek.eventIdentifier ?? UUID().uuidString)#\(Int(ek.startDate.timeIntervalSince1970))",
                    title: ek.title ?? "(no title)",
                    startDate: ek.startDate,
                    endDate: ek.endDate,
                    isAllDay: ek.isAllDay,
                    calendarTitle: ek.calendar?.title ?? "",
                    externalID: ek.calendarItemExternalIdentifier
                )
            }
        // De-duplicate across calendars BEFORE limiting, so an invite that
        // also appears on a subscribed calendar shows once and doesn't push
        // a real event out of the list.
        return Array(CalendarEventDeduplicator.deduplicate(all).prefix(limit))
    }

    private func map(_ status: EKAuthorizationStatus) -> CalendarAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        // .writeOnly: user granted only event-creation, not reading. For our
        // read-only dashboard that's equivalent to no access — surface as
        // .denied so the UI shows the "access is off" state instead of
        // pretending we're authorized and returning zero events.
        case .denied, .writeOnly: return .denied
        case .fullAccess, .authorized: return .authorized
        @unknown default: return .denied
        }
    }
}
