//
//  CalendarEventDeduplicatorTests.swift
//  ProductivityDashboardTests
//
//  Cleanup pass: the same meeting appeared twice when it was both an
//  invite on one calendar and shown by a subscribed calendar. The
//  deduplicator collapses cross-calendar copies while keeping separate
//  occurrences of a repeating event. Synthetic events only.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct CalendarEventDeduplicatorTests {

    static let nine = Date(timeIntervalSince1970: 1_800_000_000)
    static let ten = nine.addingTimeInterval(3_600)

    static func event(id: String, title: String = "Team sync", start: Date = nine,
                      end: Date? = nil, allDay: Bool = false,
                      calendar: String = "Work", externalID: String? = nil) -> CalendarEvent {
        CalendarEvent(id: id, title: title, startDate: start, endDate: end ?? start.addingTimeInterval(1_800),
                      isAllDay: allDay, calendarTitle: calendar, externalID: externalID)
    }

    @Test("Invite + subscribed-calendar copy with the same UID → one row (first kept)")
    func sameUIDAcrossCalendars() {
        let result = CalendarEventDeduplicator.deduplicate([
            Self.event(id: "a#1", calendar: "user@gmail.example", externalID: "UID-123"),
            Self.event(id: "b#1", title: "Team Sync (shared)", calendar: "Subscribed", externalID: "UID-123"),
        ])
        #expect(result.map(\.id) == ["a#1"])
    }

    @Test("Copies without a shared UID but identical title and times → one row")
    func sameShapeAcrossCalendars() {
        let result = CalendarEventDeduplicator.deduplicate([
            Self.event(id: "a#1", title: "Team sync", calendar: "Work", externalID: "UID-A"),
            Self.event(id: "b#1", title: "  team SYNC ", calendar: "Subscribed", externalID: nil),
        ])
        #expect(result.count == 1)
    }

    @Test("Occurrences of a repeating event (same UID, different starts) all stay")
    func repeatingOccurrencesKept() {
        let result = CalendarEventDeduplicator.deduplicate([
            Self.event(id: "r#1", start: Self.nine, externalID: "UID-R"),
            Self.event(id: "r#2", start: Self.nine.addingTimeInterval(86_400), externalID: "UID-R"),
            Self.event(id: "r#3", start: Self.nine.addingTimeInterval(172_800), externalID: "UID-R"),
        ])
        #expect(result.count == 3)
    }

    @Test("Different events are never merged",
          arguments: [
            ("different title", event(id: "x#1", title: "Dentist")),
            ("different start", event(id: "x#1", start: ten)),
            ("different end", event(id: "x#1", end: nine.addingTimeInterval(3_600))),
            ("all-day vs timed", event(id: "x#1", allDay: true)),
          ])
    func distinctEventsKept(_ c: (String, CalendarEvent)) {
        let result = CalendarEventDeduplicator.deduplicate([Self.event(id: "base#1"), c.1])
        #expect(result.count == 2, "\(c.0) should not merge")
    }

    @Test("Blank UIDs don't cause false merges")
    func blankUIDsIgnored() {
        let result = CalendarEventDeduplicator.deduplicate([
            Self.event(id: "a#1", title: "Standup", externalID: "  "),
            Self.event(id: "b#1", title: "Lunch", externalID: "  "),
        ])
        #expect(result.count == 2)
    }

    @Test("Exact duplicate ids collapse (ForEach needs unique ids)")
    func duplicateIDsCollapse() {
        let result = CalendarEventDeduplicator.deduplicate([
            Self.event(id: "same#1", title: "One"),
            Self.event(id: "same#1", title: "Two", start: Self.ten),
        ])
        #expect(result.map(\.title) == ["One"])
    }

    @Test("Order is preserved and output ids are unique")
    func orderAndUniqueness() {
        let input = [
            Self.event(id: "1", title: "A", start: Self.nine, externalID: "U1"),
            Self.event(id: "2", title: "A copy", start: Self.nine, externalID: "U1"),
            Self.event(id: "3", title: "B", start: Self.ten, externalID: "U2"),
        ]
        let result = CalendarEventDeduplicator.deduplicate(input)
        #expect(result.map(\.id) == ["1", "3"])
        #expect(Set(result.map(\.id)).count == result.count)
    }
}
