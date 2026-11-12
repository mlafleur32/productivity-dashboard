// Calendar/CalendarActionService.swift
//
// Stage 8, Step C. The one place that pairs calendar writes with the log.
//   - create: writer.create(confirmed) → log the receipt (source kind only).
//   - undo: ONLY for an identifier the log holds as app-created and not yet
//     undone. Anything else is refused without touching the calendar — so
//     undo can never delete an event this app didn't create.

import Foundation
import Observation

@MainActor
@Observable
final class CalendarActionService {
    private let writer: CalendarEventWriting
    var log: CalendarActionLogging

    private(set) var isWorking = false
    private(set) var lastError: String?

    /// Step D3: confirmation banner for the most recent successful create.
    nonisolated struct CreatedNotice: Equatable, Sendable, Identifiable {
        let eventIdentifier: String
        let title: String
        let calendarTitle: String
        var id: String { eventIdentifier }
    }
    private(set) var lastCreated: CreatedNotice?
    func dismissCreatedNotice() { lastCreated = nil }

    // Optional defaults (not `= EventKitEventWriter()`): default-argument
    // expressions are evaluated outside the main actor.
    init(writer: CalendarEventWriting? = nil, log: CalendarActionLogging? = nil) {
        self.writer = writer ?? EventKitEventWriter()
        self.log = log ?? NoOpCalendarActionLog()
    }

    func writableCalendars() -> [WritableCalendar] { writer.writableCalendars() }
    func defaultCalendarID() -> String? { writer.defaultCalendarID() }
    func summary(eventIdentifier: String) -> CreatedEventSummary? { writer.summary(eventIdentifier: eventIdentifier) }

    /// Execute one user-confirmed create. Returns the receipt on success.
    @discardableResult
    func create(_ action: ConfirmedCreateEvent) async -> CreatedEventReceipt? {
        isWorking = true
        defer { isWorking = false }
        do {
            let receipt = try await writer.create(action)
            log.recordCreated(receipt, source: action.draft.source,
                              sourceMessageID: action.draft.emailReference?.messageID,
                              at: action.confirmedAt)
            lastCreated = CreatedNotice(eventIdentifier: receipt.eventIdentifier,
                                        title: action.draft.title,
                                        calendarTitle: action.draft.calendar.title)
            return receipt
        } catch let error as CalendarWriteError {
            lastError = error.userMessage
        } catch {
            lastError = CalendarWriteError.saveFailed.userMessage
        }
        return nil
    }

    nonisolated enum UndoOutcome: Equatable, Sendable {
        case removed
        case alreadyGone
        case calendarChanged
        /// Not an open app-created log entry — nothing was touched.
        case refusedNotAppCreated
        case failed
    }

    func undoCreate(eventIdentifier: String, now: Date = .now) async -> UndoOutcome {
        guard let record = log.openEntry(forEventIdentifier: eventIdentifier) else {
            // Say so rather than appearing to do nothing (Matt, 2026-09-18).
            lastError = "Undo only removes events this app created and still has in its log. Nothing was changed."
            return .refusedNotAppCreated
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await writer.undoCreate(eventIdentifier: record.eventIdentifier,
                                                     expectedCalendarID: record.calendarID)
            switch result {
            case .removed:
                log.markUndone(eventIdentifier: eventIdentifier, result: result, at: now)
                if lastCreated?.eventIdentifier == eventIdentifier { lastCreated = nil }
                return .removed
            case .alreadyGone:
                log.markUndone(eventIdentifier: eventIdentifier, result: result, at: now)
                lastError = "That event was already removed from your calendar."
                return .alreadyGone
            case .calendarChanged:
                // Left open and untouched: it's been moved; the user decides.
                lastError = "That event was moved to another calendar, so it wasn't removed."
                return .calendarChanged
            }
        } catch let error as CalendarWriteError {
            lastError = error.userMessage
        } catch {
            lastError = CalendarWriteError.removeFailed.userMessage
        }
        return .failed
    }

    func dismissError() { lastError = nil }
}
