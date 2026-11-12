// AgentSummaryTextTests.swift
//
// The summary is shown as plain text, so stray markdown from the model is
// removed for display. Words are never changed.

import Testing
@testable import ProductivityDashboard

struct AgentSummaryTextTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let input: String
        let expected: String
        var testDescription: String { input }
    }

    @Test("Bullets, bold and headings are dropped; prose is untouched",
          arguments: [
            Case(input: "Your dentist reminder needs a reply first.",
                 expected: "Your dentist reminder needs a reply first."),
            Case(input: "**Urgent:** Jordan needs input.",
                 expected: "Urgent: Jordan needs input."),
            Case(input: "- Reply to Jordan\n- Archive the bank alert",
                 expected: "Reply to Jordan\nArchive the bank alert"),
            Case(input: "  * Indented bullet", expected: "Indented bullet"),
            Case(input: "• Dot bullet", expected: "Dot bullet"),
            Case(input: "## Summary\nAll clear.", expected: "Summary\nAll clear."),
            Case(input: "Costs 3 - 4 dollars, item #2", expected: "Costs 3 - 4 dollars, item #2"),
            Case(input: "\n\nPadded.\n", expected: "Padded."),
          ])
    func plain(_ c: Case) {
        #expect(AgentSummaryText.plain(c.input) == c.expected)
    }
}
