//
//  EmailStripperTests.swift
//  ProductivityDashboardTests
//
//  Security-critical suite #2 (ARCHITECTURE.md Testing): prove quoted reply threads
//  and signatures are removed before any content is eligible for an API call.
//  Parameterized like the rules-engine tests — tuning the stripper means
//  adding a row here first, then the marker in EmailStripper.
//
//  All fixtures are SYNTHETIC (git hygiene rule): invented names, example.com
//  addresses, fabricated content. Never paste real email bodies here.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct EmailStripperTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String
        let expected: String
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "plain message untouched",
            input: "Hi team,\n\nThe meeting moved to 3pm Thursday.\n\nThanks,\nPat",
            expected: "Hi team,\n\nThe meeting moved to 3pm Thursday.\n\nThanks,\nPat"
        ),
        Case(
            name: "gmail reply: On ... wrote: plus quoted block removed",
            input: """
            Sounds good, see you then.

            On Mon, Jun 1, 2026 at 3:14 PM Alex Vega <alex@example.com> wrote:
            > Can we move the meeting to Thursday?
            > It conflicts with the review.
            """,
            expected: "Sounds good, see you then."
        ),
        Case(
            name: "bare quoted lines without attribution removed",
            input: "Agreed on both points.\n> earlier point one\n> earlier point two",
            expected: "Agreed on both points."
        ),
        Case(
            name: "rfc3676 signature delimiter removed",
            input: "Invoice attached.\n\n-- \nJordan Li\nExample Corp\n555-0100",
            expected: "Invoice attached."
        ),
        Case(
            name: "bare double-dash signature removed",
            input: "Invoice attached.\n--\nJordan Li",
            expected: "Invoice attached."
        ),
        Case(
            name: "sent-from-my-iPhone trailer removed",
            input: "Running late, start without me.\n\nSent from my iPhone",
            expected: "Running late, start without me."
        ),
        Case(
            name: "outlook original message block removed",
            input: """
            Approved, please proceed.

            -----Original Message-----
            From: Sam Reyes <sam@example.com>
            Sent: Tuesday, June 2, 2026 9:00 AM
            Subject: Budget approval

            Requesting approval for the Q3 budget.
            """,
            expected: "Approved, please proceed."
        ),
        Case(
            name: "apple mail forward block removed",
            input: "FYI below.\n\nBegin forwarded message:\n\nFrom: Kit Doyle <kit@example.com>\nSubject: Renewal notice",
            expected: "FYI below."
        ),
        Case(
            name: "gmail forward block removed",
            input: "See below.\n\n---------- Forwarded message ---------\nFrom: Kit Doyle <kit@example.com>",
            expected: "See below."
        ),
        Case(
            name: "outlook underscore separator removed",
            input: "Yes, that works for us.\n________________________________\nFrom: Ana Cole <ana@example.com>\nSent: Monday 8:12 AM",
            expected: "Yes, that works for us."
        ),
        Case(
            name: "CRLF line endings normalized before stripping",
            input: "Got it, thanks.\r\n\r\nOn Tue, Jun 2, 2026 at 1:00 PM Alex Vega <alex@example.com> wrote:\r\n> original text",
            expected: "Got it, thanks."
        ),
        Case(
            name: "signature before quote: earliest boundary wins",
            input: "Short answer: yes.\n-- \nJordan Li\nOn Mon, Jun 1, 2026 at 9:00 AM Pat Kim <pat@example.com> wrote:\n> question",
            expected: "Short answer: yes."
        ),
        Case(
            name: "content after a thread marker is dropped even if unquoted",
            input: "Top-posted reply.\nOn Mon, Jun 1, 2026 at 9:00 AM Pat Kim <pat@example.com> wrote:\n> question\nInline afterthought that we deliberately sacrifice.",
            expected: "Top-posted reply."
        ),
        Case(
            name: "message that is entirely quote strips to empty",
            input: "> line one\n> line two",
            expected: ""
        ),
        Case(
            name: "sentence containing wrote: mid-line is NOT a marker",
            input: "As Alice wrote: the deadline is firm.\nPlease plan accordingly.",
            expected: "As Alice wrote: the deadline is firm.\nPlease plan accordingly.",
        ),
        Case(
            name: "get outlook trailer removed",
            input: "Confirmed for Friday.\n\nGet Outlook for iOS",
            expected: "Confirmed for Friday."
        ),
        Case(
            name: "whitespace-only result trims to empty",
            input: "   \n\n-- \nJordan Li",
            expected: ""
        ),
    ]

    @Test("Stripper removes threads and signatures, keeps sender content", arguments: cases)
    func stripCase(_ c: Case) {
        #expect(EmailStripper.strip(c.input) == c.expected)
    }

    // The privacy direction of the bias, stated as its own test: stripping
    // never ADDS content — output is always a substring-by-lines of input.
    @Test("Stripped output never contains a line absent from the input", arguments: cases)
    func neverInvents(_ c: Case) {
        let inputLines = Set(c.input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n"))
        for line in EmailStripper.strip(c.input).components(separatedBy: "\n") where !line.isEmpty {
            #expect(inputLines.contains(line))
        }
    }
}
