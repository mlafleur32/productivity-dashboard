// Storage/UnsubscribeLogEntry.swift
//
// One completed unsubscribe (Stage 7, Step D) — the action log.
//
// Privacy shape (ARCHITECTURE.md Stage 7, settled 2026-09-15): message ID, sender
// address, method, outcome, timestamp — NO subjects, NO bodies, and NO
// destination: the one-click URL and the mailto address are deliberately
// never persisted, because unsubscribe links embed per-recipient tokens.
// The sender address (normalized, same identifier class the allowlist
// already stores) is what drives the "Unsubscribed" row state.
//
// No undo field: an unsubscribe can't be reversed from the app. Only
// SUCCESSFUL actions are recorded — a failed request changed nothing, and
// the user saw the failure in an alert.

import Foundation
import SwiftData

@Model
final class UnsubscribeLogEntry {
    var messageID: String
    var senderAddress: String     // normalized (AllowedSender.normalize)
    var method: String            // UnsubscribeLogMethod raw value
    var outcome: String           // UnsubscribeLogOutcome raw value
    var httpStatus: Int?          // one-click only
    var timestamp: Date

    init(messageID: String, senderAddress: String, method: String,
         outcome: String, httpStatus: Int?, timestamp: Date) {
        self.messageID = messageID
        self.senderAddress = senderAddress
        self.method = method
        self.outcome = outcome
        self.httpStatus = httpStatus
        self.timestamp = timestamp
    }
}

enum UnsubscribeLogMethod: String, Sendable {
    case oneClick
    case mailto
    case gmail
}

enum UnsubscribeLogOutcome: String, Sendable {
    /// One-click POST accepted (2xx) — the sender is unsubscribed.
    case accepted
    /// Draft opened in Apple Mail — the user may or may not have sent it.
    case draftOpened
    /// User chose "Open in Gmail" to unsubscribe there (settled
    /// 2026-09-16). The app can't see what happened in Gmail; the mark
    /// records the user's choice so the button doesn't invite a repeat.
    case handedToGmail
}
