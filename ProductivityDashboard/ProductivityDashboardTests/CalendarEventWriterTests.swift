//
//  CalendarEventWriterTests.swift
//  ProductivityDashboardTests
//
//  Stage 8, Step C. The calendar writer and the service that pairs it with
//  the log — all against fakes, so no real calendar is touched. Release-gate
//  properties:
//    - create writes exactly the confirmed draft's fields, and re-checks the
//      calendar is still writable at write time;
//    - undo removes only an event the log holds as app-created and open,
//      only on the calendar it was created in; anything else is untouched.
//  Synthetic data only.
//

import Testing
import Foundation
import SwiftData
@testable import ProductivityDashboard

// MARK: - Fakes

final class FakeEventStore: EventStoreAdapting, @unchecked Sendable {
    struct Saved: Equatable {
        let title: String; let start: Date; let end: Date; let isAllDay: Bool; let calendarID: String
        var notes: String? = nil
    }

    var authorized = true
    var calendars = [WritableCalendar(id: "cal-work", title: "Work"), WritableCalendar(id: "cal-home", title: "Home")]
    var defaultID: String? = "cal-home"
    var saveError: Error?
    var removeError: Error?
    private(set) var saved: [Saved] = []
    private(set) var removed: [String] = []
    /// identifier → calendar ID of events that currently exist.
    var events: [String: String] = [:]
    private var counter = 0

    func isAuthorized() -> Bool { authorized }
    func writableCalendars() -> [WritableCalendar] { calendars }
    func defaultCalendarID() -> String? { defaultID }

    func saveEvent(title: String, start: Date, end: Date, isAllDay: Bool, calendarID: String, notes: String?) throws -> String {
        if let saveError { throw saveError }
        saved.append(Saved(title: title, start: start, end: end, isAllDay: isAllDay, calendarID: calendarID, notes: notes))
        counter += 1
        let id = "evt-\(counter)"
        events[id] = calendarID
        return id
    }

    func event(withIdentifier id: String) -> StoredEventInfo? {
        events[id].map { StoredEventInfo(calendarID: $0) }
    }

    var summaries: [String: CreatedEventSummary] = [:]
    func summary(withIdentifier id: String) -> CreatedEventSummary? { summaries[id] }

    func removeEvent(withIdentifier id: String) throws {
        if let removeError { throw removeError }
        removed.append(id)
        events[id] = nil
    }
}

@MainActor
final class SpyCalendarActionLog: CalendarActionLogging {
    private(set) var created: [(receipt: CreatedEventReceipt, source: EventSource, messageID: String?)] = []
    private(set) var undone: [(id: String, result: UndoCreateResult)] = []
    private var open: [String: CalendarActionRecord] = [:]

    func recordCreated(_ receipt: CreatedEventReceipt, source: EventSource, sourceMessageID: String?, at date: Date) {
        created.append((receipt, source, sourceMessageID))
        open[receipt.eventIdentifier] = CalendarActionRecord(eventIdentifier: receipt.eventIdentifier,
                                                             calendarID: receipt.calendarID, timestamp: date)
    }
    func openEntry(forEventIdentifier id: String) -> CalendarActionRecord? { open[id] }
    func markUndone(eventIdentifier id: String, result: UndoCreateResult, at date: Date) {
        undone.append((id, result))
        open[id] = nil
    }
}

// MARK: - Minting (the only way)

@MainActor
enum ConfirmedEventFixture {
    static let twoPM = Date(timeIntervalSince1970: 1_900_000_000)

    static func confirmed(title: String = "Dentist", calendarID: String = "cal-work", allDay: Bool = false,
                          source: EventSource = .manual,
                          writable: [WritableCalendar] = [WritableCalendar(id: "cal-work", title: "Work"),
                                                          WritableCalendar(id: "cal-home", title: "Home")]) throws -> ConfirmedCreateEvent {
        let values = NewEventFormValues(title: title, start: twoPM, end: twoPM.addingTimeInterval(3_600),
                                        isAllDay: allDay, calendarID: calendarID, source: source)
        guard case .valid(let draft) = NewEventValidator.validate(values, writableCalendars: writable) else {
            Issue.record("fixture draft invalid")
            throw CancellationError()
        }
        let flow = CreateEventConfirmationFlow()
        flow.request(draft)
        return try #require(flow.confirm())
    }
}

// MARK: - Writer

@MainActor
struct EventKitEventWriterTests {

    @Test("Create writes exactly the confirmed draft's fields to the chosen calendar")
    func createWritesDraft() async throws {
        let store = FakeEventStore()
        let receipt = try await EventKitEventWriter(store: store)
            .create(try ConfirmedEventFixture.confirmed(title: "Dentist", calendarID: "cal-home"))

        #expect(store.saved == [FakeEventStore.Saved(title: "Dentist", start: ConfirmedEventFixture.twoPM,
                                                     end: ConfirmedEventFixture.twoPM.addingTimeInterval(3_600),
                                                     isAllDay: false, calendarID: "cal-home")])
        #expect(receipt == CreatedEventReceipt(eventIdentifier: "evt-1", calendarID: "cal-home"))
    }

    @Test("A calendar that stopped being writable after confirmation is refused; nothing saved")
    func calendarRecheckedAtWriteTime() async throws {
        let store = FakeEventStore()
        let action = try ConfirmedEventFixture.confirmed(calendarID: "cal-work")
        store.calendars = [WritableCalendar(id: "cal-home", title: "Home")]

        await #expect(throws: CalendarWriteError.calendarNotWritable) {
            _ = try await EventKitEventWriter(store: store).create(action)
        }
        #expect(store.saved.isEmpty)
    }

    @Test("No calendar access → create refused, nothing saved")
    func notAuthorized() async throws {
        let store = FakeEventStore()
        store.authorized = false
        let action = try ConfirmedEventFixture.confirmed()
        await #expect(throws: CalendarWriteError.notAuthorized) {
            _ = try await EventKitEventWriter(store: store).create(action)
        }
        #expect(store.saved.isEmpty)
        #expect(EventKitEventWriter(store: store).writableCalendars().isEmpty)
    }

    @Test("Store save failure surfaces as saveFailed")
    func saveFailure() async throws {
        let store = FakeEventStore()
        store.saveError = NSError(domain: "test", code: 1)
        let action = try ConfirmedEventFixture.confirmed()
        await #expect(throws: CalendarWriteError.saveFailed) {
            _ = try await EventKitEventWriter(store: store).create(action)
        }
    }

    @Test("Default calendar is offered only if it's writable")
    func defaultCalendarMustBeWritable() {
        let store = FakeEventStore()
        #expect(EventKitEventWriter(store: store).defaultCalendarID() == "cal-home")
        store.defaultID = "cal-subscribed"
        #expect(EventKitEventWriter(store: store).defaultCalendarID() == nil)
    }

    @Test("Undo removes the event only when it's still on the calendar it was created in")
    func undoOutcomes() async throws {
        let store = FakeEventStore()
        let writer = EventKitEventWriter(store: store)
        store.events = ["evt-a": "cal-work", "evt-moved": "cal-home"]

        #expect(try await writer.undoCreate(eventIdentifier: "evt-a", expectedCalendarID: "cal-work") == .removed)
        #expect(try await writer.undoCreate(eventIdentifier: "evt-missing", expectedCalendarID: "cal-work") == .alreadyGone)
        #expect(try await writer.undoCreate(eventIdentifier: "evt-moved", expectedCalendarID: "cal-work") == .calendarChanged)
        #expect(store.removed == ["evt-a"])
    }
}

// MARK: - Service (writer + log)

@MainActor
struct CalendarActionServiceTests {

    @Test("A confirmed create is written once and logged once with its source kind")
    func createLogs() async throws {
        let store = FakeEventStore()
        let log = SpyCalendarActionLog()
        let service = CalendarActionService(writer: EventKitEventWriter(store: store), log: log)

        let receipt = await service.create(try ConfirmedEventFixture.confirmed(
            source: .suggestedFromEmail(sender: "pat@example.com")))

        #expect(receipt?.eventIdentifier == "evt-1")
        #expect(store.saved.count == 1)
        #expect(log.created.count == 1)
        #expect(log.created.first?.source.isSuggested == true)
        #expect(service.lastError == nil)
    }

    @Test("A failed create logs nothing and shows the error")
    func failedCreateLogsNothing() async throws {
        let store = FakeEventStore()
        store.saveError = NSError(domain: "test", code: 1)
        let log = SpyCalendarActionLog()
        let service = CalendarActionService(writer: EventKitEventWriter(store: store), log: log)

        #expect(await service.create(try ConfirmedEventFixture.confirmed()) == nil)
        #expect(log.created.isEmpty)
        #expect(service.lastError == CalendarWriteError.saveFailed.userMessage)
    }

    @Test("Undo of an app-created event removes it and closes the log entry")
    func undoAppCreated() async throws {
        let store = FakeEventStore()
        let log = SpyCalendarActionLog()
        let service = CalendarActionService(writer: EventKitEventWriter(store: store), log: log)
        let receipt = try #require(await service.create(try ConfirmedEventFixture.confirmed()))

        #expect(await service.undoCreate(eventIdentifier: receipt.eventIdentifier) == .removed)
        #expect(store.removed == [receipt.eventIdentifier])
        #expect(log.undone.map(\.id) == [receipt.eventIdentifier])
        // A second undo finds no open entry and touches nothing.
        #expect(await service.undoCreate(eventIdentifier: receipt.eventIdentifier) == .refusedNotAppCreated)
        #expect(store.removed.count == 1)
    }

    @Test("RELEASE GATE: undo never deletes an event the app didn't create")
    func undoRefusesForeignEvents() async {
        let store = FakeEventStore()
        store.events = ["someone-elses-meeting": "cal-work"]
        let log = SpyCalendarActionLog()
        let service = CalendarActionService(writer: EventKitEventWriter(store: store), log: log)

        #expect(await service.undoCreate(eventIdentifier: "someone-elses-meeting") == .refusedNotAppCreated)
        #expect(store.removed.isEmpty)
        #expect(store.events["someone-elses-meeting"] == "cal-work")
        #expect(log.undone.isEmpty)
        // A refusal must SAY so — a silent no-op reads as a broken button.
        // Read first: inside #expect the macro wraps the access in `await`,
        // which warns because this property access isn't async.
        let refusalMessage = service.lastError
        #expect(refusalMessage != nil)
    }

    @Test("Undo of an event already deleted elsewhere closes the entry and says so")
    func undoAlreadyGone() async throws {
        let store = FakeEventStore()
        let log = SpyCalendarActionLog()
        let service = CalendarActionService(writer: EventKitEventWriter(store: store), log: log)
        let receipt = try #require(await service.create(try ConfirmedEventFixture.confirmed()))
        store.events[receipt.eventIdentifier] = nil

        #expect(await service.undoCreate(eventIdentifier: receipt.eventIdentifier) == .alreadyGone)
        #expect(store.removed.isEmpty)
        #expect(log.undone.first?.result == .alreadyGone)
        #expect(service.lastError != nil)
    }

    @Test("Undo of an event moved to another calendar leaves it and the log entry alone")
    func undoMoved() async throws {
        let store = FakeEventStore()
        let log = SpyCalendarActionLog()
        let service = CalendarActionService(writer: EventKitEventWriter(store: store), log: log)
        let receipt = try #require(await service.create(try ConfirmedEventFixture.confirmed(calendarID: "cal-work")))
        store.events[receipt.eventIdentifier] = "cal-home"

        #expect(await service.undoCreate(eventIdentifier: receipt.eventIdentifier) == .calendarChanged)
        #expect(store.removed.isEmpty)
        #expect(log.undone.isEmpty)
    }
}

// MARK: - SwiftData log

@MainActor
@Suite(.serialized)
struct CalendarActionLogTests {

    static let container: ModelContainer = {
        try! ModelContainer(for: CalendarActionLogEntry.self,
                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }()

    private var log: SwiftDataCalendarActionLog { SwiftDataCalendarActionLog(context: Self.container.mainContext) }

    @Test("Record round-trips identifiers and source kind only, and saves explicitly")
    func recordRoundTrip() throws {
        log.recordCreated(CreatedEventReceipt(eventIdentifier: "log-1", calendarID: "cal-work"),
                          source: .suggestedFromEmail(sender: "pat@example.com"),
                          sourceMessageID: "<m1@example.com>", at: .now)
        let record = try #require(log.openEntry(forEventIdentifier: "log-1"))
        #expect(record.calendarID == "cal-work")
        #expect(Self.container.mainContext.hasChanges == false)

        let entries = try Self.container.mainContext.fetch(FetchDescriptor<CalendarActionLogEntry>(
            predicate: #Predicate { $0.eventIdentifier == "log-1" }))
        #expect(entries.first?.sourceKind == "fromEmail")
        #expect(entries.first?.sourceMessageID == "<m1@example.com>")
    }

    @Test("markUndone closes the entry; openEntry then returns nil")
    func markUndone() {
        log.recordCreated(CreatedEventReceipt(eventIdentifier: "log-2", calendarID: "cal-home"), source: .manual,
                          sourceMessageID: "ignored-for-manual", at: .now)
        let manual = try? Self.container.mainContext.fetch(FetchDescriptor<CalendarActionLogEntry>(
            predicate: #Predicate { $0.eventIdentifier == "log-2" }))
        #expect(manual?.first?.sourceMessageID == nil)
        log.markUndone(eventIdentifier: "log-2", result: .removed, at: .now)
        #expect(log.openEntry(forEventIdentifier: "log-2") == nil)
        #expect(Self.container.mainContext.hasChanges == false)
    }

    // Step D3 deliberately added sourceMessageID (an identifier, like the
    // classification cache's); the check below still forbids content fields.
    @Test("The persisted entry has no field that could hold a title, time, sender, subject or body")
    func noContentFields() {
        let entry = CalendarActionLogEntry(eventIdentifier: "e", calendarID: "c", sourceKind: "manual", timestamp: .now)
        let stored = Mirror(reflecting: entry).children.compactMap(\.label)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "_")).lowercased() }
        for name in stored {
            // Whole-word-ish terms: bare "end"/"start" would false-match
            // "calENDar" (the first run of this test did exactly that).
            for word in ["title", "startdate", "enddate", "starttime", "endtime", "sender",
                         "subject", "body", "location", "notes"] {
                #expect(!name.contains(word), "field \(name) looks like it could hold \(word)")
            }
        }
    }
}

// MARK: - Step D3: email reference in notes, created notice

@MainActor
struct EventNotesAndNoticeTests {

    static let writable = [WritableCalendar(id: "cal-home", title: "Home")]
    static let start = Date(timeIntervalSince1970: 4_000_000_000)

    nonisolated static func reference(link: URL? = URL(string: "https://mail.google.com/mail/?authuser=u%40gmail.example#search/rfc822msgid%3Aabc%40x.example")) -> EmailReference {
        EmailReference(messageID: "<abc@x.example>", sender: "Pat Example",
                       subject: "Re: Lunch tomorrow?", gmailLink: link)
    }

    private func draft(include: Bool, reference: EmailReference? = reference()) throws -> NewEventDraft {
        let values = NewEventFormValues(title: "Lunch", start: Self.start, end: Self.start.addingTimeInterval(3_600),
                                        calendarID: "cal-home", source: .suggestedFromEmail(sender: "Pat Example"),
                                        emailReference: reference, includeEmailReferenceInNotes: include)
        guard case .valid(let d) = NewEventValidator.validate(values, writableCalendars: Self.writable) else {
            Issue.record("invalid")
            throw CancellationError()
        }
        return d
    }

    @Test("Notes are empty unless the user ticks the reference box")
    func notesOffByDefault() throws {
        #expect(try draft(include: false).notes == nil)
        #expect(try draft(include: true, reference: nil).notes == nil)
    }

    @Test("Reference line: sender, cleaned subject, Gmail link — nothing else")
    func notesText() throws {
        let notes = try #require(try draft(include: true).notes)
        #expect(notes.hasPrefix("From an email from Pat Example: Lunch tomorrow?"))
        #expect(notes.contains("\nOpen in Gmail: https://mail.google.com/"))
        #expect(notes.split(separator: "\n").count == 2)
    }

    @Test("Hostile sender/subject can't add lines, and a non-Gmail link is dropped")
    func notesSanitized() {
        let ref = EmailReference(messageID: "m", sender: "Pat\nhttps://evil.example",
                                 subject: "Hi\r\nClick https://evil.example/x",
                                 gmailLink: URL(string: "https://evil.example/mail"))
        #expect(ref.gmailLink == nil)
        #expect(!ref.notesText.contains("\n"))
    }

    @Test("Writer saves the notes; service records the source Message-ID and raises the created notice")
    func writerAndService() async throws {
        let store = FakeEventStore()
        store.calendars = Self.writable
        let log = SpyCalendarActionLog()
        let service = CalendarActionService(writer: EventKitEventWriter(store: store), log: log)
        let d = try draft(include: true)
        let flow = CreateEventConfirmationFlow()
        flow.request(d)
        let action = try #require(flow.confirm())

        let receipt = try #require(await service.create(action))
        #expect(store.saved.first?.notes == d.notes)
        #expect(log.created.first?.messageID == "<abc@x.example>")
        #expect(service.lastCreated == CalendarActionService.CreatedNotice(
            eventIdentifier: receipt.eventIdentifier, title: "Lunch", calendarTitle: "Home"))

        #expect(await service.undoCreate(eventIdentifier: receipt.eventIdentifier) == .removed)
        #expect(service.lastCreated == nil)
    }
}

// MARK: - Step D6: one thread, one event

@MainActor
struct CreatedEventTimesTests {

    /// On a minute boundary, like every start these two paths produce.
    nonisolated static let start = Date(timeIntervalSince1970: 4_000_000_020)

    @Test("A hint at the same minute as a created event counts as created")
    func sameMinuteMatches() {
        var times = CreatedEventTimes()
        times.insert(start: Self.start, isAllDay: false)
        #expect(times.contains(EventHint(start: Self.start, isAllDay: false)))
        // Stray seconds within the same minute still match.
        #expect(times.contains(EventHint(start: Self.start.addingTimeInterval(20), isAllDay: false)))
    }

    @Test("A different time does NOT count as created")
    func differentTimeDoesNotMatch() {
        var times = CreatedEventTimes()
        times.insert(start: Self.start, isAllDay: false)
        #expect(!times.contains(EventHint(start: Self.start.addingTimeInterval(3_600), isAllDay: false)))
        #expect(!times.contains(EventHint(start: Self.start.addingTimeInterval(60), isAllDay: false)))
    }

    @Test("All-day events match by day, and never against a timed hint")
    func allDayMatchesByDay() {
        var times = CreatedEventTimes()
        times.insert(start: Self.start, isAllDay: true)
        let laterSameDay = Calendar.current.startOfDay(for: Self.start).addingTimeInterval(7 * 3_600)
        #expect(times.contains(EventHint(start: laterSameDay, isAllDay: true)))
        #expect(!times.contains(EventHint(start: laterSameDay, isAllDay: false)))
        #expect(!times.contains(EventHint(start: Self.start.addingTimeInterval(86_400), isAllDay: true)))
    }

    @Test("Nothing created → nothing matches")
    func emptyMatchesNothing() {
        let times = CreatedEventTimes()
        #expect(times.isEmpty)
        #expect(!times.contains(EventHint(start: Self.start, isAllDay: false)))
    }
}
