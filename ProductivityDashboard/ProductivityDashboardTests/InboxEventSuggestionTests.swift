//
//  InboxEventSuggestionTests.swift
//  ProductivityDashboardTests
//
//  Stage 8, Step D wiring: the view model offers "Make Event from Email…"
//  only for mail the rules allow, fetches the body (locally) ONLY when not
//  refused, and returns form values — never a draft. Plus the confirmation
//  dialog copy. Synthetic messages only.
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct InboxEventSuggestionTests {

    struct FakeCredentialsStore: CredentialsStore {
        nonisolated func save(_ credentials: IMAPCredentials) throws {}
        nonisolated func loadAll() throws -> [IMAPCredentials] {
            [
            IMAPCredentials(server: "imap.test.example", port: 993, account: "user@test.example", password: "test")
            ]
        }
        nonisolated func delete(accountID: String) throws {}
    }

    final class BodySource: MailSource, @unchecked Sendable {
        var messages: [MailMessage] = []
        var body: String?
        private(set) var bodyFetches: [UInt32] = []
        func fetchRecent(limit: Int) async throws -> [MailMessage] { messages }
        func fetchBody(accountID: String?, imapUID: UInt32) async throws -> String? {
            bodyFetches.append(imapUID)
            return body
        }
    }

    final class OffAnalyzer: CloudAnalyzing, @unchecked Sendable {
        func isConfigured() -> Bool { false }
        func analyze(_ eligible: CloudEligibleMessage, rawBody: String) async throws -> CloudVerdict {
            throw CloudAnalysisError.notConfigured
        }
    }

    private func message(id: String, dmarc: AuthVerdict = .pass, uid: UInt32 = 5) -> MailMessage {
        MailMessage(id: id, fromName: "Pat Example", fromAddress: "pat@example.com",
                    subject: "Planning meeting", date: .now,
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: dmarc),
                    imapUID: uid)
    }

    private func loaded(_ messages: [MailMessage], body: String?) async -> (InboxViewModel, BodySource) {
        let source = BodySource()
        source.messages = messages
        source.body = body
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(), mailSource: source)
        vm.cloudAnalyzer = OffAnalyzer()
        // This suite asserts exact body-fetch lists for the "Make Event from
        // Email…" path; the Step D5 background scan has its own suite below.
        vm.scansForEventHints = false
        await vm.load()
        return (vm, source)
    }

    @Test("Ordinary mail: offered, body fetched locally, suggestion is form values with default calendar")
    func ordinaryMail() async throws {
        let msg = message(id: "ok")
        let (vm, source) = await loaded([msg], body: "Let's meet on October 15, 2099 at 3:00 PM.")
        #expect(vm.canSuggestEvent(for: msg))

        let result = await vm.eventSuggestion(for: msg, defaultCalendarID: "cal-default")
        guard case .suggestion(let values, let dateFound, _) = result else {
            Issue.record("expected a suggestion")
            return
        }
        #expect(source.bodyFetches == [5])
        #expect(dateFound)
        #expect(values.calendarID == "cal-default")
        #expect(values.source == .suggestedFromEmail(sender: "Pat Example"))
    }

    @Test("DMARC-failed (spoof-shaped) mail: not offered, and the body is never fetched")
    func refusedMailFetchesNothing() async {
        let msg = message(id: "spoof", dmarc: .fail)
        let (vm, source) = await loaded([msg], body: "October 15, 2099 at 3:00 PM")
        #expect(!vm.canSuggestEvent(for: msg))
        let result = await vm.eventSuggestion(for: msg, defaultCalendarID: "cal-default")
        // The local rules engine already classifies non-list dmarc=fail
        // mail as .scam, so the scam refusal fires first — either way it's
        // refused before any body fetch.
        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(source.bodyFetches.isEmpty)
    }

    // MARK: - Dialog copy

    private func draft(source: EventSource, allDay: Bool = false) throws -> NewEventDraft {
        let start = Date(timeIntervalSince1970: 4_000_000_000)
        let values = NewEventFormValues(title: "Dentist", start: start, end: start.addingTimeInterval(3_600),
                                        isAllDay: allDay, calendarID: "cal-home", source: source)
        guard case .valid(let d) = NewEventValidator.validate(
            values, writableCalendars: [WritableCalendar(id: "cal-home", title: "Home")]) else {
            Issue.record("invalid draft")
            throw CancellationError()
        }
        return d
    }

    @Test("Dialog names title and calendar; manual events carry no suggestion label")
    func manualDialog() throws {
        let text = EventFormCopy.dialogMessage(try draft(source: .manual))
        #expect(text.contains("Dentist"))
        #expect(text.contains("Calendar: Home"))
        #expect(!text.contains("Suggested"))
    }

    @Test("Suggested events repeat the sender label in the dialog")
    func suggestedDialog() throws {
        let text = EventFormCopy.dialogMessage(try draft(source: .suggestedFromEmail(sender: "Pat Example")))
        #expect(text.contains("Suggested from an email from Pat Example — check every field."))
    }

    @Test("All-day events say so and show a single day")
    func allDayWhen() throws {
        let when = EventFormCopy.when(try draft(source: .manual, allDay: true))
        #expect(when.hasSuffix("(all day)"))
        #expect(!when.contains("–"))
    }
}

// MARK: - Step D5: on-device event hints on rows

@MainActor
struct InboxEventHintTests {

    typealias FakeCredentialsStore = InboxEventSuggestionTests.FakeCredentialsStore
    typealias BodySource = InboxEventSuggestionTests.BodySource
    typealias OffAnalyzer = InboxEventSuggestionTests.OffAnalyzer

    private func message(id: String, subject: String = "Lunch this week",
                         dmarc: AuthVerdict = .pass, uid: UInt32? = 7) -> MailMessage {
        MailMessage(id: id, fromName: "Robin Example", fromAddress: "robin@example.com",
                    subject: subject, date: .now,
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: dmarc),
                    imapUID: uid)
    }

    private func loaded(_ messages: [MailMessage], body: String?) async -> (InboxViewModel, BodySource) {
        let source = BodySource()
        source.messages = messages
        source.body = body
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(), mailSource: source)
        vm.cloudAnalyzer = OffAnalyzer()
        await vm.load()
        return (vm, source)
    }

    @Test("A time in the body becomes a hint on the row")
    func hintFromBody() async throws {
        let (vm, _) = await loaded([message(id: "m1")],
                                   body: "12:30 on October 15, 2027 confirmed")
        let hint = try #require(vm.eventHints["m1"])
        #expect(!hint.isAllDay)
        #expect(hint.label.contains("12:30") || hint.label.contains("12.30"))
    }

    @Test("No date in subject or body → no hint")
    func noHintWithoutADate() async {
        let (vm, _) = await loaded([message(id: "m2", subject: "Quick question")],
                                   body: "Do you have the slides?")
        #expect(vm.eventHints["m2"] == nil)
    }

    @Test("RELEASE GATE: refused mail is never hinted, and its body is never fetched")
    func refusedMailIsNeverScanned() async {
        let refused = message(id: "m3", dmarc: .fail)
        let (vm, source) = await loaded([refused], body: "12:30 on October 15, 2027 confirmed")
        #expect(vm.eventHints["m3"] == nil)
        #expect(source.bodyFetches.isEmpty)
    }

    @Test("Each message is scanned once per session")
    func scannedOnce() async {
        let source = BodySource()
        source.messages = [message(id: "m4")]
        source.body = "12:30 on October 15, 2027 confirmed"
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(), mailSource: source)
        vm.cloudAnalyzer = OffAnalyzer()
        await vm.load()
        let afterFirst = source.bodyFetches.count
        await vm.load()
        #expect(source.bodyFetches.count == afterFirst)
        #expect(vm.eventHints["m4"] != nil)
    }
}
