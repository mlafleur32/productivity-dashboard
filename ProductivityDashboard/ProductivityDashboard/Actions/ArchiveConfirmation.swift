// Actions/ArchiveConfirmation.swift
//
// THE ACTION CONFIRMATION GATE — Stage 6's spine, and the app's second
// compile-time gate (ARCHITECTURE.md Security & Privacy item 6; Testing security
// test #3). Every mailbox write passes through here exactly once. The gate
// asks: did the user explicitly confirm THIS action on THIS message?
//
// Type-safe enforcement, same idiom as CloudAllowlist/CloudEligibleMessage:
// ConfirmedArchiveAction has a fileprivate init, so the ONLY code in the
// entire app that can construct one is ArchiveConfirmationFlow.confirm(),
// below. The IMAP write layer (Step B) accepts only ConfirmedArchiveAction —
// making "a write command fires without user confirmation" a COMPILE error,
// not something a future code path can forget to guard.
//
// Fail-safe by construction: the flow is a tiny state machine whose only
// minting transition is confirm() on a pending request. Cancel mints
// nothing. Confirm with nothing pending mints nothing. A second confirm
// after a mint returns nil (one confirmation, one action). A newer request
// replaces the pending one, so a confirmation can never apply to a message
// other than the one the dialog is currently naming.
//
// This file must stay small and obvious. Anything that constructs a
// ConfirmedArchiveAction lives here and nowhere else — that is the whole
// point.

import Foundation
import Observation

/// An archive action the user has explicitly confirmed via the dialog.
/// Cannot be constructed any other way (fileprivate init).
struct ConfirmedArchiveAction: Identifiable, Sendable {
    let message: MailMessage
    let confirmedAt: Date
    var id: String { message.id }

    fileprivate init(_ message: MailMessage, confirmedAt: Date) {
        self.message = message
        self.confirmedAt = confirmedAt
    }
}

/// The write boundary the gate guards. IMAPMailSource is the real
/// implementation. archive() takes only the confirmed type, so there is no
/// way to reach that write around the gate; the receipt carries the undo
/// handle for the action log. unarchive() is the reverse move — it needs
/// no dialog because it can only RESTORE a prior state, and it is only
/// reachable from an Undo click on a logged entry (same reasoning as
/// one-click allowlist demote: narrowing back needs no ceremony).
protocol MailArchiving: Sendable {
    func archive(_ action: ConfirmedArchiveAction) async throws -> ArchiveReceipt
    /// `accountID` names the account the message was archived FROM
    /// (Stage 9): the copy-back has to land in the same mailbox it left.
    func unarchive(accountID: String?, newUID: UInt32, from mailbox: String) async throws
}

/// Drives the Archive button → confirmation dialog → confirmed action
/// sequence (the dialog UI arrives in Step C; this is the logic it binds
/// to). Observable so SwiftUI can present the dialog whenever `pending`
/// is non-nil.
@Observable
final class ArchiveConfirmationFlow {

    /// The message the dialog is currently asking about, nil when no
    /// confirmation is in flight. The dialog names this message's sender
    /// and subject — the user confirms exactly what they can read.
    private(set) var pending: MailMessage?

    /// Archive button tapped: stage the request and (via observation)
    /// present the dialog. A newer request replaces any older pending one.
    func request(_ message: MailMessage) {
        pending = message
    }

    /// Dialog dismissed without confirming. Mints nothing, by design.
    func cancel() {
        pending = nil
    }

    /// The single mint site in the entire app. Returns an action for the
    /// pending message, or nil when nothing is pending (double-confirm,
    /// confirm-after-cancel, stray call — all fail safe to "no action").
    func confirm(now: Date = .now) -> ConfirmedArchiveAction? {
        guard let message = pending else { return nil }
        pending = nil
        return ConfirmedArchiveAction(message, confirmedAt: now)
    }
}
