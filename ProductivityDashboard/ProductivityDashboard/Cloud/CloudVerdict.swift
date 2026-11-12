// Cloud/CloudVerdict.swift
//
// The structured result of one cloud analysis (Stage 5, Step C). This is
// exactly the JSON the API is constrained to produce via output_config's
// json_schema (see ClaudeAnalyzer.verdictSchemaJSON — keep the two in sync),
// so decoding is deterministic: no free-text parsing, no partial states.
//
// Minimal by design: importance, scam judgment, and extracted tasks. Task
// titles are derived analysis RESULTS (per the settled Stage 5 decision they
// may be persisted); raw bodies never appear here.

import Foundation

struct CloudVerdict: Codable, Equatable, Sendable {
    enum Importance: String, Codable, Sendable {
        case important
        case routine
    }

    enum ScamJudgment: String, Codable, Sendable {
        case clean
        case suspicious
        case phishing
    }

    struct ExtractedTask: Codable, Equatable, Sendable {
        /// Short imperative summary of what the sender asked the user to do.
        let title: String
        /// Due-date hint verbatim from the email ("by Friday"), if any.
        let dueHint: String?

        enum CodingKeys: String, CodingKey {
            case title
            case dueHint = "due_hint"
        }
    }

    let importance: Importance
    let scam: ScamJudgment
    let tasks: [ExtractedTask]
}
