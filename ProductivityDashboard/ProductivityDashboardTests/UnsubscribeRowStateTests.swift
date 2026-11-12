//
//  UnsubscribeRowStateTests.swift
//  ProductivityDashboardTests
//
//  Stage 7 (settled 2026-09-16): once a choice is recorded for a sender —
//  one-click success, email draft, or Gmail hand-off — the row shows a
//  status instead of a button, so a distracted click can't repeat it. A
//  deliberate repeat stays available (right-click). Synthetic data only.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct UnsubscribeRowStateTests {

    static func message(listUnsubscribe: String?) -> MailMessage {
        MailMessage(id: "row-1", fromName: "Synthetic List", fromAddress: "news@list.example.com",
                    subject: "Synthetic newsletter", date: .now,
                    listUnsubscribe: listUnsubscribe,
                    listUnsubscribePost: "List-Unsubscribe=One-Click",
                    listId: "<list.example.com>",
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass))
    }

    static var offerDecision: UnsubscribeEligibility.Decision {
        UnsubscribeEligibility.evaluate(message(listUnsubscribe: "<https://unsub.example.com/u>"),
                                        localCategory: .newsletter, cloudVerdict: nil)
    }

    static var noSafeDecision: UnsubscribeEligibility.Decision {
        UnsubscribeEligibility.evaluate(message(listUnsubscribe: nil),
                                        localCategory: .newsletter, cloudVerdict: nil)
    }

    @Test("No recorded choice + offer → the Unsubscribe button")
    func noChoiceShowsButton() {
        guard case .offer = UnsubscribeRowState.resolve(latestOutcome: nil, decision: Self.offerDecision,
                                                        canOpenInGmail: true) else {
            Issue.record("expected .offer")
            return
        }
    }

    @Test("Any recorded choice replaces the button with a status",
          arguments: [UnsubscribeLogOutcome.accepted, .draftOpened, .handedToGmail])
    func recordedChoiceShowsStatus(_ outcome: UnsubscribeLogOutcome) {
        let state = UnsubscribeRowState.resolve(latestOutcome: outcome, decision: Self.offerDecision,
                                                canOpenInGmail: true)
        guard case .unsubscribed(let shown, let again, let canOpen) = state else {
            Issue.record("expected .unsubscribed, got a button")
            return
        }
        #expect(shown == outcome)
        #expect(again != nil)        // deliberate repeat still possible (right-click)
        #expect(canOpen)
    }

    @Test("Gmail hand-off on a no-safe-option sender → Unsubscribed in Gmail, no repeat offer")
    func gmailOnNoSafeSender() {
        let state = UnsubscribeRowState.resolve(latestOutcome: .handedToGmail, decision: Self.noSafeDecision,
                                                canOpenInGmail: true)
        guard case .unsubscribed(.handedToGmail, let again, true) = state else {
            Issue.record("expected Unsubscribed in Gmail")
            return
        }
        #expect(again == nil)
        #expect(state.canOpenInGmail)
    }

    @Test("No recorded choice + no safe method → the no-safe-option row")
    func noChoiceNoSafe() {
        guard case .noSafeMethod(true) = UnsubscribeRowState.resolve(
            latestOutcome: nil, decision: Self.noSafeDecision, canOpenInGmail: true) else {
            Issue.record("expected .noSafeMethod")
            return
        }
    }

    @Test("Status labels")
    func statusLabels() {
        #expect(UnsubscribeDialogCopy.statusLabel(.accepted) == "Unsubscribed")
        #expect(UnsubscribeDialogCopy.statusLabel(.draftOpened) == "Unsubscribe email drafted")
        #expect(UnsubscribeDialogCopy.statusLabel(.handedToGmail) == "Unsubscribed in Gmail")
    }
}
