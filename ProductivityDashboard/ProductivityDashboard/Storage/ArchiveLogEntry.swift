// Storage/ArchiveLogEntry.swift
//
// One completed archive action (Stage 6, Step D) — the undo ledger.
//
// Privacy shape (ARCHITECTURE.md Key decisions, settled 2026-07): message ID,
// sender address, timestamp, and the undo handle — NO subjects, NO bodies.
// The sender address is the same identifier class the allowlist already
// persists; the log UI identifies entries by sender + date alone.
//
// The undo handle is (archivedTo, newUID): where the UID MOVE put the
// message and its UID there, from UIDPLUS COPYUID. It is a HINT, not a
// guarantee — UIDs die with a UIDVALIDITY change, and a nil newUID means
// the server never told us. Undo uses it while it works and fails
// honestly when it doesn't; the message is never lost either way (it's
// in the archive mailbox, findable in Gmail).
//
// Rows are never deleted by the app; undo sets undoneAt rather than
// removing history. (An entry whose archive was undone and re-archived
// simply gets a second row.)

import Foundation
import SwiftData

@Model
final class ArchiveLogEntry {
    var messageID: String
    var senderAddress: String
    var actionKind: String        // "archive" — future actions get their own kind
    var timestamp: Date
    var archivedTo: String        // destination mailbox (e.g. "[Gmail]/All Mail")
    var newUID: Int?              // UIDPLUS COPYUID destination UID; nil = unreported
    // Stage 9: which account this message was archived FROM. Optional for
    // rows written before multiple accounts existed; undo refuses rather
    // than guessing when it is nil and more than one account is configured.
    var accountID: String?
    var undoneAt: Date?           // nil = still archived (undo offered)

    init(
        messageID: String,
        senderAddress: String,
        actionKind: String = "archive",
        timestamp: Date = .now,
        archivedTo: String,
        newUID: Int? = nil,
        accountID: String? = nil,
        undoneAt: Date? = nil
    ) {
        self.messageID = messageID
        self.senderAddress = senderAddress
        self.actionKind = actionKind
        self.timestamp = timestamp
        self.archivedTo = archivedTo
        self.newUID = newUID
        self.accountID = accountID
        self.undoneAt = undoneAt
    }
}
