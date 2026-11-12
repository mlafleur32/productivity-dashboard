//
//  AllowlistEditorTests.swift
//  ProductivityDashboardTests
//
//  Verifies the ONLY write path to the cloud allowlist (Stage 4, Step E):
//  promote / demote / remove, each followed by an explicit save (asserted
//  via !context.hasChanges — the ARCHITECTURE.md never-rely-on-auto-save rule),
//  plus the confirm-on-promote flow. The headline test: CANCELLING the
//  promote confirmation writes ZERO rows — no partial or dangling state
//  from an abandoned dialog.
//
//  One shared in-memory ModelContainer for the whole suite (multiple
//  containers for the same @Model crash the test process — see
//  ClassificationCacheTests). This suite owns the only AllowedSender
//  container in the test bundle; distinct addresses per test avoid
//  cross-test interference without clearing the store.
//

import Testing
import Foundation
import SwiftData
@testable import ProductivityDashboard

@MainActor
@Suite(.serialized)
struct AllowlistEditorTests {

    static let container: ModelContainer = {
        try! ModelContainer(
            for: AllowedSender.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private var context: ModelContext { Self.container.mainContext }
    private var editor: AllowlistEditor { AllowlistEditor(context: Self.container.mainContext) }

    private func rows(for rawAddress: String) throws -> [AllowedSender] {
        let key = AllowedSender.normalize(rawAddress)
        return try context.fetch(FetchDescriptor<AllowedSender>(
            predicate: #Predicate { $0.senderIdentifier == key }
        ))
    }

    // MARK: - Editor mutations

    @Test("Promote writes one normalized, cloud-eligible row and flushes the save")
    func promoteWritesNormalizedRow() throws {
        try editor.promote("  Promo.One@Firm.Example ")
        let found = try rows(for: "promo.one@firm.example")
        #expect(found.count == 1)
        #expect(found.first?.senderIdentifier == "promo.one@firm.example")
        #expect(found.first?.cloudEligible == true)
        // Explicit-save rule: nothing may sit unsaved after a mutation.
        #expect(!context.hasChanges)
    }

    @Test("Re-promoting the same sender (any casing) does not duplicate")
    func repromoteIsIdempotent() throws {
        try editor.promote("promo.two@firm.example")
        try editor.promote("Promo.Two@FIRM.example")
        #expect(try rows(for: "promo.two@firm.example").count == 1)
    }

    @Test("Demote keeps the row but flips it local-only; re-promote re-enables it")
    func demoteFlipsFlagAndKeepsRow() throws {
        try editor.promote("demote.one@firm.example")
        try editor.demote("demote.one@firm.example")
        var found = try rows(for: "demote.one@firm.example")
        #expect(found.count == 1)
        #expect(found.first?.cloudEligible == false)
        #expect(!context.hasChanges)

        try editor.promote("demote.one@firm.example")
        found = try rows(for: "demote.one@firm.example")
        #expect(found.count == 1)
        #expect(found.first?.cloudEligible == true)
    }

    @Test("Demoting a never-promoted address is a no-op — no row appears")
    func demoteUnknownIsNoOp() throws {
        try editor.demote("never.seen@firm.example")
        #expect(try rows(for: "never.seen@firm.example").isEmpty)
        #expect(!context.hasChanges)
    }

    @Test("setCloudEligible (the Settings toggle path) flips the flag and saves")
    func setEligibleTogglesAndSaves() throws {
        try editor.promote("toggle.one@firm.example")
        let row = try #require(try rows(for: "toggle.one@firm.example").first)
        try editor.setCloudEligible(row, to: false)
        #expect(row.cloudEligible == false)
        #expect(!context.hasChanges)
    }

    @Test("Remove deletes the row entirely")
    func removeDeletesRow() throws {
        try editor.promote("remove.one@firm.example")
        let row = try #require(try rows(for: "remove.one@firm.example").first)
        try editor.remove(row)
        #expect(try rows(for: "remove.one@firm.example").isEmpty)
        #expect(!context.hasChanges)
    }

    // MARK: - Confirm-on-promote flow

    @Test("Cancelling the promote confirmation writes ZERO rows — no dangling state")
    func cancelledConfirmationWritesNothing() throws {
        let flow = PromotionFlow()
        flow.request("cancelled@firm.example")
        // Merely ASKING (dialog on screen) must not touch the store.
        #expect(try rows(for: "cancelled@firm.example").isEmpty)

        flow.cancel()
        #expect(flow.pendingAddress == nil)
        #expect(try rows(for: "cancelled@firm.example").isEmpty)
        #expect(!context.hasChanges)
    }

    @Test("Confirming writes exactly one eligible row and clears the pending state")
    func confirmedPromotionWritesRow() throws {
        let flow = PromotionFlow()
        flow.request("confirmed@firm.example")
        try flow.confirm("confirmed@firm.example", using: editor)
        #expect(flow.pendingAddress == nil)

        let found = try rows(for: "confirmed@firm.example")
        #expect(found.count == 1)
        #expect(found.first?.cloudEligible == true)
        #expect(!context.hasChanges)
    }
}
