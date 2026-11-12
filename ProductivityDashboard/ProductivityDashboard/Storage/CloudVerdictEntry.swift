// Storage/CloudVerdictEntry.swift
//
// Persisted outcome of ONE cloud analysis (Stage 5, Step E) — the analyze-
// once cache that keeps paid API calls from repeating. Two outcome kinds:
//
//   "verdict": the analysis succeeded; importance/scam/tasks are populated.
//   "skipped": the message can never produce a verdict (no text part,
//              refused, undecodable) — recorded so we never re-spend on it.
//
// Transient failures (network, rate limit, no key) are deliberately NOT
// rows here: absence means "may retry on a future poll".
//
// Privacy shape (ARCHITECTURE.md storage rules): messageID + verdict enums +
// extracted task titles/hints. Task text is a derived analysis RESULT the
// user opted to persist (settled Stage 5 decision); raw bodies and subjects
// never land here. tasksJSON is an inspectable JSON encoding of
// [CloudVerdict.ExtractedTask].

import Foundation
import SwiftData

@Model
final class CloudVerdictEntry {
    @Attribute(.unique) var messageID: String
    var outcomeRaw: String            // "verdict" | "skipped"
    var importanceRaw: String?        // CloudVerdict.Importance.rawValue
    var scamRaw: String?              // CloudVerdict.ScamJudgment.rawValue
    var tasksJSON: String?            // JSON-encoded [CloudVerdict.ExtractedTask]
    var analyzedAt: Date

    init(
        messageID: String,
        outcomeRaw: String,
        importanceRaw: String? = nil,
        scamRaw: String? = nil,
        tasksJSON: String? = nil,
        analyzedAt: Date = .now
    ) {
        self.messageID = messageID
        self.outcomeRaw = outcomeRaw
        self.importanceRaw = importanceRaw
        self.scamRaw = scamRaw
        self.tasksJSON = tasksJSON
        self.analyzedAt = analyzedAt
    }
}
