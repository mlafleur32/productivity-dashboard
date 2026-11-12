// Calendar/EventKitEventWriter.swift
//
// Stage 8, Step C. The ONLY calendar write code in the app. Implements
// CalendarEventWriting on top of a thin store seam (EventStoreAdapting) so
// every rule here is unit-tested against a fake store; the real EventKit
// adapter below is deliberately trivial.
//
// Rules:
//   - create() accepts only ConfirmedCreateEvent (mintable only by the
//     confirmation dialog). The target calendar is re-checked against the
//     CURRENT writable list at write time — a calendar that became
//     read-only or disappeared since the form opened is refused.
//   - Writes exactly title, start, end, all-day, calendar, and — only when
//     the user ticked it — the one-line email reference in notes (Step D3).
//     Nothing else is settable through the seam (no invitees, URL, location,
//     alarms, recurrence, email body).
//   - undoCreate() removes one event by identifier, and only if it's still
//     on the calendar the app created it in. Missing → .alreadyGone; moved
//     → .calendarChanged (left alone).
//
// No new entitlements or permissions: the app already holds calendar full
// access (EventKit has no read-only level; see EventKitCalendarSource).

import EventKit
import Foundation

nonisolated enum CalendarWriteError: Error, Equatable, Sendable {
    case notAuthorized
    case calendarNotWritable
    case saveFailed
    case removeFailed

    var userMessage: String {
        switch self {
        case .notAuthorized:       return "The app doesn't have access to your calendars. Turn it on in System Settings → Privacy & Security → Calendars."
        case .calendarNotWritable: return "That calendar no longer accepts new events. Choose another calendar."
        case .saveFailed:          return "Couldn't save the event to your calendar. Nothing was added."
        case .removeFailed:        return "Couldn't remove the event. It's still in your calendar."
        }
    }
}

nonisolated struct StoredEventInfo: Equatable, Sendable {
    let calendarID: String
}

/// What the Recently Created list shows, read back LIVE from the calendar
/// (the log itself stores no title or time).
nonisolated struct CreatedEventSummary: Equatable, Sendable {
    let title: String
    let start: Date
    let isAllDay: Bool
}

/// Everything the writer needs from a calendar store — and nothing more.
protocol EventStoreAdapting: Sendable {
    func isAuthorized() -> Bool
    func writableCalendars() -> [WritableCalendar]
    func defaultCalendarID() -> String?
    /// Save a new single, non-recurring event. Returns its identifier.
    func saveEvent(title: String, start: Date, end: Date, isAllDay: Bool, calendarID: String, notes: String?) throws -> String
    func event(withIdentifier id: String) -> StoredEventInfo?
    func summary(withIdentifier id: String) -> CreatedEventSummary?
    func removeEvent(withIdentifier id: String) throws
}

final class EventKitEventWriter: CalendarEventWriting {
    private let store: EventStoreAdapting

    init(store: EventStoreAdapting? = nil) {
        self.store = store ?? EKEventStoreAdapter()
    }

    func writableCalendars() -> [WritableCalendar] {
        guard store.isAuthorized() else { return [] }
        return store.writableCalendars()
    }

    /// The macOS default calendar, but only if it's actually writable.
    func defaultCalendarID() -> String? {
        guard store.isAuthorized(), let id = store.defaultCalendarID(),
              store.writableCalendars().contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func create(_ action: ConfirmedCreateEvent) async throws -> CreatedEventReceipt {
        guard store.isAuthorized() else { throw CalendarWriteError.notAuthorized }
        let draft = action.draft
        guard store.writableCalendars().contains(where: { $0.id == draft.calendar.id }) else {
            throw CalendarWriteError.calendarNotWritable
        }
        let identifier: String
        do {
            identifier = try store.saveEvent(title: draft.title, start: draft.start, end: draft.end,
                                             isAllDay: draft.isAllDay, calendarID: draft.calendar.id,
                                             notes: draft.notes)
        } catch {
            throw CalendarWriteError.saveFailed
        }
        guard !identifier.isEmpty else { throw CalendarWriteError.saveFailed }
        return CreatedEventReceipt(eventIdentifier: identifier, calendarID: draft.calendar.id)
    }

    func summary(eventIdentifier: String) -> CreatedEventSummary? {
        guard store.isAuthorized() else { return nil }
        return store.summary(withIdentifier: eventIdentifier)
    }

    func undoCreate(eventIdentifier: String, expectedCalendarID: String) async throws -> UndoCreateResult {
        guard store.isAuthorized() else { throw CalendarWriteError.notAuthorized }
        guard let info = store.event(withIdentifier: eventIdentifier) else { return .alreadyGone }
        guard info.calendarID == expectedCalendarID else { return .calendarChanged }
        do {
            try store.removeEvent(withIdentifier: eventIdentifier)
        } catch {
            throw CalendarWriteError.removeFailed
        }
        return .removed
    }
}

// MARK: - Real EventKit adapter (kept trivial; the rules live above)

final class EKEventStoreAdapter: EventStoreAdapting {
    private let store = EKEventStore()

    func isAuthorized() -> Bool {
        // Demo mode / preview canvas: the real calendar is never written.
        guard !RealIOGuard.isBlocked else { return false }
        return EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func writableCalendars() -> [WritableCalendar] {
        store.calendars(for: .event)
            .filter { $0.allowsContentModifications && $0.type != .subscription && $0.type != .birthday }
            .map { WritableCalendar(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func defaultCalendarID() -> String? {
        store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    func saveEvent(title: String, start: Date, end: Date, isAllDay: Bool, calendarID: String, notes: String?) throws -> String {
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            throw CalendarWriteError.calendarNotWritable
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.notes = notes   // only the optional reference line (Step D3)
        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw CalendarWriteError.saveFailed }
        return id
    }

    func event(withIdentifier id: String) -> StoredEventInfo? {
        guard let event = store.event(withIdentifier: id), let calendar = event.calendar else { return nil }
        return StoredEventInfo(calendarID: calendar.calendarIdentifier)
    }

    func summary(withIdentifier id: String) -> CreatedEventSummary? {
        guard let event = store.event(withIdentifier: id) else { return nil }
        return CreatedEventSummary(title: event.title ?? "(no title)", start: event.startDate, isAllDay: event.isAllDay)
    }

    func removeEvent(withIdentifier id: String) throws {
        guard let event = store.event(withIdentifier: id) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }
}
