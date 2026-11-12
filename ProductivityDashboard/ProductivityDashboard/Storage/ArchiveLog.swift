// Storage/ArchiveLog.swift
//
// Read/write access to the archive action log (Stage 6, Step D). Same
// architecture as CloudVerdictCache: a @MainActor protocol, a NoOp
// fallback, and a SwiftData implementation with explicit saves.
//
// Explicit save after EVERY mutation — the allowlist rule extended to the
// action log (ARCHITECTURE.md storage rules): a silently lost row here means a
// silently lost undo handle. A missed record still fails safe (the archive
// happened and the message is findable in the archive mailbox; only the
// one-click undo is lost), but that's a UX bug we don't accept by default.

import Foundation
import SwiftData

@MainActor
protocol ArchiveLogRecording {
    /// Persist one completed archive with its undo handle.
    func record(messageID: String, senderAddress: String,
                archivedTo: String, newUID: UInt32?, accountID: String?, at date: Date)
    /// Mark the most recent not-yet-undone entry for this message as undone.
    func markUndone(messageID: String, at date: Date)
}

/// Fallback when no store is attached (previews, or before ContentView
/// wires the ModelContext in). Archives still work; they just leave no
/// undo trail — the fail-safe direction.
@MainActor
struct NoOpArchiveLog: ArchiveLogRecording {
    func record(messageID: String, senderAddress: String,
                archivedTo: String, newUID: UInt32?, accountID: String?, at date: Date) {}
    func markUndone(messageID: String, at date: Date) {}
}

@MainActor
struct SwiftDataArchiveLog: ArchiveLogRecording {
    let context: ModelContext

    func record(messageID: String, senderAddress: String,
                archivedTo: String, newUID: UInt32?, accountID: String?, at date: Date) {
        let entry = ArchiveLogEntry(
            messageID: messageID,
            senderAddress: senderAddress,
            timestamp: date,
            archivedTo: archivedTo,
            newUID: newUID.map(Int.init),
            accountID: accountID
        )
        context.insert(entry)
        // Explicit save, never auto-save (ARCHITECTURE.md storage rules).
        try? context.save()
    }

    func markUndone(messageID: String, at date: Date) {
        // Latest open entry only: archive → undo → archive again yields two
        // rows, and an undo must close the newer one, not resurrect the old.
        var descriptor = FetchDescriptor<ArchiveLogEntry>(
            predicate: #Predicate { $0.messageID == messageID && $0.undoneAt == nil },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let entry = (try? context.fetch(descriptor))?.first else { return }
        entry.undoneAt = date
        try? context.save()
    }
}
