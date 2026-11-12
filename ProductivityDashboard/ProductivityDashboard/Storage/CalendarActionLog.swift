// Storage/CalendarActionLog.swift
//
// Read/write access to the calendar action log (Stage 8, Step C). Same
// architecture as ArchiveLog: a @MainActor protocol, a NoOp fallback, and a
// SwiftData implementation with an explicit save after every mutation.

import Foundation
import SwiftData

/// A log row as the service sees it (decoupled from the @Model class).
nonisolated struct CalendarActionRecord: Equatable, Sendable {
    let eventIdentifier: String
    let calendarID: String
    let timestamp: Date
}

@MainActor
protocol CalendarActionLogging {
    func recordCreated(_ receipt: CreatedEventReceipt, source: EventSource,
                       sourceMessageID: String?, at date: Date)
    /// The latest not-yet-undone entry for this identifier, if any.
    func openEntry(forEventIdentifier id: String) -> CalendarActionRecord?
    func markUndone(eventIdentifier id: String, result: UndoCreateResult, at date: Date)
}

@MainActor
struct NoOpCalendarActionLog: CalendarActionLogging {
    func recordCreated(_ receipt: CreatedEventReceipt, source: EventSource,
                       sourceMessageID: String?, at date: Date) {}
    func openEntry(forEventIdentifier id: String) -> CalendarActionRecord? { nil }
    func markUndone(eventIdentifier id: String, result: UndoCreateResult, at date: Date) {}
}

@MainActor
struct SwiftDataCalendarActionLog: CalendarActionLogging {
    let context: ModelContext

    func recordCreated(_ receipt: CreatedEventReceipt, source: EventSource,
                       sourceMessageID: String?, at date: Date) {
        context.insert(CalendarActionLogEntry(
            eventIdentifier: receipt.eventIdentifier,
            calendarID: receipt.calendarID,
            sourceKind: source.isSuggested ? "fromEmail" : "manual",
            timestamp: date,
            sourceMessageID: source.isSuggested ? sourceMessageID : nil))
        // Explicit save, never auto-save (ARCHITECTURE.md storage rules).
        try? context.save()
    }

    func openEntry(forEventIdentifier id: String) -> CalendarActionRecord? {
        latestOpen(id).map {
            CalendarActionRecord(eventIdentifier: $0.eventIdentifier, calendarID: $0.calendarID, timestamp: $0.timestamp)
        }
    }

    func markUndone(eventIdentifier id: String, result: UndoCreateResult, at date: Date) {
        guard let entry = latestOpen(id) else { return }
        entry.undoneAt = date
        entry.undoResult = String(describing: result)
        try? context.save()
    }

    /// Fetch by identifier ONLY, then filter "not yet undone" in Swift: a
    /// #Predicate comparing an optional Date to nil is the fragile part of
    /// this query, and a fetch that throws would look to the user like an
    /// Undo button that does nothing (Matt, 2026-09-18).
    private func latestOpen(_ id: String) -> CalendarActionLogEntry? {
        let descriptor = FetchDescriptor<CalendarActionLogEntry>(
            predicate: #Predicate { $0.eventIdentifier == id },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        return (try? context.fetch(descriptor))?.first { $0.undoneAt == nil }
    }
}
