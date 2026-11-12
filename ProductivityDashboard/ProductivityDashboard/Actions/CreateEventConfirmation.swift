// Actions/CreateEventConfirmation.swift
//
// THE CREATE-EVENT GATE — Stage 8, Step A. The app's first calendar write,
// built on the same idiom as ArchiveConfirmation.swift. Two fileprivate
// inits make two guarantees structural:
//
//   1. NewEventDraft can be constructed ONLY by NewEventValidator.validate().
//      Form values — typed by the user, or suggested from an email (Step B)
//      — are just editable input; nothing becomes a draft without passing
//      every rule below.
//
//   2. ConfirmedCreateEvent can be constructed ONLY by
//      CreateEventConfirmationFlow.confirm(). The EventKit writer (Step C)
//      accepts nothing else, so "an event is created without the user
//      confirming it" is a COMPILE error.
//
// What an event may contain (ARCHITECTURE.md Stage 8): title, start, end,
// all-day, target calendar. No invitees, notes, URL, location, alarms or
// recurrence — none of those types even exist here.
//
// Pure Foundation, no EventKit: calendars are represented by identifier +
// title so everything here is unit-testable without a calendar store.

import Foundation
import Observation

// MARK: - Inputs

/// Where the form's initial values came from. Shown in the form and dialog;
/// the log records only the kind (manual / fromEmail), never the sender.
nonisolated enum EventSource: Equatable, Sendable {
    case manual
    /// Suggested on-device from an email (Stage 8 Step B). `sender` is for
    /// the "Suggested from an email from <sender>" label only.
    case suggestedFromEmail(sender: String)

    var isSuggested: Bool {
        if case .suggestedFromEmail = self { return true }
        return false
    }
}

/// A calendar that accepts new events (EventKit allowsContentModifications),
/// as listed by the writer. The form may offer only these.
nonisolated struct WritableCalendar: Identifiable, Hashable, Sendable {
    let id: String      // EKCalendar.calendarIdentifier
    let title: String
}

/// Which email a suggested event came from (Step D3, Matt 2026-09-17).
/// Used for the row's "Event created" mark (message ID only, logged) and for
/// the OPTIONAL reference line in the event notes. Never the email body.
nonisolated struct EmailReference: Equatable, Sendable {
    let messageID: String
    let sender: String
    let subject: String
    /// App-built https://mail.google.com link (GmailWebLink), or nil.
    let gmailLink: URL?

    init(messageID: String, sender: String, subject: String, gmailLink: URL?) {
        self.messageID = messageID
        self.sender = sender
        self.subject = subject
        // Defense in depth: only an app-built Gmail link may ride along.
        self.gmailLink = gmailLink.flatMap { GmailLinkOpener.isAllowed($0) ? $0 : nil }
    }

    static let maxSenderLength = 200

    /// The notes text: one sanitized "From an email…" line plus the Gmail
    /// link when available. Sender and subject are single-lined and capped,
    /// so nothing else from the email can ride into the calendar.
    var notesText: String {
        let senderLine = EventSuggester.title(fromSubject: sender)
        let cappedSender = String(senderLine.prefix(Self.maxSenderLength))
        let cleanSubject = EventSuggester.title(fromSubject: subject)
        var text = "From an email from \(cappedSender)"
        if !cleanSubject.isEmpty { text += ": \(cleanSubject)" }
        if let gmailLink { text += "\nOpen in Gmail: \(gmailLink.absoluteString)" }
        return text
    }
}

/// The New Event form's editable state. Suggestions only ever produce one
/// of these; it grants nothing until validated.
nonisolated struct NewEventFormValues: Equatable, Sendable {
    var title: String
    var start: Date?
    var end: Date?
    var isAllDay: Bool
    var calendarID: String?
    let source: EventSource
    /// Set only for "Make Event from Email…".
    var emailReference: EmailReference?
    /// User's choice in the form; off by default.
    var includeEmailReferenceInNotes: Bool

    init(title: String = "", start: Date? = nil, end: Date? = nil,
         isAllDay: Bool = false, calendarID: String? = nil,
         source: EventSource = .manual, emailReference: EmailReference? = nil,
         includeEmailReferenceInNotes: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.source = source
        self.emailReference = emailReference
        self.includeEmailReferenceInNotes = includeEmailReferenceInNotes
    }
}

// MARK: - Draft (gate 1)

nonisolated enum NewEventProblem: Equatable, Sendable, Hashable {
    case titleMissing
    case titleTooLong
    case titleHasControlCharacters
    case startMissing
    case endMissing
    case endNotAfterStart
    case durationTooLong
    case calendarMissing
    case calendarNotWritable

    var userMessage: String {
        switch self {
        case .titleMissing:              return "Enter a title."
        case .titleTooLong:              return "Title must be \(NewEventValidator.maxTitleLength) characters or fewer."
        case .titleHasControlCharacters: return "Title can't contain line breaks or control characters."
        case .startMissing:              return "Choose a start date."
        case .endMissing:                return "Choose an end date."
        case .endNotAfterStart:          return "End must be after start."
        case .durationTooLong:           return "Events can be at most \(NewEventValidator.maxDurationDays) days long."
        case .calendarMissing:           return "Choose a calendar."
        case .calendarNotWritable:       return "That calendar doesn't accept new events. Choose another."
        }
    }
}

/// A fully validated event, ready for the confirmation dialog.
/// Cannot be constructed outside this file (fileprivate init).
nonisolated struct NewEventDraft: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendar: WritableCalendar
    let source: EventSource
    let emailReference: EmailReference?
    /// Event notes: nil unless the user ticked the reference box.
    let notes: String?

    fileprivate init(title: String, start: Date, end: Date, isAllDay: Bool,
                     calendar: WritableCalendar, source: EventSource,
                     emailReference: EmailReference?, notes: String?) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.source = source
        self.emailReference = emailReference
        self.notes = notes
    }
}

enum NewEventValidator {
    nonisolated static let maxTitleLength = 200
    nonisolated static let maxDurationDays = 31

    nonisolated enum Result: Equatable, Sendable {
        case valid(NewEventDraft)
        case invalid([NewEventProblem])
    }

    /// Control characters and line/paragraph separators (a title is one line).
    nonisolated static func isForbiddenInTitle(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// The single mint site for NewEventDraft. Reports every problem at once
    /// so the form can show them together.
    ///
    /// All-day events are normalized to whole days in `calendar`'s time
    /// zone: start = start of the start day, end = start of the day AFTER
    /// the end day (EventKit's convention). A one-day all-day event may
    /// therefore have start and end on the same date in the form.
    static func validate(_ values: NewEventFormValues,
                         writableCalendars: [WritableCalendar],
                         calendar: Calendar = .current) -> Result {
        var problems: [NewEventProblem] = []

        let title = values.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            problems.append(.titleMissing)
        } else {
            if title.count > maxTitleLength { problems.append(.titleTooLong) }
            if title.unicodeScalars.contains(where: isForbiddenInTitle) {
                problems.append(.titleHasControlCharacters)
            }
        }

        var start = values.start
        var end = values.end
        if start == nil { problems.append(.startMissing) }
        if end == nil { problems.append(.endMissing) }

        if values.isAllDay, let s = start, let e = end {
            start = calendar.startOfDay(for: s)
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: e))
        }
        if let s = start, let e = end {
            if e <= s {
                problems.append(.endNotAfterStart)
            } else if e.timeIntervalSince(s) > Double(maxDurationDays) * 86_400 + 3_600 {
                // +1h tolerance for a DST shift inside a long all-day span.
                problems.append(.durationTooLong)
            }
        }

        var target: WritableCalendar?
        if let id = values.calendarID {
            target = writableCalendars.first { $0.id == id }
            if target == nil { problems.append(.calendarNotWritable) }
        } else {
            problems.append(.calendarMissing)
        }

        guard problems.isEmpty, let s = start, let e = end, let target else {
            return .invalid(problems)
        }
        let notes = values.includeEmailReferenceInNotes ? values.emailReference?.notesText : nil
        return .valid(NewEventDraft(title: title, start: s, end: e, isAllDay: values.isAllDay,
                                    calendar: target, source: values.source,
                                    emailReference: values.emailReference, notes: notes))
    }
}

// MARK: - Confirmed action (gate 2)

/// A create-event the user explicitly confirmed in the dialog.
/// Cannot be constructed any other way (fileprivate init).
nonisolated struct ConfirmedCreateEvent: Sendable {
    let draft: NewEventDraft
    let confirmedAt: Date

    fileprivate init(_ draft: NewEventDraft, confirmedAt: Date) {
        self.draft = draft
        self.confirmedAt = confirmedAt
    }
}

/// What a completed create reports back for the action log and undo.
nonisolated struct CreatedEventReceipt: Equatable, Sendable {
    let eventIdentifier: String   // EKEvent.eventIdentifier
    let calendarID: String
}

/// What an undo actually did.
nonisolated enum UndoCreateResult: Equatable, Sendable {
    case removed
    /// The event no longer exists (deleted in Calendar or on another device).
    case alreadyGone
    /// The identifier now points at an event on a different calendar than
    /// the one the app created it in — left untouched, never guessed at.
    case calendarChanged
}

/// The write boundary the gate guards (EventKit implementation:
/// EventKitEventWriter). create() takes only the confirmed type. undoCreate()
/// needs no dialog — it restores the prior state — and is reachable only
/// through CalendarActionService, which calls it solely for identifiers the
/// app itself logged as created and not yet undone.
protocol CalendarEventWriting: Sendable {
    func writableCalendars() -> [WritableCalendar]
    func defaultCalendarID() -> String?
    func create(_ action: ConfirmedCreateEvent) async throws -> CreatedEventReceipt
    func summary(eventIdentifier: String) -> CreatedEventSummary?
    func undoCreate(eventIdentifier: String, expectedCalendarID: String) async throws -> UndoCreateResult
}

// MARK: - Flow

/// Drives Save in the form → confirmation dialog → confirmed action. Same
/// state machine as the other gates: cancel mints nothing, confirm with
/// nothing pending mints nothing, one confirmation mints one action, and a
/// newer request replaces the pending one.
@Observable
final class CreateEventConfirmationFlow {
    private(set) var pending: NewEventDraft?

    /// Takes a DRAFT, not form values — only validated input can reach the
    /// dialog.
    func request(_ draft: NewEventDraft) {
        pending = draft
    }

    func cancel() {
        pending = nil
    }

    /// The single mint site for ConfirmedCreateEvent.
    func confirm(now: Date = .now) -> ConfirmedCreateEvent? {
        guard let draft = pending else { return nil }
        pending = nil
        return ConfirmedCreateEvent(draft, confirmedAt: now)
    }
}
