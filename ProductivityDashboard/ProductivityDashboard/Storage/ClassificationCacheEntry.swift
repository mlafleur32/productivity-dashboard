// Storage/ClassificationCacheEntry.swift
//
// Caches the local rules engine's verdict for a message so each message is
// classified at most once (on first arrival). Frequent polling is cheap;
// re-analysis is what would cost money at Stage 5 — so we cache results,
// never re-derive them for a message we've already seen.
//
// Privacy (ARCHITECTURE.md): stores ONLY the RFC Message-ID, the category, and a
// timestamp. No subject, no body, no sender name. The Message-ID is the
// minimum needed to recognize the message again; the category is a result,
// not content.

import Foundation
import SwiftData

@Model
final class ClassificationCacheEntry {
    @Attribute(.unique) var messageID: String
    // Stored as the raw String rather than the enum directly: keeps the
    // SwiftData store inspectable and portable, and tolerates an unknown
    // value by falling back to .other rather than failing to decode.
    var categoryRaw: String
    var classifiedAt: Date

    var category: MailCategory {
        get { MailCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    init(messageID: String, category: MailCategory, classifiedAt: Date = .now) {
        self.messageID = messageID
        self.categoryRaw = category.rawValue
        self.classifiedAt = classifiedAt
    }
}
