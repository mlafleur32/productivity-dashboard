// Cloud/CloudUsageLedger.swift
//
// Cumulative Claude API usage counters (deferred follow-up, 2026-07-05):
// how many analyses ran, how many tokens they consumed, and roughly what
// they cost — surfaced in the Claude API Settings pane.
//
// What this is NOT: it is not inbox-derived data. Token counts and a cost
// estimate encode nothing about message content or senders, so UserDefaults
// is the right home (same reasoning as CloudModel's stored selection) —
// never Keychain, never SwiftData.
//
// Cost math is exact integer arithmetic: USD-per-million-tokens equals
// microdollars-per-token, so `tokens * pricePerMTok` accumulates in Int
// microdollars with no floating-point drift. Each response is priced at
// record time with the model that actually served it, so switching models
// mid-history keeps the running estimate honest. The estimate uses list
// prices (see CloudModel) and ignores prompt-caching discounts — an upper
// bound, which is the safe direction for a spending indicator.
//
// Recording happens from ClaudeAnalyzer's sequential pipeline loop; there
// is no concurrent-writer scenario, so plain UserDefaults read-modify-write
// suffices (UserDefaults itself is thread-safe).

import Foundation

protocol UsageRecording: Sendable {
    func record(inputTokens: Int, outputTokens: Int, model: CloudModel)
}

// nonisolated: pure value type; keeps its Equatable conformance usable
// from test tables (the target defaults to MainActor isolation).
nonisolated struct CloudUsageTotals: Equatable, Sendable {
    var analysisCount: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    /// Exact integer accumulation; divide by 1_000_000 for dollars.
    var estimatedMicrodollars: Int = 0
    /// When counting started (first recorded analysis, or last reset).
    var since: Date?

    var estimatedDollars: Double { Double(estimatedMicrodollars) / 1_000_000 }
}

// @unchecked: the only stored property is UserDefaults, which is
// documented thread-safe; there is no other mutable state.
final class CloudUsageLedger: UsageRecording, @unchecked Sendable {

    private enum Key {
        static let analysisCount = "cloudUsage.analysisCount"
        static let inputTokens = "cloudUsage.inputTokens"
        static let outputTokens = "cloudUsage.outputTokens"
        static let estimatedMicrodollars = "cloudUsage.estimatedMicrodollars"
        static let since = "cloudUsage.since"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(inputTokens: Int, outputTokens: Int, model: CloudModel) {
        let cost = inputTokens * model.inputMicrodollarsPerToken
            + outputTokens * model.outputMicrodollarsPerToken

        defaults.set(defaults.integer(forKey: Key.analysisCount) + 1,
                     forKey: Key.analysisCount)
        defaults.set(defaults.integer(forKey: Key.inputTokens) + inputTokens,
                     forKey: Key.inputTokens)
        defaults.set(defaults.integer(forKey: Key.outputTokens) + outputTokens,
                     forKey: Key.outputTokens)
        defaults.set(defaults.integer(forKey: Key.estimatedMicrodollars) + cost,
                     forKey: Key.estimatedMicrodollars)
        if defaults.object(forKey: Key.since) == nil {
            defaults.set(Date.now, forKey: Key.since)
        }
    }

    func totals() -> CloudUsageTotals {
        CloudUsageTotals(
            analysisCount: defaults.integer(forKey: Key.analysisCount),
            inputTokens: defaults.integer(forKey: Key.inputTokens),
            outputTokens: defaults.integer(forKey: Key.outputTokens),
            estimatedMicrodollars: defaults.integer(forKey: Key.estimatedMicrodollars),
            since: defaults.object(forKey: Key.since) as? Date)
    }

    /// Zero every counter and restart the "since" clock now, so the pane
    /// reads "0 analyses since <today>" rather than reviving the old date.
    func reset() {
        defaults.set(0, forKey: Key.analysisCount)
        defaults.set(0, forKey: Key.inputTokens)
        defaults.set(0, forKey: Key.outputTokens)
        defaults.set(0, forKey: Key.estimatedMicrodollars)
        defaults.set(Date.now, forKey: Key.since)
    }
}
