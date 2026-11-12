// Storage/CalendarActionLogEntry.swift
//
// One calendar action the app performed (Stage 8) — the undo ledger.
//
// Privacy shape (ARCHITECTURE.md Stage 8): action kind, EventKit event identifier,
// calendar identifier, source kind (manual / fromEmail), timestamp, undo
// state. NO title, NO times, NO sender, NO message ID. The Recently Created
// list reads titles/times back live from EventKit by identifier.
//
// Rows are never deleted; undo sets undoneAt (and notes whether the event
// was already gone or had moved).

import Foundation
import SwiftData

@Model
final class CalendarActionLogEntry {
    var actionKind: String        // "createEvent"
    var eventIdentifier: String
    var calendarID: String
    var sourceKind: String        // "manual" | "fromEmail"
    var timestamp: Date
    var undoneAt: Date?
    var undoResult: String?       // UndoCreateResult raw name when undone
    /// Step D3 (Matt 2026-09-17): the source email's Message-ID, only for
    /// events made from an email — drives the row's "Event created" mark.
    /// Same identifier class the classification cache already stores.
    var sourceMessageID: String?

    init(actionKind: String = "createEvent", eventIdentifier: String, calendarID: String,
         sourceKind: String, timestamp: Date, undoneAt: Date? = nil, undoResult: String? = nil,
         sourceMessageID: String? = nil) {
        self.sourceMessageID = sourceMessageID
        self.actionKind = actionKind
        self.eventIdentifier = eventIdentifier
        self.calendarID = calendarID
        self.sourceKind = sourceKind
        self.timestamp = timestamp
        self.undoneAt = undoneAt
        self.undoResult = undoResult
    }
}
