//
//  MailHeaderParserTests.swift
//  ProductivityDashboardTests
//
//  Verifies header folding, case-insensitivity, and — critically for the
//  Authentication-Results anti-forgery rule — that repeated fields are
//  returned in delivered (top-to-bottom) order.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct MailHeaderParserTests {

    @Test("Simple field extraction, case-insensitive lookup")
    func simpleFields() {
        let raw = "List-Id: Deals <deals.shop.example>\r\nPrecedence: bulk\r\n"
        let h = MailHeaderParser.parse(raw)
        #expect(h.first("list-id") == "Deals <deals.shop.example>")
        #expect(h.first("LIST-ID") == "Deals <deals.shop.example>")
        #expect(h.first("precedence") == "bulk")
        #expect(h.first("nonexistent") == nil)
    }

    @Test("Folded (continuation) lines are unfolded into one value")
    func foldedLines() {
        let raw = "List-Unsubscribe: <https://x.example/u>,\r\n" +
                  " <mailto:unsub@x.example>\r\n"
        let h = MailHeaderParser.parse(raw)
        #expect(h.first("list-unsubscribe") ==
                "<https://x.example/u>, <mailto:unsub@x.example>")
    }

    @Test("Repeated fields are preserved in delivered order (topmost first)")
    func repeatedFieldsInOrder() {
        // Two Authentication-Results, as would arrive if a sender embedded a
        // forgery below the receiver's genuine stamp.
        let raw = "Authentication-Results: mx.google.com; dmarc=fail\r\n" +
                  "Authentication-Results: mx.google.com; dmarc=pass\r\n"
        let h = MailHeaderParser.parse(raw)
        let all = h.all("authentication-results")
        #expect(all.count == 2)
        #expect(all[0] == "mx.google.com; dmarc=fail")   // topmost = genuine
        #expect(all[1] == "mx.google.com; dmarc=pass")   // below = forgery
    }

    @Test("Blank line ends the header block")
    func blankLineTerminates() {
        let raw = "Precedence: bulk\r\n\r\nBody text: not a header\r\n"
        let h = MailHeaderParser.parse(raw)
        #expect(h.first("precedence") == "bulk")
        #expect(h.first("body text") == nil)   // after the blank line, ignored
    }

    @Test("End-to-end: parsed headers feed the A-R anti-forgery parser")
    func feedsAuthenticationResults() {
        let raw = "Authentication-Results: mx.google.com; spf=pass; dkim=pass; dmarc=fail\r\n" +
                  "Authentication-Results: mx.google.com; dmarc=pass\r\n" +
                  "List-Id: Grp <g.example>\r\n"
        let h = MailHeaderParser.parse(raw)
        let auth = AuthenticationResults.parse(
            headerValues: h.all("authentication-results"),
            expectedAuthservID: "mx.google.com"
        )
        #expect(auth?.dmarc == .fail)   // topmost genuine verdict, not the forged pass
        #expect(h.first("list-id") == "Grp <g.example>")
    }
}
