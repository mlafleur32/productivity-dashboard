//
//  ArchiveConfirmationGateTests.swift
//  ProductivityDashboardTests
//
//  RELEASE GATE (ARCHITECTURE.md Testing security test #3, peer to the allowlist
//  gate suite): no mailbox write can ever be issued without a user-confirmed
//  action. The compile-time half of the guarantee — ConfirmedArchiveAction's
//  fileprivate init means only ArchiveConfirmationFlow.confirm() can mint
//  one, and MailArchiving accepts nothing else — cannot be unit-tested
//  (a violation doesn't compile). What CAN be tested is the runtime half:
//  every non-confirming path through the flow mints nothing, and a
//  confirmation applies to exactly the message the dialog named.
//
//  Synthetic messages only (git hygiene rule).
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct ArchiveConfirmationGateTests {

    private func message(
        id: String = UUID().uuidString,
        from: String = "sender@example.invalid",
        subject: String = "Synthetic subject"
    ) -> MailMessage {
        MailMessage(id: id, fromName: "Synthetic Sender", fromAddress: from,
                    subject: subject, date: .now)
    }

    // MARK: - Non-confirming paths mint nothing (the release gate)

    @Test("Confirm with nothing pending mints nothing")
    func confirmWithoutRequest() {
        let flow = ArchiveConfirmationFlow()
        #expect(flow.confirm() == nil)
    }

    @Test("Cancel mints nothing and clears the pending request")
    func cancelMintsNothing() {
        let flow = ArchiveConfirmationFlow()
        flow.request(message())
        flow.cancel()
        #expect(flow.pending == nil)
        #expect(flow.confirm() == nil)
    }

    @Test("A confirmation is single-use: the second confirm mints nothing")
    func confirmIsSingleUse() {
        let flow = ArchiveConfirmationFlow()
        flow.request(message())
        #expect(flow.confirm() != nil)
        #expect(flow.confirm() == nil)
    }

    @Test("Request after cancel needs its own confirmation")
    func cancelDoesNotBleedForward() {
        let flow = ArchiveConfirmationFlow()
        flow.request(message(id: "cancelled"))
        flow.cancel()
        flow.request(message(id: "fresh"))
        let action = flow.confirm()
        #expect(action?.message.id == "fresh")
    }

    // MARK: - A confirmation applies to exactly the named message

    @Test("Confirm mints exactly one action for exactly the pending message")
    func confirmMintsThePendingMessage() throws {
        let flow = ArchiveConfirmationFlow()
        let msg = message(id: "the-one", from: "alice@firm.invalid", subject: "Q3")
        flow.request(msg)

        let action = try #require(flow.confirm())
        #expect(action.message.id == "the-one")
        #expect(action.message.fromAddress == "alice@firm.invalid")
        #expect(flow.pending == nil)
    }

    @Test("A newer request replaces the pending one — confirm never applies to a stale message")
    func newerRequestReplacesPending() throws {
        let flow = ArchiveConfirmationFlow()
        flow.request(message(id: "stale"))
        flow.request(message(id: "current"))

        let action = try #require(flow.confirm())
        #expect(action.message.id == "current")
        // And the stale one was never minted: nothing else is pending.
        #expect(flow.confirm() == nil)
    }

    @Test("Pending exposes the message the dialog will name")
    func pendingIsReadableForTheDialog() {
        let flow = ArchiveConfirmationFlow()
        let msg = message(subject: "Named in the dialog")
        flow.request(msg)
        #expect(flow.pending?.subject == "Named in the dialog")
    }

    @Test("The minted action records when it was confirmed")
    func confirmedAtIsStamped() throws {
        let flow = ArchiveConfirmationFlow()
        flow.request(message())
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let action = try #require(flow.confirm(now: stamp))
        #expect(action.confirmedAt == stamp)
    }
}
