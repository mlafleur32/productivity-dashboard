//
//  ClassificationCacheTests.swift
//  ProductivityDashboardTests
//
//  Verifies the SwiftData-backed classification cache: store/retrieve, and
//  the classify-once rule (a second store for the same message-id does not
//  overwrite the first-arrival verdict).
//
//  One shared in-memory ModelContainer for the whole suite: creating several
//  ModelContainers for the same @Model in a single test process crashes
//  SwiftData. Tests use distinct message-ids so they don't interfere, and
//  the suite is serialized so the shared context isn't touched concurrently.
//

import Testing
import Foundation
import SwiftData
@testable import ProductivityDashboard

@MainActor
@Suite(.serialized)
struct ClassificationCacheTests {

    static let container: ModelContainer = {
        try! ModelContainer(
            for: ClassificationCacheEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private var cache: SwiftDataClassificationCache {
        SwiftDataClassificationCache(context: Self.container.mainContext)
    }

    @Test("A miss returns nil; after store, the category is returned")
    func storeThenRetrieve() {
        let c = cache
        #expect(c.category(forMessageID: "store-1") == nil)
        c.store(category: .newsletter, forMessageID: "store-1")
        #expect(c.category(forMessageID: "store-1") == .newsletter)
    }

    @Test("Classify-once: a second store keeps the first-arrival verdict")
    func classifyOnceKeepsFirstVerdict() {
        let c = cache
        c.store(category: .scam, forMessageID: "once-1")
        // A later attempt with a different category must not overwrite.
        c.store(category: .other, forMessageID: "once-1")
        #expect(c.category(forMessageID: "once-1") == .scam)
    }

    @Test("Distinct message-ids are cached independently")
    func distinctIDs() {
        let c = cache
        c.store(category: .newsletter, forMessageID: "dist-a")
        c.store(category: .scam, forMessageID: "dist-b")
        #expect(c.category(forMessageID: "dist-a") == .newsletter)
        #expect(c.category(forMessageID: "dist-b") == .scam)
        #expect(c.category(forMessageID: "dist-c") == nil)
    }
}
