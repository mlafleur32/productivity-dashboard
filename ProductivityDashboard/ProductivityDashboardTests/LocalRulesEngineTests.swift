//
//  LocalRulesEngineTests.swift
//  ProductivityDashboardTests
//
//  Parameterized (table-driven) tests for the local rules engine, per
//  ARCHITECTURE.md — these rules get tuned repeatedly as misclassifications
//  surface, so they're fed a table of (message, expected-category) cases.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct LocalRulesEngineTests {

    struct RuleCase: Sendable, CustomTestStringConvertible {
        let name: String
        let message: MailMessage
        let expected: MailCategory
        var testDescription: String { name }
    }

    private static func msg(
        from: String = "person@example.com",
        listUnsubscribe: String? = nil,
        listId: String? = nil,
        precedence: String? = nil,
        dmarc: AuthVerdict? = nil
    ) -> MailMessage {
        let auth = dmarc.map {
            AuthenticationResults(spf: .pass, dkim: .pass, dmarc: $0)
        }
        return MailMessage(
            id: UUID().uuidString,
            fromName: nil,
            fromAddress: from,
            subject: "subject",
            date: .now,
            listUnsubscribe: listUnsubscribe,
            listId: listId,
            precedence: precedence,
            authentication: auth
        )
    }

    static let cases: [RuleCase] = [
        // Newsletter signals
        .init(name: "List-Unsubscribe present",
              message: msg(listUnsubscribe: "<https://x.example/u>"), expected: .newsletter),
        .init(name: "List-Id present",
              message: msg(listId: "Deals <deals.x.example>"), expected: .newsletter),
        .init(name: "Precedence: bulk",
              message: msg(precedence: "bulk"), expected: .newsletter),
        .init(name: "bulk local part noreply@",
              message: msg(from: "noreply@shop.example"), expected: .newsletter),
        .init(name: "marketing@ with dmarc=pass still newsletter",
              message: msg(from: "marketing@shop.example", dmarc: .pass), expected: .newsletter),

        // Scam signals
        .init(name: "dmarc=fail, no list headers -> scam",
              message: msg(from: "security@bank.example", dmarc: .fail), expected: .scam),
        .init(name: "dmarc=fail, spf/dkim irrelevant, personal-looking -> scam",
              message: msg(from: "ceo@corp.example", dmarc: .fail), expected: .scam),

        // The deliberate false-positive avoidance: a mailing list that fails
        // DMARC (lists rewrite messages) must be newsletter, NOT scam.
        .init(name: "dmarc=fail BUT has List-Id -> newsletter, not scam",
              message: msg(from: "list@groups.example", listId: "Grp <g.example>", dmarc: .fail),
              expected: .newsletter),
        .init(name: "dmarc=fail BUT has List-Unsubscribe -> newsletter, not scam",
              message: msg(listUnsubscribe: "<mailto:u@x.example>", dmarc: .fail),
              expected: .newsletter),

        // Other (the default bucket)
        .init(name: "personal mail, dmarc=pass -> other",
              message: msg(from: "alice@friend.example", dmarc: .pass), expected: .other),
        .init(name: "personal mail, no auth info -> other",
              message: msg(from: "bob@friend.example"), expected: .other),
        .init(name: "dmarc=notPerformed (not fail) -> other, not scam",
              message: msg(from: "person@corp.example", dmarc: .notPerformed), expected: .other),
    ]

    @Test("category table", arguments: cases)
    func classifies(_ testCase: RuleCase) {
        #expect(LocalRulesEngine.classify(testCase.message) == testCase.expected)
    }
}
