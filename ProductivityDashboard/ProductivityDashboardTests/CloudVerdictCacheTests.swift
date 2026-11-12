//
//  CloudVerdictCacheTests.swift
//  ProductivityDashboardTests
//
//  The analyze-once money gate: verdicts and terminal skips round-trip
//  through SwiftData, and an existing row is never overwritten. One shared
//  in-memory container for the suite; this suite owns the test bundle's
//  only CloudVerdictEntry container (single-container rule).
//

import Testing
import Foundation
import SwiftData
@testable import ProductivityDashboard

@MainActor
@Suite(.serialized)
struct CloudVerdictCacheTests {

    static let container: ModelContainer = {
        try! ModelContainer(
            for: CloudVerdictEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private var cache: SwiftDataCloudVerdictCache {
        SwiftDataCloudVerdictCache(context: Self.container.mainContext)
    }

    private let sampleVerdict = CloudVerdict(
        importance: .important,
        scam: .clean,
        tasks: [
            .init(title: "Send the signed form", dueHint: "by Tuesday"),
            .init(title: "Confirm the meeting time", dueHint: nil),
        ])

    @Test("Miss returns nil; verdict round-trips with tasks and hints intact")
    func verdictRoundTrip() {
        let c = cache
        #expect(c.outcome(forMessageID: "rt-1") == nil)
        c.store(.verdict(sampleVerdict), forMessageID: "rt-1")
        #expect(c.outcome(forMessageID: "rt-1") == .verdict(sampleVerdict))
        #expect(!Self.container.mainContext.hasChanges)  // explicit-save rule
    }

    @Test("Skipped round-trips as skipped")
    func skippedRoundTrip() {
        let c = cache
        c.store(.skipped, forMessageID: "skip-1")
        #expect(c.outcome(forMessageID: "skip-1") == .skipped)
    }

    @Test("Analyze-once: a second store never overwrites the first outcome")
    func insertOnly() {
        let c = cache
        c.store(.verdict(sampleVerdict), forMessageID: "once-1")
        c.store(.skipped, forMessageID: "once-1")
        #expect(c.outcome(forMessageID: "once-1") == .verdict(sampleVerdict))

        c.store(.skipped, forMessageID: "once-2")
        c.store(.verdict(sampleVerdict), forMessageID: "once-2")
        #expect(c.outcome(forMessageID: "once-2") == .skipped)
    }

    @Test("Empty task list round-trips as empty, not nil-ish")
    func emptyTasks() {
        let c = cache
        let verdict = CloudVerdict(importance: .routine, scam: .suspicious, tasks: [])
        c.store(.verdict(verdict), forMessageID: "empty-1")
        #expect(c.outcome(forMessageID: "empty-1") == .verdict(verdict))
    }

    @Test("A corrupt row decodes as skipped — fail-safe is don't re-spend")
    func corruptRowIsSkipped() {
        let context = Self.container.mainContext
        context.insert(CloudVerdictEntry(
            messageID: "corrupt-1",
            outcomeRaw: "verdict",
            importanceRaw: "no-such-importance",
            scamRaw: "clean"))
        try? context.save()
        #expect(cache.outcome(forMessageID: "corrupt-1") == .skipped)
    }
}
