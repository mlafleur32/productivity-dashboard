// Storage/AllowlistEditor.swift
//
// The ONLY write path to the cloud allowlist (Stage 4, Step E). Reads go
// through SwiftDataAllowlistReader; every mutation goes through here so the
// ARCHITECTURE.md rule — explicit modelContext.save() after EVERY allowlist
// mutation — lives in exactly one place. SwiftData auto-save can fail
// silently; a missed save fails privacy-safe (the sender reverts to
// local-only) but is still a UX bug, so we never rely on auto-save here.
//
// There is deliberately no "add by typed address" path anywhere in the app:
// promote() is only ever called with an address observed on real fetched
// mail (via the message-row context menu), so a typo can't silently create
// an allowlist row that never matches anything.

import Foundation
import Observation
import SwiftData

struct AllowlistEditor {
    let context: ModelContext

    /// Insert the sender as cloud-eligible, or re-enable an existing row.
    /// Idempotent: looking up before inserting means re-promoting can never
    /// duplicate or trip the unique constraint on senderIdentifier.
    func promote(_ rawAddress: String) throws {
        if let row = try existingRow(for: rawAddress) {
            row.cloudEligible = true
        } else {
            context.insert(AllowedSender(senderIdentifier: rawAddress))
        }
        try context.save()
    }

    /// Flip an existing sender back to local-only. The row is kept (so the
    /// user can re-enable from Settings); an unknown address is a no-op —
    /// there is nothing to narrow.
    func demote(_ rawAddress: String) throws {
        guard let row = try existingRow(for: rawAddress) else { return }
        row.cloudEligible = false
        try context.save()
    }

    /// Settings-toggle path: same effect as promote/demote but addressed by
    /// the row the @Query already holds, so no re-fetch.
    func setCloudEligible(_ sender: AllowedSender, to value: Bool) throws {
        sender.cloudEligible = value
        try context.save()
    }

    /// Delete the row entirely. Removal narrows the privacy boundary, so —
    /// unlike promotion — it needs no confirmation ceremony.
    func remove(_ sender: AllowedSender) throws {
        context.delete(sender)
        try context.save()
    }

    private func existingRow(for rawAddress: String) throws -> AllowedSender? {
        let key = AllowedSender.normalize(rawAddress)
        var descriptor = FetchDescriptor<AllowedSender>(
            predicate: #Predicate { $0.senderIdentifier == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

/// State machine behind the confirm-on-promote dialog. Promotion is the one
/// click that WIDENS the privacy boundary, so the UI interposes a
/// confirmation: request() only records what the user was asked about;
/// nothing touches the store until confirm(). Cancelling (button, Esc, or
/// click-away) must leave zero trace — verified by AllowlistEditorTests.
///
/// confirm() takes the address explicitly (from the dialog's `presenting`
/// value) rather than reading pendingAddress, because SwiftUI's dismissal
/// order — isPresented flipping false (which routes to cancel()) vs. the
/// button action running — is not documented, and reading cleared state
/// would silently no-op the promotion.
@Observable
@MainActor
final class PromotionFlow {
    private(set) var pendingAddress: String?

    func request(_ address: String) {
        pendingAddress = address
    }

    func cancel() {
        pendingAddress = nil
    }

    func confirm(_ address: String, using editor: AllowlistEditor) throws {
        pendingAddress = nil
        try editor.promote(address)
    }
}
