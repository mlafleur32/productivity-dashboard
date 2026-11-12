//
//  InboxCloudPipelineTests.swift
//  ProductivityDashboardTests
//
//  THE Stage 5 release-gate suite (peer of AllowlistGateTests): prove the
//  wired pipeline never lets a non-allowlisted or non-ambiguous message
//  reach the analyzer or even a body fetch, and that analyze-once, terminal
//  vs transient failure handling, and the dashboard projections all behave.
//
//  Everything is faked at the protocol seams — no SwiftData container, no
//  Keychain, no sockets. The spy analyzer records exactly which message IDs
//  were analyzed; the fake mail source records exactly which UIDs had
//  bodies fetched. If any test here fails, the privacy or money boundary
//  is broken — release blocker, not a normal failure.
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct InboxCloudPipelineTests {

    // MARK: - Fakes

    struct FakeCredentialsStore: CredentialsStore {
        nonisolated func save(_ credentials: IMAPCredentials) throws {}
        nonisolated func loadAll() throws -> [IMAPCredentials] {
            [
            IMAPCredentials(server: "imap.test.example", port: 993,
                            account: "user@test.example", password: "test")
            ]
        }
        nonisolated func delete(accountID: String) throws {}
    }

    final class FakeMailSource: MailSource, @unchecked Sendable {
        var messages: [MailMessage] = []
        var bodies: [UInt32: String] = [:]      // uid → raw body
        var bodyFetchThrows = false
        private(set) var fetchedBodyUIDs: [UInt32] = []

        func fetchRecent(limit: Int) async throws -> [MailMessage] { messages }

        func fetchBody(accountID: String?, imapUID: UInt32) async throws -> String? {
            fetchedBodyUIDs.append(imapUID)
            if bodyFetchThrows { throw InboxError.connectionDropped }
            return bodies[imapUID]
        }
    }

    final class SpyAnalyzer: CloudAnalyzing, @unchecked Sendable {
        var configured = true
        var result: Result<CloudVerdict, CloudAnalysisError>
        private(set) var analyzedMessageIDs: [String] = []
        private(set) var receivedBodies: [String] = []

        init(result: Result<CloudVerdict, CloudAnalysisError> = .success(
            CloudVerdict(importance: .important, scam: .clean,
                         tasks: [.init(title: "Reply to Alice", dueHint: "today")])
        )) {
            self.result = result
        }

        func isConfigured() -> Bool { configured }

        func analyze(_ eligible: CloudEligibleMessage, rawBody: String) async throws -> CloudVerdict {
            analyzedMessageIDs.append(eligible.message.id)
            receivedBodies.append(rawBody)
            return try result.get()
        }
    }

    struct FakeReader: AllowlistReading {
        let eligible: Set<String>
        func cloudEligibleSenders() -> Set<String> { eligible }
    }

    /// Dictionary-backed cache — real analyze-once semantics, no SwiftData.
    final class InMemoryCloudCache: CloudVerdictCaching {
        private(set) var outcomes: [String: CloudOutcome] = [:]
        func outcome(forMessageID id: String) -> CloudOutcome? { outcomes[id] }
        func store(_ outcome: CloudOutcome, forMessageID id: String) {
            guard outcomes[id] == nil else { return }
            outcomes[id] = outcome
        }
    }

    // MARK: - Fixtures

    /// A message the local rules classify .other (no list headers, no bulk
    /// local part, no trusted auth verdict) — the only category the cloud
    /// pipeline may touch.
    private func ambiguousMessage(id: String, from: String, uid: UInt32) -> MailMessage {
        MailMessage(id: id, fromName: nil, fromAddress: from,
                    subject: "s", date: .now, imapUID: uid)
    }

    /// Local verdict .newsletter — allowlisted or not, never cloud-analyzed.
    private func newsletterMessage(id: String, from: String, uid: UInt32) -> MailMessage {
        MailMessage(id: id, fromName: nil, fromAddress: from,
                    subject: "s", date: .now,
                    listUnsubscribe: "<https://u.example/x>", imapUID: uid)
    }

    private func makeVM(
        source: FakeMailSource,
        analyzer: SpyAnalyzer,
        cache: InMemoryCloudCache,
        eligible: Set<String>
    ) -> InboxViewModel {
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(), mailSource: source)
        vm.cloudAnalyzer = analyzer
        vm.cloudVerdictCache = cache
        vm.allowlistReader = FakeReader(eligible: eligible)
        // These tests are about the CLOUD gate, and assert exact body-fetch
        // lists. The Step D5 hint scan reads bodies locally for its own
        // reasons, so it is off here and covered by its own suite (including
        // "the hint scan never feeds the analyzer" below).
        vm.scansForEventHints = false
        return vm
    }

    // MARK: - THE RELEASE GATE

    @Test("Non-allowlisted senders never reach the analyzer OR a body fetch")
    func nonAllowlistedNeverAnalyzed() async {
        let source = FakeMailSource()
        source.messages = [
            ambiguousMessage(id: "m-allowed", from: "alice@firm.example", uid: 11),
            ambiguousMessage(id: "m-stranger", from: "stranger@evil.example", uid: 12),
        ]
        source.bodies = [11: "please review", 12: "should never be fetched"]
        let analyzer = SpyAnalyzer()
        let vm = makeVM(source: source, analyzer: analyzer, cache: InMemoryCloudCache(), eligible: ["alice@firm.example"])

        await vm.load()

        #expect(analyzer.analyzedMessageIDs == ["m-allowed"])
        #expect(source.fetchedBodyUIDs == [11])  // stranger's body never even fetched
    }

    @Test("RELEASE GATE: being a VIP grants NO cloud eligibility")
    func vipIsNotCloudEligible() async {
        struct FakeVIPReader: VIPReading {
            let senders: Set<String>
            func vipSenders() -> Set<String> { senders }
        }
        let source = FakeMailSource()
        source.messages = [
            ambiguousMessage(id: "m-vip", from: "dad@family.example", uid: 21),
            ambiguousMessage(id: "m-allowed", from: "alice@firm.example", uid: 22),
        ]
        source.bodies = [21: "family news", 22: "please review"]
        let analyzer = SpyAnalyzer()
        // Allowlist holds alice only; dad is a VIP and nothing more.
        let vm = makeVM(source: source, analyzer: analyzer, cache: InMemoryCloudCache(),
                        eligible: ["alice@firm.example"])
        vm.vipReader = FakeVIPReader(senders: ["dad@family.example"])

        await vm.load()

        // The VIP is important locally…
        #expect(vm.important.contains { $0.id == "m-vip" })
        // …and the cloud boundary is exactly where it was.
        #expect(analyzer.analyzedMessageIDs == ["m-allowed"])
        #expect(!source.fetchedBodyUIDs.contains(21))
    }

    @Test("An allowlisted VIP is still analyzed, so tasks and scam checks keep working")
    func allowlistedVIPStillAnalyzed() async {
        struct FakeVIPReader: VIPReading {
            let senders: Set<String>
            func vipSenders() -> Set<String> { senders }
        }
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m-vip", from: "dad@family.example", uid: 31)]
        source.bodies = [31: "can you send the form by Friday?"]
        let analyzer = SpyAnalyzer()
        let vm = makeVM(source: source, analyzer: analyzer, cache: InMemoryCloudCache(),
                        eligible: ["dad@family.example"])
        vm.vipReader = FakeVIPReader(senders: ["dad@family.example"])

        await vm.load()

        #expect(analyzer.analyzedMessageIDs == ["m-vip"])
    }

    @Test("RELEASE GATE: the local event-hint scan never feeds the analyzer")
    func hintScanNeverReachesTheCloud() async {
        let source = FakeMailSource()
        source.messages = [
            ambiguousMessage(id: "m-allowed", from: "alice@firm.example", uid: 11),
            ambiguousMessage(id: "m-stranger", from: "stranger@evil.example", uid: 12),
        ]
        source.bodies = [11: "please review", 12: "lunch at 12:30 on October 15, 2027"]
        let analyzer = SpyAnalyzer()
        let vm = makeVM(source: source, analyzer: analyzer, cache: InMemoryCloudCache(), eligible: ["alice@firm.example"])
        vm.scansForEventHints = true   // the scan reads the stranger's body LOCALLY

        await vm.load()

        // A local read, and a hint for the user — but the cloud boundary is
        // exactly where it was.
        #expect(analyzer.analyzedMessageIDs == ["m-allowed"])
        #expect(vm.eventHints["m-stranger"] != nil)
    }

    @Test("Empty allowlist: zero body fetches, zero analyses — the fail-safe default")
    func emptyAllowlistDoesNothing() async {
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m1", from: "a@b.example", uid: 1)]
        source.bodies = [1: "body"]
        let analyzer = SpyAnalyzer()
        let vm = makeVM(source: source, analyzer: analyzer, cache: InMemoryCloudCache(), eligible: [])

        await vm.load()

        #expect(analyzer.analyzedMessageIDs.isEmpty)
        #expect(source.fetchedBodyUIDs.isEmpty)
    }

    @Test("Locally-classified mail (newsletter) is never cloud-analyzed even when allowlisted")
    func nonAmbiguousNeverAnalyzed() async {
        let source = FakeMailSource()
        source.messages = [newsletterMessage(id: "n1", from: "alice@firm.example", uid: 21)]
        source.bodies = [21: "newsletter body"]
        let analyzer = SpyAnalyzer()
        let vm = makeVM(source: source, analyzer: analyzer, cache: InMemoryCloudCache(), eligible: ["alice@firm.example"])

        await vm.load()

        #expect(analyzer.analyzedMessageIDs.isEmpty)
        #expect(source.fetchedBodyUIDs.isEmpty)
    }

    @Test("Unconfigured analyzer (no API key): zero body fetches")
    func unconfiguredSkipsEverything() async {
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m1", from: "alice@firm.example", uid: 1)]
        source.bodies = [1: "body"]
        let analyzer = SpyAnalyzer()
        analyzer.configured = false
        let vm = makeVM(source: source, analyzer: analyzer, cache: InMemoryCloudCache(), eligible: ["alice@firm.example"])

        await vm.load()

        #expect(analyzer.analyzedMessageIDs.isEmpty)
        #expect(source.fetchedBodyUIDs.isEmpty)
    }

    // MARK: - Analyze-once (the money gate)

    @Test("A cached outcome is never re-analyzed across polls")
    func analyzeOnceAcrossLoads() async {
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m1", from: "alice@firm.example", uid: 1)]
        source.bodies = [1: "body"]
        let analyzer = SpyAnalyzer()
        let vm = makeVM(source: source, analyzer: analyzer, cache: InMemoryCloudCache(), eligible: ["alice@firm.example"])

        await vm.load()
        await vm.load()  // second poll, same message

        #expect(analyzer.analyzedMessageIDs == ["m1"])   // exactly once
        #expect(source.fetchedBodyUIDs == [1])           // body fetched exactly once
    }

    @Test("nil body (no text part) is cached as terminal skip; analyzer untouched")
    func nilBodySkippedPermanently() async {
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m1", from: "alice@firm.example", uid: 1)]
        source.bodies = [:]  // fetchBody returns nil
        let analyzer = SpyAnalyzer()
        let cache = InMemoryCloudCache()
        let vm = makeVM(source: source, analyzer: analyzer, cache: cache, eligible: ["alice@firm.example"])

        await vm.load()
        await vm.load()

        #expect(analyzer.analyzedMessageIDs.isEmpty)
        #expect(source.fetchedBodyUIDs == [1])           // fetched once, then cached skip
        #expect(cache.outcomes["m1"] == .skipped)
    }

    @Test("Refusal is terminal: cached as skipped, never retried")
    func refusalCachedAsSkipped() async {
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m1", from: "alice@firm.example", uid: 1)]
        source.bodies = [1: "body"]
        let analyzer = SpyAnalyzer(result: .failure(.refused))
        let cache = InMemoryCloudCache()
        let vm = makeVM(source: source, analyzer: analyzer, cache: cache, eligible: ["alice@firm.example"])

        await vm.load()
        await vm.load()

        #expect(analyzer.analyzedMessageIDs == ["m1"])   // once, not twice
        #expect(cache.outcomes["m1"] == .skipped)
    }

    @Test("Network failure is transient: nothing cached, retried next poll")
    func networkFailureRetries() async {
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m1", from: "alice@firm.example", uid: 1)]
        source.bodies = [1: "body"]
        let analyzer = SpyAnalyzer(result: .failure(.networkFailure))
        let cache = InMemoryCloudCache()
        let vm = makeVM(source: source, analyzer: analyzer, cache: cache, eligible: ["alice@firm.example"])

        await vm.load()
        #expect(cache.outcomes["m1"] == nil)

        analyzer.result = .success(CloudVerdict(importance: .routine, scam: .clean, tasks: []))
        await vm.load()

        #expect(analyzer.analyzedMessageIDs == ["m1", "m1"])  // retried and succeeded
        #expect(cache.outcomes["m1"] != nil)
    }

    @Test("IMAP body-fetch failure is transient: analyzer untouched, retried next poll")
    func bodyFetchFailureRetries() async {
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m1", from: "alice@firm.example", uid: 1)]
        source.bodies = [1: "body"]
        source.bodyFetchThrows = true
        let analyzer = SpyAnalyzer()
        let cache = InMemoryCloudCache()
        let vm = makeVM(source: source, analyzer: analyzer, cache: cache, eligible: ["alice@firm.example"])

        await vm.load()
        #expect(analyzer.analyzedMessageIDs.isEmpty)
        #expect(cache.outcomes["m1"] == nil)

        source.bodyFetchThrows = false
        await vm.load()
        #expect(analyzer.analyzedMessageIDs == ["m1"])
    }

    // MARK: - Dashboard projections

    @Test("Verdicts drive Important, Tasks, and Scams sections")
    func projectionsReflectVerdicts() async {
        let source = FakeMailSource()
        source.messages = [
            ambiguousMessage(id: "m-imp", from: "alice@firm.example", uid: 1),
            ambiguousMessage(id: "m-phish", from: "bob@firm.example", uid: 2),
        ]
        source.bodies = [1: "please reply", 2: "wire the funds"]
        let analyzer = SpyAnalyzer()
        let cache = InMemoryCloudCache()
        // Pre-seed bob's verdict so the two messages carry different verdicts.
        cache.store(.verdict(CloudVerdict(importance: .routine, scam: .phishing, tasks: [])),
                    forMessageID: "m-phish")
        let vm = makeVM(source: source, analyzer: analyzer, cache: cache,
                        eligible: ["alice@firm.example", "bob@firm.example"])

        await vm.load()

        #expect(vm.important.map(\.id) == ["m-imp"])
        #expect(vm.extractedTasks == [
            DashboardTask(id: "m-imp#0", title: "Reply to Alice", dueHint: "today",
                          sender: "alice@firm.example")
        ])
        #expect(vm.scams.map(\.id) == ["m-phish"])       // cloud phishing joins the section
        #expect(analyzer.analyzedMessageIDs == ["m-imp"]) // bob came from cache
    }

    @Test("Verdicts from cache surface without any analyzer or body-fetch activity")
    func cachedVerdictsSurviveRestart() async {
        let source = FakeMailSource()
        source.messages = [ambiguousMessage(id: "m1", from: "alice@firm.example", uid: 1)]
        let analyzer = SpyAnalyzer()
        let cache = InMemoryCloudCache()
        let verdict = CloudVerdict(importance: .important, scam: .clean, tasks: [])
        cache.store(.verdict(verdict), forMessageID: "m1")
        let vm = makeVM(source: source, analyzer: analyzer, cache: cache, eligible: ["alice@firm.example"])

        await vm.load()

        #expect(vm.important.map(\.id) == ["m1"])
        #expect(analyzer.analyzedMessageIDs.isEmpty)
        #expect(source.fetchedBodyUIDs.isEmpty)
    }
}
