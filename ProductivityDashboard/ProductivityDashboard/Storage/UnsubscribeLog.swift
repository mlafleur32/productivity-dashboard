// Storage/UnsubscribeLog.swift
//
// Write access to the unsubscribe action log (Stage 7, Step D). Same
// architecture as ArchiveLog: a @MainActor protocol, a NoOp fallback, and a
// SwiftData implementation with an explicit save after every mutation.

import Foundation
import SwiftData

@MainActor
protocol UnsubscribeLogRecording {
    /// Persist one successful unsubscribe. Takes the outcome, never a URL
    /// or mailto address — the signature itself keeps destinations out.
    func record(messageID: String, senderAddress: String,
                outcome: UnsubscribeOutcome, at date: Date)
    /// Persist the user's choice to unsubscribe in Gmail instead.
    func recordGmailHandoff(messageID: String, senderAddress: String, at date: Date)
}

/// Fallback when no store is attached (previews, or before ContentView
/// wires the ModelContext in): unsubscribes still work, nothing persists.
@MainActor
struct NoOpUnsubscribeLog: UnsubscribeLogRecording {
    func record(messageID: String, senderAddress: String,
                outcome: UnsubscribeOutcome, at date: Date) {}
    func recordGmailHandoff(messageID: String, senderAddress: String, at date: Date) {}
}

@MainActor
struct SwiftDataUnsubscribeLog: UnsubscribeLogRecording {
    let context: ModelContext

    func record(messageID: String, senderAddress: String,
                outcome: UnsubscribeOutcome, at date: Date) {
        let method: UnsubscribeLogMethod
        let result: UnsubscribeLogOutcome
        let status: Int?
        switch outcome {
        case .oneClickAccepted(let code):
            (method, result, status) = (.oneClick, .accepted, code)
        case .draftHandedOff:
            (method, result, status) = (.mailto, .draftOpened, nil)
        case .redirectNeedsApproval:
            return   // nothing happened yet — never logged
        }
        insert(messageID: messageID, senderAddress: senderAddress,
               method: method, outcome: result, httpStatus: status, at: date)
    }

    func recordGmailHandoff(messageID: String, senderAddress: String, at date: Date) {
        insert(messageID: messageID, senderAddress: senderAddress,
               method: .gmail, outcome: .handedToGmail, httpStatus: nil, at: date)
    }

    private func insert(messageID: String, senderAddress: String,
                        method: UnsubscribeLogMethod, outcome: UnsubscribeLogOutcome,
                        httpStatus: Int?, at date: Date) {
        context.insert(UnsubscribeLogEntry(
            messageID: messageID,
            senderAddress: AllowedSender.normalize(senderAddress),
            method: method.rawValue,
            outcome: outcome.rawValue,
            httpStatus: httpStatus,
            timestamp: date))
        // Explicit save, never auto-save (ARCHITECTURE.md storage rules).
        try? context.save()
    }
}
