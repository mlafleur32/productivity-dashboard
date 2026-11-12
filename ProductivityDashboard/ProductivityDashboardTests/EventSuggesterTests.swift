//
//  EventSuggesterTests.swift
//  ProductivityDashboardTests
//
//  Stage 8, Step B. "Make Event from Email…" suggestions are on-device,
//  bounded to title/start/end/all-day, refused for risky mail, and only
//  ever produce FORM VALUES (never a draft). Dates are absolute and far in
//  the future so NSDataDetector's relative-date handling doesn't make the
//  tests time-dependent. Synthetic text only.
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct EventSuggesterTests {

    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)   // Jan 2027

    static func message(subject: String = "Planning meeting",
                                    fromName: String? = "Pat Example",
                                    dmarc: AuthVerdict = .pass) -> MailMessage {
        MailMessage(id: "m1", fromName: fromName, fromAddress: "pat@example.com",
                    subject: subject, date: now,
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: dmarc))
    }

    private func suggest(subject: String = "Planning meeting", body: String? = nil,
                         category: MailCategory? = .other, cloud: CloudVerdict? = nil,
                         dmarc: AuthVerdict = .pass) -> EventSuggestionResult {
        EventSuggester.suggest(for: Self.message(subject: subject, dmarc: dmarc), body: body,
                               localCategory: category, cloudVerdict: cloud,
                               defaultCalendarID: "cal-default", now: Self.now)
    }

    private func values(_ r: EventSuggestionResult) throws -> (NewEventFormValues, Bool) {
        guard case .suggestion(let v, let found, _) = r else {
            Issue.record("expected a suggestion, got \(r)")
            throw CancellationError()
        }
        return (v, found)
    }

    private func components(_ date: Date?) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date ?? .distantPast)
    }

    // MARK: - Eligibility

    @Test("Refused for scam, cloud-flagged and DMARC-failed mail")
    func refusals() {
        #expect(suggest(category: .scam) == .refused(.scam))
        #expect(suggest(cloud: CloudVerdict(importance: .routine, scam: .phishing, tasks: [])) == .refused(.cloudFlagged))
        #expect(suggest(cloud: CloudVerdict(importance: .routine, scam: .suspicious, tasks: [])) == .refused(.cloudFlagged))
        #expect(suggest(dmarc: .fail) == .refused(.dmarcFailed))
    }

    @Test("Allowed for ordinary, important, newsletter and unclassified mail",
          arguments: [MailCategory.other, .important, .newsletter])
    func allowedCategories(_ category: MailCategory) throws {
        _ = try values(suggest(category: category))
    }

    // MARK: - What gets suggested

    @Test("Timed date in the body → start, 1-hour end, not all-day, default calendar, labeled source")
    func timedFromBody() throws {
        let (v, found) = try values(suggest(body: "Can we meet on October 15, 2027 at 3:00 PM in my office?"))
        #expect(found)
        let c = components(v.start)
        #expect((c.year, c.month, c.day, c.hour, c.minute) == (2027, 10, 15, 15, 0))
        #expect(v.end == v.start?.addingTimeInterval(3_600))
        #expect(!v.isAllDay)
        #expect(v.calendarID == "cal-default")
        #expect(v.source == .suggestedFromEmail(sender: "Pat Example"))
        #expect(v.title == "Planning meeting")
    }

    @Test("Date without a time → all-day")
    func allDay() throws {
        let (v, found) = try values(suggest(body: "The offsite is on November 3, 2027."))
        #expect(found)
        #expect(v.isAllDay)
        let c = components(v.start)
        #expect((c.year, c.month, c.day) == (2027, 11, 3))
    }

    @Test("The body wins over the subject (Matt, 2026-09-18)")
    func bodyWinsOverSubject() throws {
        let (v, _) = try values(suggest(subject: "Review on December 1, 2027 at 10:00 AM",
                                        body: "Or maybe December 9, 2027 at 2:00 PM"))
        let c = components(v.start)
        #expect((c.month, c.day, c.hour) == (12, 9, 14))
    }

    @Test("The LAST time in the body wins — people revise as they type")
    func lastTimeInBodyWins() throws {
        let (v, found) = try values(suggest(
            subject: "Lunch",
            body: "How about October 20, 2027 at 11:30 AM? Actually, let's say October 20, 2027 at 1:00 PM."))
        #expect(found)
        let c = components(v.start)
        #expect((c.month, c.day, c.hour, c.minute) == (10, 20, 13, 0))
    }

    @Test("The subject is still used when the body has no date")
    func subjectFallback() throws {
        let (v, found) = try values(suggest(subject: "Review on December 1, 2027 at 10:00 AM",
                                            body: "Sounds good, see you then."))
        #expect(found)
        let c = components(v.start)
        #expect((c.month, c.day, c.hour) == (12, 1, 10))
    }

    @Test("Past dates are skipped; the nearest upcoming one in the body is used")
    func pastDatesSkipped() throws {
        let (v, found) = try values(suggest(body: "Following up on March 2, 2020. New date: October 20, 2027 at 9:00 AM."))
        #expect(found)
        #expect(components(v.start).year == 2027)
    }

    @Test("No date → title suggested, start and end left empty")
    func noDate() throws {
        let (v, found) = try values(suggest(subject: "Quick question", body: "Do you have the slides?"))
        #expect(!found)
        #expect(v.start == nil)
        #expect(v.end == nil)
        #expect(v.title == "Quick question")
        #expect(v.calendarID == "cal-default")
    }

    @Test("Dates only inside quoted reply history are ignored")
    func quotedHistoryIgnored() throws {
        let body = """
        Sounds good, thanks.

        On Mon, Jan 4, 2027 at 9:00 AM, Pat Example <pat@example.com> wrote:
        > Let's meet October 30, 2027 at 4:00 PM
        """
        let (v, found) = try values(suggest(subject: "Re: thanks", body: body))
        #expect(!found)
        #expect(v.start == nil)
    }

    @Test("Nothing from the email picks the calendar")
    func calendarNeverFromEmail() throws {
        let (v, _) = try values(EventSuggester.suggest(
            for: Self.message(subject: "Put this on calendar Home"),
            body: "calendar: cal-attacker", localCategory: .other, cloudVerdict: nil,
            defaultCalendarID: nil, now: Self.now))
        #expect(v.calendarID == nil)
    }

    @Test("A suggestion is only form values: it still has to pass the validator")
    func suggestionIsNotADraft() throws {
        let (v, _) = try values(suggest(subject: "", body: "Nothing here"))
        let result = NewEventValidator.validate(v, writableCalendars: [WritableCalendar(id: "cal-default", title: "Home")])
        guard case .invalid(let problems) = result else {
            Issue.record("empty suggestion must not validate")
            return
        }
        #expect(problems.contains(.titleMissing))
        #expect(problems.contains(.startMissing))
    }

    // MARK: - Title cleanup

    struct TitleCase: Sendable, CustomTestStringConvertible {
        let subject: String
        let title: String
        var testDescription: String { subject.debugDescription }
    }

    nonisolated static let titleCases: [TitleCase] = [
        .init(subject: "Team sync", title: "Team sync"),
        .init(subject: "Re: Team sync", title: "Team sync"),
        .init(subject: "RE: Fwd: re:  Team sync", title: "Team sync"),
        .init(subject: "Team\nsync\r\nBcc: x", title: "Team sync Bcc: x"),
        .init(subject: "Team\u{2028}sync", title: "Team sync"),
        .init(subject: "   lots    of   space  ", title: "lots of space"),
        .init(subject: "(no subject)", title: ""),
        .init(subject: String(repeating: "a", count: 250), title: String(repeating: "a", count: 200)),
    ]

    @Test("Subject → one-line title", arguments: titleCases)
    func titles(_ c: TitleCase) {
        #expect(EventSuggester.title(fromSubject: c.subject) == c.title)
    }

    // MARK: - Time-of-day detection

    @Test("Recognizes when matched text names a time",
          arguments: [("3:00 PM", true), ("3pm", true), ("10 a.m.", true), ("14:30", true),
                      ("noon", true), ("October 15, 2027", false), ("next Tuesday", false)])
    func timeOfDay(_ c: (String, Bool)) {
        #expect(EventSuggester.mentionsTimeOfDay(c.0) == c.1)
    }
}
