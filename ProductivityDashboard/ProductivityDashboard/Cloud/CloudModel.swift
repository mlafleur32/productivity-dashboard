// Cloud/CloudModel.swift
//
// The curated model list for cloud analysis (Stage 5). Hardcoded rather than
// fetched from the Models API: ARCHITECTURE.md Security & Privacy item 4 permits
// only the network calls features strictly require, and a models-list call
// is not one. These are stable alias IDs (no date suffixes), so the list
// rots slowly; updating it is an edit here plus a costHint refresh.
//
// The selection is a preference, not a secret and not inbox-derived data —
// stored via @AppStorage (UserDefaults) under `storageKey`, never Keychain,
// never SwiftData. resolve() folds unknown stored values (e.g. a model we
// later remove from this list) back to the default instead of failing.

import Foundation

enum CloudModel: String, CaseIterable, Identifiable, Sendable {
    case opus48 = "claude-opus-4-8"
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"

    nonisolated static let defaultModel: CloudModel = .opus48
    // nonisolated: read from the analyzer's @Sendable model closure.
    nonisolated static let storageKey = "cloudAnalysisModelID"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus48:  "Claude Opus 4.8"
        case .sonnet5: "Claude Sonnet 5"
        case .haiku45: "Claude Haiku 4.5"
        }
    }

    // List prices in USD per million tokens — numerically identical to
    // microdollars per token, so CloudUsageLedger accumulates cost in exact
    // Int microdollars. Source: claude-api skill pricing table (cached
    // 2026-06-24): Opus 4.8 $5/$25, Sonnet 5 $3/$15 (intro discount through
    // 2026-08-31 ignored — estimate at list, the conservative direction),
    // Haiku 4.5 $1/$5. Refresh together with costHint when the curated list
    // changes; both rot at the same speed and live here for that reason.
    var inputMicrodollarsPerToken: Int {
        switch self {
        case .opus48:  5
        case .sonnet5: 3
        case .haiku45: 1
        }
    }

    var outputMicrodollarsPerToken: Int {
        switch self {
        case .opus48:  25
        case .sonnet5: 15
        case .haiku45: 5
        }
    }

    // Rough per-analyzed-email cost at mid-2026 list prices, for the picker
    // UI. Order-of-magnitude guidance, not a quote.
    var costHint: String {
        switch self {
        case .opus48:  "Most capable — about 1–2¢ per analyzed email"
        case .sonnet5: "Balanced — about 0.5–1¢ per analyzed email"
        case .haiku45: "Most economical — about 0.2–0.4¢ per analyzed email"
        }
    }

    /// Stored raw value → model, defaulting when nothing is stored or the
    /// stored ID is no longer in the curated list.
    nonisolated static func resolve(storedValue: String?) -> CloudModel {
        guard let storedValue, let model = CloudModel(rawValue: storedValue) else {
            return defaultModel
        }
        return model
    }
}
