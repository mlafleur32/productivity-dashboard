//
//  CloudUsageLedgerTests.swift
//  ProductivityDashboardTests
//
//  Each test gets its own throwaway UserDefaults suite so nothing touches
//  the real app preferences and tests can't contaminate one another.
//

import Testing
import Foundation
@testable import ProductivityDashboard

// @MainActor: the app target defaults to MainActor isolation, so its
// types (and their conformances) are main-actor-isolated; running the
// suite there too removes the cross-isolation warnings (cleanup pass).
@MainActor
struct CloudUsageLedgerTests {

    private func freshLedger() -> (CloudUsageLedger, UserDefaults, String) {
        let suiteName = "CloudUsageLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (CloudUsageLedger(defaults: defaults), defaults, suiteName)
    }

    @Test("Fresh ledger reports all zeros and no since date")
    func freshIsEmpty() {
        let (ledger, _, suite) = freshLedger()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(ledger.totals() == CloudUsageTotals())
    }

    @Test("Recording accumulates counts, tokens, and cost across calls")
    func accumulation() {
        let (ledger, _, suite) = freshLedger()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        ledger.record(inputTokens: 1_000, outputTokens: 200, model: .opus48)
        ledger.record(inputTokens: 500, outputTokens: 100, model: .opus48)

        let totals = ledger.totals()
        #expect(totals.analysisCount == 2)
        #expect(totals.inputTokens == 1_500)
        #expect(totals.outputTokens == 300)
        // Opus 4.8: $5/MTok in, $25/MTok out → 5 and 25 microdollars/token.
        #expect(totals.estimatedMicrodollars == 1_500 * 5 + 300 * 25)
        #expect(totals.since != nil)
    }

    @Test("Cost is priced per call with the model that served it")
    func perModelPricing() {
        let (ledger, _, suite) = freshLedger()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        ledger.record(inputTokens: 1_000, outputTokens: 0, model: .opus48)   // $0.005
        ledger.record(inputTokens: 1_000, outputTokens: 0, model: .haiku45)  // $0.001

        #expect(ledger.totals().estimatedMicrodollars == 5_000 + 1_000)
    }

    @Test("A million input tokens on Opus 4.8 estimates exactly $5")
    func mtokSanity() {
        let (ledger, _, suite) = freshLedger()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        ledger.record(inputTokens: 1_000_000, outputTokens: 0, model: .opus48)
        #expect(ledger.totals().estimatedDollars == 5.0)
    }

    @Test("Since date is set on first record and preserved on later ones")
    func sinceIsFirstRecord() throws {
        let (ledger, _, suite) = freshLedger()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        ledger.record(inputTokens: 1, outputTokens: 1, model: .opus48)
        let first = try #require(ledger.totals().since)
        ledger.record(inputTokens: 1, outputTokens: 1, model: .opus48)
        #expect(ledger.totals().since == first)
    }

    @Test("Reset zeroes counters and restarts the since clock")
    func reset() throws {
        let (ledger, _, suite) = freshLedger()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        ledger.record(inputTokens: 100, outputTokens: 50, model: .sonnet5)
        let beforeReset = try #require(ledger.totals().since)
        ledger.reset()

        let totals = ledger.totals()
        #expect(totals.analysisCount == 0)
        #expect(totals.inputTokens == 0)
        #expect(totals.outputTokens == 0)
        #expect(totals.estimatedMicrodollars == 0)
        // The clock restarts rather than reverting to nil or the old date.
        let afterReset = try #require(totals.since)
        #expect(afterReset >= beforeReset)
    }
}
