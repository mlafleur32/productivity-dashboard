// Storage/MailCategory.swift
//
// The single primary category assigned to each message by the local rules
// engine (Stage 4, Step C). One category per message — priority order when
// multiple could apply is scam > newsletter > important > other, resolved
// in the rules engine, not here. Persisted as a raw String in
// ClassificationCacheEntry so the store stays inspectable and portable.

import Foundation

enum MailCategory: String, Codable, Sendable, CaseIterable {
    case important
    case newsletter   // "unsubscribe candidate" in dashboard terms
    case scam
    case other
}
