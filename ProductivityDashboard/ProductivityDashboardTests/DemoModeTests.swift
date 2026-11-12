//
//  DemoModeTests.swift
//  ProductivityDashboardTests
//
//  Demo mode (-DemoMode) runs the app on synthetic data for screenshots,
//  video and agent development. These tests prove two things:
//    1. The fixtures cover what the demo has to show (VIP, newsletters with
//       each unsubscribe path, an auth-mismatch scam, an invite with a time,
//       allowlisted senders) and classify the way the demo script expects.
//    2. Demo mode keeps the real privacy rules: the canned analyzer still
//       sits behind the real allowlist gate, the scam never gets an
//       unsubscribe offer, and actions still need a confirmed type.
//

import Testing
import Foundation
import SwiftData
@testable import ProductivityDashboard

@MainActor
struct DemoModeTests {

    /// Records which messages reached the "cloud"; answers with the demo's
    /// canned verdicts.
    final class RecordingDemoAnalyzer: CloudAnalyzing, @unchecked Sendable {
        private(set) var analyzedSenders: [String] = []
        func isConfigured() -> Bool { true }
        func analyze(_ eligible: CloudEligibleMessage, rawBody: String) async throws -> CloudVerdict {
            analyzedSenders.append(AllowedSender.normalize(eligible.message.fromAddress))
            return DemoFixtures.verdict(forSender: eligible.message.fromAddress)
        }
    }

    /// The app publishes verdicts from the verdict cache (in demo mode the
    /// SwiftData cache over the in-memory store), so tests need a real one.
    final class InMemoryCloudCache: CloudVerdictCaching {
        private var outcomes: [String: CloudOutcome] = [:]
        func outcome(forMessageID id: String) -> CloudOutcome? { outcomes[id] }
        func store(_ outcome: CloudOutcome, forMessageID id: String) {
            if outcomes[id] == nil { outcomes[id] = outcome }
        }
    }

    struct FixedAllowlist: AllowlistReading {
        func cloudEligibleSenders() -> Set<String> {
            Set(DemoFixtures.allowlistedSenders.map(AllowedSender.normalize))
        }
    }

    struct FixedVIPs: VIPReading {
        func vipSenders() -> Set<String> {
            Set(DemoFixtures.vipSenders.map { AllowedSender.normalize($0.address) })
        }
    }

    // Optional default: default arguments are evaluated outside the main actor.
    private func loadedDemoInbox(analyzer: RecordingDemoAnalyzer? = nil) async -> InboxViewModel {
        let analyzer = analyzer ?? RecordingDemoAnalyzer()
        let vm = InboxViewModel(credentialsStore: DemoCredentialsStore(),
                                mailSource: DemoMailSource(), fetchLimit: 20)
        vm.cloudAnalyzer = analyzer
        vm.cloudVerdictCache = InMemoryCloudCache()
        vm.allowlistReader = FixedAllowlist()
        vm.vipReader = FixedVIPs()
        vm.unsubscriber = DemoUnsubscriber()
        vm.scansForEventHints = false
        await vm.load()
        return vm
    }

    private func message(from address: String, in vm: InboxViewModel) throws -> MailMessage {
        try #require(vm.messages.first { $0.fromAddress == address })
    }

    // MARK: - Switches

    @Test("Tests never run in demo mode, so the real-I/O guards stay off here")
    func notInDemoModeUnderTest() {
        #expect(!DemoMode.isActive)
        #expect(DemoMode.launchArgument == "-DemoMode")
    }

    // MARK: - Fixture coverage

    @Test("Every demo address and domain is synthetic (.example)")
    func fixturesAreSynthetic() {
        let items = DemoFixtures.inbox()
        let addresses = items.map(\.message.fromAddress)
            + DemoFixtures.allowlistedSenders
            + DemoFixtures.vipSenders.map(\.address)
            + [DemoFixtures.personalAccount.account, DemoFixtures.workAccount.account]
        for address in addresses {
            #expect(address.hasSuffix(".example"), "\(address) is not a reserved test domain")
        }
        #expect(DemoFixtures.personalAccount.server.hasSuffix(".example"))
        #expect(DemoFixtures.workAccount.server.hasSuffix(".example"))
        // Unique ids and UIDs, so rows and body fetches can't collide.
        #expect(Set(items.map(\.message.id)).count == items.count)
        #expect(Set(items.compactMap(\.message.imapUID)).count == items.count)
    }

    @Test("The demo inbox shows each dashboard section")
    func sectionsArePopulated() async throws {
        let vm = await loadedDemoInbox()

        // VIP mail is Important, decided locally.
        let vip = try message(from: "dana.morgan@mail.example", in: vm)
        #expect(vm.isVIP(vip))
        #expect(vm.important.first?.id == vip.id)

        // Allowlisted senders judged important by the (canned) cloud.
        let importantSenders = Set(vm.important.map(\.fromAddress))
        #expect(importantSenders.contains("jordan.ellis@northwind.example"))
        #expect(importantSenders.contains("sam.rivera@bluepeak.example"))

        // The auth-mismatch scam lands in Scams & Phishing.
        let scam = try message(from: "alerts@harb0rbank-secure.example", in: vm)
        #expect(vm.scams.map(\.id) == [scam.id])
        #expect(scam.authentication?.dmarc == .fail)
        #expect(scam.forensics?.isNotable == true)

        // Newsletters: three list senders plus the bulk-shaped notifier.
        #expect(vm.newsletters.count == 4)

        // Tasks come only from allowlisted, cloud-analyzed mail.
        #expect(vm.extractedTasks.count == 3)
        #expect(Set(vm.extractedTasks.map(\.sender)) == ["Jordan Ellis", "Sam Rivera"])
    }

    @Test("Each unsubscribe path appears once: one-click, mailto, and no safe option")
    func unsubscribePaths() async throws {
        let vm = await loadedDemoInbox()

        let oneClick = try message(from: "hello@hearthside.example", in: vm)
        guard case .offer(let offer1) = vm.unsubscribeDecision(for: oneClick),
              case .oneClick = offer1.method else {
            Issue.record("Hearthside should get a one-click offer"); return
        }
        let mailto = try message(from: "newsletter@trailhead.example", in: vm)
        guard case .offer(let offer2) = vm.unsubscribeDecision(for: mailto),
              case .mailto = offer2.method else {
            Issue.record("Trailhead should get a mailto offer"); return
        }
        let linkOnly = try message(from: "news@dailybrief.example", in: vm)
        if case .offer = vm.unsubscribeDecision(for: linkOnly) {
            Issue.record("A plain https link must never be offered")
        }
        let scam = try message(from: "alerts@harb0rbank-secure.example", in: vm)
        if case .offer = vm.unsubscribeDecision(for: scam) {
            Issue.record("Scam mail must never get an unsubscribe offer")
        }
    }

    @Test("Invite mail carries a meeting time in its body")
    func inviteHasATime() throws {
        let invite = try #require(DemoFixtures.inbox().first {
            $0.message.fromAddress == "priya.shah@northwind.example"
        })
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let matches = detector.matches(in: invite.body,
                                       range: NSRange(invite.body.startIndex..., in: invite.body))
        #expect(!matches.isEmpty)
    }

    // MARK: - The gate still holds in demo mode

    @Test("Only allowlisted demo senders reach the canned analyzer")
    func gateHoldsInDemo() async {
        let analyzer = RecordingDemoAnalyzer()
        _ = await loadedDemoInbox(analyzer: analyzer)

        let allowed = Set(DemoFixtures.allowlistedSenders.map(AllowedSender.normalize))
        #expect(!analyzer.analyzedSenders.isEmpty)
        #expect(Set(analyzer.analyzedSenders).isSubset(of: allowed))
        // The privileged sender, the VIP and the scam never leave "the Mac".
        #expect(!analyzer.analyzedSenders.contains("frontdesk@riversidedental.example"))
        #expect(!analyzer.analyzedSenders.contains("dana.morgan@mail.example"))
        #expect(!analyzer.analyzedSenders.contains("alerts@harb0rbank-secure.example"))
    }

    // MARK: - Fake executors

    @Test("Archive and undo move a message out of and back into the demo inbox")
    func archiveRoundTrip() async throws {
        let source = DemoMailSource()
        let before = try await source.fetchRecent(limit: 50)
        let target = try #require(before.first { $0.fromAddress == "hello@hearthside.example" })

        let flow = ArchiveConfirmationFlow()
        flow.request(target)
        let action = try #require(flow.confirm())
        let receipt = try await source.archive(action)
        #expect(receipt.messageID == target.id)
        #expect(try await source.fetchRecent(limit: 50).count == before.count - 1)

        let uid = try #require(receipt.newUID)
        try await source.unarchive(accountID: target.accountID, newUID: uid, from: receipt.archivedTo)
        #expect(try await source.fetchRecent(limit: 50).count == before.count)
    }

    @Test("Body fetch is scoped to the message's own account")
    func bodyFetchIsAccountScoped() async throws {
        let source = DemoMailSource()
        let item = try #require(DemoFixtures.inbox().first)
        let uid = try #require(item.message.imapUID)
        #expect(try await source.fetchBody(accountID: item.message.accountID, imapUID: uid) == item.body)
        #expect(try await source.fetchBody(accountID: "someone-else|imap.other.example", imapUID: uid) == nil)
    }

    @Test("The demo calendar shows upcoming events and takes created ones")
    func demoCalendar() async throws {
        let store = DemoCalendarStore()
        let source = DemoCalendarSource(store: store)
        let upcoming = try await source.fetchUpcomingEvents(daysAhead: 7, limit: 10)
        #expect(upcoming.count == DemoFixtures.calendar().count)

        let start = Date.now.addingTimeInterval(3_600)
        store.add(CalendarEvent(id: "demo-created-x", title: "Design review",
                                startDate: start, endDate: start.addingTimeInterval(1_800),
                                isAllDay: false, calendarTitle: "Work"))
        let writer = DemoEventWriter(store: store)
        #expect(writer.summary(eventIdentifier: "demo-created-x")?.title == "Design review")
        #expect(try await writer.undoCreate(eventIdentifier: "demo-created-x",
                                            expectedCalendarID: "demo-work") == .removed)
        #expect(try await writer.undoCreate(eventIdentifier: "demo-created-x",
                                            expectedCalendarID: "demo-work") == .alreadyGone)
    }

    // MARK: - Seeded store

    @Test("Demo store is in memory and seeded with the demo allowlist and VIPs")
    func seededStore() throws {
        let schema = Schema([AllowedSender.self, VIPSender.self])
        let container = try DemoEnvironment.makeModelContainer(schema: schema)
        for configuration in container.configurations {
            #expect(configuration.isStoredInMemoryOnly)
        }

        let reader = SwiftDataAllowlistReader(context: container.mainContext)
        #expect(reader.cloudEligibleSenders()
                == Set(DemoFixtures.allowlistedSenders.map(AllowedSender.normalize)))
        let vips = SwiftDataVIPReader(context: container.mainContext).vipSenders()
        #expect(vips == ["dana.morgan@mail.example"])
    }
}
