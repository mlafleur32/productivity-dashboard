// Storage/ClassificationCache.swift
//
// Read/write access to the persisted classification cache. Backs the
// "classify each message at most once, on first arrival" rule (ARCHITECTURE.md):
// local classification is deterministic and free today, but at Stage 5 the
// cloud path costs money per message, so the cache structure that prevents
// re-analysis is built now.
//
// @MainActor because the SwiftData-backed implementation holds a ModelContext
// (the container's mainContext), which is main-actor bound. The view model
// that uses this is also main-actor.

import Foundation
import SwiftData

@MainActor
protocol ClassificationCaching {
    /// The cached category for a message, or nil if it hasn't been classified.
    func category(forMessageID id: String) -> MailCategory?
    /// Persist the first-arrival verdict for a message. Insert-only (see impl).
    func store(category: MailCategory, forMessageID id: String)
}

/// Fallback used when no store is attached (previews, tests, or before the
/// SwiftData context is wired in). Always misses, never persists — so
/// classification still happens, just without the once-only cache. Safe
/// because local rules are deterministic; must NOT be the production path at
/// Stage 5, where the real cache prevents paid re-analysis.
@MainActor
struct NoOpClassificationCache: ClassificationCaching {
    func category(forMessageID id: String) -> MailCategory? { nil }
    func store(category: MailCategory, forMessageID id: String) {}
}

@MainActor
struct SwiftDataClassificationCache: ClassificationCaching {
    let context: ModelContext

    func category(forMessageID id: String) -> MailCategory? {
        var descriptor = FetchDescriptor<ClassificationCacheEntry>(
            predicate: #Predicate { $0.messageID == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.category
    }

    func store(category: MailCategory, forMessageID id: String) {
        // Classify-once: keep the first-arrival verdict. If an entry already
        // exists, leave it (local rules are deterministic, so re-inserting
        // would be a no-op anyway; at Stage 5 this guards against re-running
        // paid cloud analysis).
        guard self.category(forMessageID: id) == nil else { return }
        context.insert(ClassificationCacheEntry(messageID: id, category: category))
        // Explicit save rather than relying on SwiftData auto-save, which can
        // defer or drop silently.
        try? context.save()
    }
}
