//
//  ArchiveLogTests.swift
//  ProductivityDashboardTests
//
//  SwiftDataArchiveLog: record round-trips the privacy-minimal fields,
//  markUndone closes exactly the latest open entry, and every mutation is
//  explicitly saved. ONE shared in-memory container for the whole suite
//  (multiple containers crash the test process) with .serialized so tests
//  don't interleave on the shared store.
//

import Testing
import Foundation
import SwiftData
@testable import ProductivityDashboard

@MainActor
@Suite(.serialized)
struct ArchiveLogTests {

    static let container: ModelContainer = {
        try! ModelContainer(
            for: ArchiveLogEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private var log: SwiftDataArchiveLog {
        SwiftDataArchiveLog(context: Self.container.mainContext)
    }

    private func entries(forMessageID id: String) -> [ArchiveLogEntry] {
        let descriptor = FetchDescriptor<ArchiveLogEntry>(
            predicate: #Predicate { $0.messageID == id },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? Self.container.mainContext.fetch(descriptor)) ?? []
    }

    @Test("Record round-trips the privacy-minimal fields — and only those")
    func recordRoundTrip() throws {
        log.record(messageID: "rt-1", senderAddress: "alice@example.invalid",
                   archivedTo: "[Gmail]/All Mail", newUID: 77, accountID: nil, at: .now)

        let entry = try #require(entries(forMessageID: "rt-1").first)
        #expect(entry.senderAddress == "alice@example.invalid")
        #expect(entry.archivedTo == "[Gmail]/All Mail")
        #expect(entry.newUID == 77)
        #expect(entry.actionKind == "archive")
        #expect(entry.undoneAt == nil)
        // Explicit-save rule: no dirty state left behind.
        #expect(!Self.container.mainContext.hasChanges)
    }

    @Test("A nil COPYUID handle persists as nil, not zero")
    func nilHandlePersists() throws {
        log.record(messageID: "nil-1", senderAddress: "s@example.invalid",
                   archivedTo: "Archive", newUID: nil, accountID: nil, at: .now)
        let entry = try #require(entries(forMessageID: "nil-1").first)
        #expect(entry.newUID == nil)
    }

    @Test("markUndone closes the entry and saves explicitly")
    func markUndoneCloses() throws {
        log.record(messageID: "u-1", senderAddress: "s@example.invalid",
                   archivedTo: "Archive", newUID: 5, accountID: nil, at: .now)
        log.markUndone(messageID: "u-1", at: .now)

        let entry = try #require(entries(forMessageID: "u-1").first)
        #expect(entry.undoneAt != nil)
        #expect(!Self.container.mainContext.hasChanges)
    }

    @Test("Archive → undo → archive again: undo closes the NEWEST open entry")
    func markUndoneClosesLatest() throws {
        let early = Date(timeIntervalSinceNow: -100)
        log.record(messageID: "twice", senderAddress: "s@example.invalid",
                   archivedTo: "Archive", newUID: 1, accountID: nil, at: early)
        log.markUndone(messageID: "twice", at: Date(timeIntervalSinceNow: -50))
        log.record(messageID: "twice", senderAddress: "s@example.invalid",
                   archivedTo: "Archive", newUID: 2, accountID: nil, at: .now)

        log.markUndone(messageID: "twice", at: .now)

        let rows = entries(forMessageID: "twice")
        #expect(rows.count == 2)
        // Both closed now, and history was appended to, never overwritten.
        #expect(rows.allSatisfy { $0.undoneAt != nil })
    }

    @Test("markUndone for an unknown message is a no-op, not a crash")
    func markUndoneUnknownIsNoOp() {
        log.markUndone(messageID: "never-recorded", at: .now)
        #expect(entries(forMessageID: "never-recorded").isEmpty)
    }
}
