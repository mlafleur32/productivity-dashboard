//
//  CreateEventConfirmationGateTests.swift
//  ProductivityDashboardTests
//
//  RELEASE GATE (Stage 8, Step A — peer to ArchiveConfirmationGateTests).
//  Proves at runtime what the compile-time gates in
//  Actions/CreateEventConfirmation.swift rely on:
//    1. Only form values that pass every rule become a NewEventDraft.
//    2. Every non-confirming path through the flow mints nothing, and a
//       confirmation applies to exactly the draft the dialog named.
//  Suggested-from-email values get NO special treatment: same validator.
//  Synthetic data only; fixed time zone so all-day math is deterministic.
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct CreateEventConfirmationGateTests {

    // MARK: - Fixtures

    nonisolated static let work = WritableCalendar(id: "cal-work", title: "Work")
    nonisolated static let home = WritableCalendar(id: "cal-home", title: "Home")
    nonisolated static let writable = [work, home]

    nonisolated static let chicago: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    /// 2026-10-01 14:00 Chicago.
    nonisolated static let twoPM: Date = {
        chicago.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14))!
    }()

    nonisolated static func values(
        title: String = "Dentist",
        start: Date? = twoPM,
        end: Date? = twoPM.addingTimeInterval(3_600),
        allDay: Bool = false,
        calendarID: String? = "cal-work",
        source: EventSource = .manual
    ) -> NewEventFormValues {
        NewEventFormValues(title: title, start: start, end: end, isAllDay: allDay,
                           calendarID: calendarID, source: source)
    }

    private func validate(_ v: NewEventFormValues) -> NewEventValidator.Result {
        NewEventValidator.validate(v, writableCalendars: Self.writable, calendar: Self.chicago)
    }

    private func draft(_ v: NewEventFormValues = Self.values()) throws -> NewEventDraft {
        guard case .valid(let d) = validate(v) else {
            Issue.record("expected a valid draft")
            throw CancellationError()
        }
        return d
    }

    // MARK: - Validation table

    struct ProblemCase: Sendable, CustomTestStringConvertible {
        let name: String
        let values: NewEventFormValues
        let problems: Set<NewEventProblem>   // empty = valid
        var testDescription: String { name }
    }

    nonisolated static let problemCases: [ProblemCase] = [
        .init(name: "timed event, 1 hour", values: values(), problems: []),
        .init(name: "title trimmed is fine", values: values(title: "  Dentist  "), problems: []),
        .init(name: "exactly 200-char title", values: values(title: String(repeating: "a", count: 200)), problems: []),
        .init(name: "emoji/accents allowed", values: values(title: "Café ☕️ with Zoë"), problems: []),
        .init(name: "suggested source, valid values", values: values(source: EventSource.suggestedFromEmail(sender: "a@example.com")), problems: []),
        .init(name: "all-day single day (same start/end date)",
              values: values(start: twoPM, end: twoPM, allDay: true), problems: []),
        .init(name: "31-day all-day span", values: values(start: twoPM, end: twoPM.addingTimeInterval(30 * 86_400), allDay: true), problems: []),

        .init(name: "empty title", values: values(title: ""), problems: [.titleMissing]),
        .init(name: "whitespace-only title", values: values(title: " \n\t "), problems: [.titleMissing]),
        .init(name: "201-char title", values: values(title: String(repeating: "a", count: 201)), problems: [.titleTooLong]),
        .init(name: "newline inside title", values: values(title: "Dentist\nBcc: x"), problems: [.titleHasControlCharacters]),
        .init(name: "tab inside title", values: values(title: "Den\ttist"), problems: [.titleHasControlCharacters]),
        .init(name: "Unicode line separator", values: values(title: "Den\u{2028}tist"), problems: [.titleHasControlCharacters]),
        .init(name: "no start", values: values(start: nil), problems: [.startMissing]),
        .init(name: "no end", values: values(end: nil), problems: [.endMissing]),
        .init(name: "end equals start (timed)", values: values(end: twoPM), problems: [.endNotAfterStart]),
        .init(name: "end before start", values: values(end: twoPM.addingTimeInterval(-60)), problems: [.endNotAfterStart]),
        .init(name: "all-day end day before start day",
              values: values(start: twoPM, end: twoPM.addingTimeInterval(-86_400), allDay: true), problems: [.endNotAfterStart]),
        .init(name: "32-day timed event", values: values(end: twoPM.addingTimeInterval(32 * 86_400)), problems: [.durationTooLong]),
        .init(name: "no calendar", values: values(calendarID: nil), problems: [.calendarMissing]),
        .init(name: "calendar not in writable list (e.g. subscribed)",
              values: values(calendarID: "cal-subscribed"), problems: [.calendarNotWritable]),
        .init(name: "everything wrong at once",
              values: values(title: "", start: nil, end: nil, calendarID: nil),
              problems: [.titleMissing, .startMissing, .endMissing, .calendarMissing]),
    ]

    @Test("New event validation", arguments: problemCases)
    func validation(_ c: ProblemCase) {
        switch validate(c.values) {
        case .valid:
            #expect(c.problems.isEmpty, "expected problems \(c.problems)")
        case .invalid(let problems):
            #expect(Set(problems) == c.problems)
        }
    }

    @Test("A valid draft carries trimmed title, target calendar and source")
    func draftContents() throws {
        let d = try draft(Self.values(title: "  Team sync ", calendarID: "cal-home",
                                 source: EventSource.suggestedFromEmail(sender: "boss@example.com")))
        #expect(d.title == "Team sync")
        #expect(d.calendar == Self.home)
        #expect(d.source == .suggestedFromEmail(sender: "boss@example.com"))
        #expect(d.start == Self.twoPM)
        #expect(!d.isAllDay)
    }

    @Test("All-day events normalize to whole days (end = start of the next day)")
    func allDayNormalization() throws {
        let d = try draft(Self.values(start: Self.twoPM, end: Self.twoPM, allDay: true))
        let expectedStart = Self.chicago.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let expectedEnd = Self.chicago.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        #expect(d.isAllDay)
        #expect(d.start == expectedStart)
        #expect(d.end == expectedEnd)
    }

    @Test("A writable-calendar list change invalidates a previously chosen calendar")
    func calendarMustStillBeWritable() {
        let result = NewEventValidator.validate(Self.values(calendarID: "cal-work"),
                                                writableCalendars: [Self.home], calendar: Self.chicago)
        #expect(result == .invalid([.calendarNotWritable]))
    }

    // MARK: - Confirmation flow: non-confirming paths mint nothing

    @Test("Confirm with nothing pending mints nothing")
    func confirmWithoutRequest() {
        #expect(CreateEventConfirmationFlow().confirm() == nil)
    }

    @Test("Cancel mints nothing and clears the pending request")
    func cancelMintsNothing() throws {
        let flow = CreateEventConfirmationFlow()
        flow.request(try draft())
        flow.cancel()
        #expect(flow.pending == nil)
        #expect(flow.confirm() == nil)
    }

    @Test("A confirmation is single-use")
    func confirmIsSingleUse() throws {
        let flow = CreateEventConfirmationFlow()
        flow.request(try draft())
        #expect(flow.confirm() != nil)
        #expect(flow.confirm() == nil)
    }

    @Test("Request after cancel needs its own confirmation")
    func cancelDoesNotBleedForward() throws {
        let flow = CreateEventConfirmationFlow()
        flow.request(try draft(Self.values(title: "Cancelled")))
        flow.cancel()
        flow.request(try draft(Self.values(title: "Fresh")))
        #expect(flow.confirm()?.draft.title == "Fresh")
    }

    // MARK: - Confirmation applies to exactly the named draft

    @Test("Confirm mints exactly the pending draft")
    func confirmMintsPendingDraft() throws {
        let flow = CreateEventConfirmationFlow()
        let pending = try draft(Self.values(title: "The one", calendarID: "cal-home"))
        flow.request(pending)
        let action = try #require(flow.confirm())
        #expect(action.draft == pending)
        #expect(flow.pending == nil)
    }

    @Test("A newer request replaces the pending one — confirm never applies to a stale draft")
    func newerRequestReplacesPending() throws {
        let flow = CreateEventConfirmationFlow()
        flow.request(try draft(Self.values(title: "Stale")))
        flow.request(try draft(Self.values(title: "Current")))
        #expect(flow.confirm()?.draft.title == "Current")
        #expect(flow.confirm() == nil)
    }

    @Test("The minted action records when it was confirmed")
    func confirmedAtIsStamped() throws {
        let flow = CreateEventConfirmationFlow()
        flow.request(try draft())
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try #require(flow.confirm(now: stamp)).confirmedAt == stamp)
    }
}
