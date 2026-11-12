// Calendar/CalendarTypes.swift
//
// The testable surface of the calendar layer: domain model, authorization
// enum, and the CalendarSource protocol. Deliberately does NOT import
// EventKit — that lives in EventKitCalendarSource.swift. Anything in this
// file should be substitutable in tests by a fake CalendarSource without
// pulling EventKit into the test target.

import Foundation

struct CalendarEvent: Identifiable, Hashable, Sendable {
    /// Unique per OCCURRENCE: EventKit gives every occurrence of a
    /// repeating event the same eventIdentifier, so the source appends the
    /// start time. (Duplicate ids made SwiftUI's ForEach misrender rows.)
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    /// The event's iCalendar UID (EKEvent.calendarItemExternalIdentifier)
    /// when available — shared by copies of the same event on different
    /// calendars (e.g. an invite on your calendar AND a subscribed calendar
    /// that shows the same meeting). Used only for de-duplication.
    let externalID: String?

    init(id: String, title: String, startDate: Date, endDate: Date,
         isAllDay: Bool, calendarTitle: String, externalID: String? = nil) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.externalID = externalID
    }
}

/// Collapses the same event appearing on more than one calendar into a
/// single row. Pure and order-preserving (first copy wins), so it runs
/// BEFORE the display limit — duplicates never crowd out real events.
///
/// Two events are the same when either:
///   1. they share a non-empty iCalendar UID and the same start time
///      (the start time keeps separate occurrences of a repeating event
///      apart), or
///   2. they have the same title (trimmed, case-insensitive), start, end and
///      all-day flag — the fallback for calendars that don't preserve the
///      UID. Two genuinely different events with identical title and times
///      would be indistinguishable on the dashboard anyway.
enum CalendarEventDeduplicator {
    static func deduplicate(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var seenIDs = Set<String>()
        var seenExternal = Set<String>()
        var seenShape = Set<String>()
        var result: [CalendarEvent] = []

        for event in events {
            let start = event.startDate.timeIntervalSinceReferenceDate
            let end = event.endDate.timeIntervalSinceReferenceDate
            let externalKey = event.externalID
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : "\($0)|\(start)" }
            let shapeKey = "\(event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(start)|\(end)|\(event.isAllDay)"

            if seenIDs.contains(event.id) { continue }
            if let externalKey, seenExternal.contains(externalKey) { continue }
            if seenShape.contains(shapeKey) { continue }

            seenIDs.insert(event.id)
            if let externalKey { seenExternal.insert(externalKey) }
            seenShape.insert(shapeKey)
            result.append(event)
        }
        return result
    }
}

enum CalendarAuthorization: Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

// CalendarSource exists so the view model depends on a protocol, not on
// EKEventStore directly. A future test can construct CalendarViewModel
// with a fake CalendarSource and verify state transitions without hitting
// Apple's framework or the real TCC system.
protocol CalendarSource: Sendable {
    func currentAuthorization() -> CalendarAuthorization
    func requestAccess() async throws -> CalendarAuthorization
    func fetchUpcomingEvents(daysAhead: Int, limit: Int) async throws -> [CalendarEvent]
}
