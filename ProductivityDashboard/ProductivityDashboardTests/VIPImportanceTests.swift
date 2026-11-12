//
//  VIPImportanceTests.swift
//  ProductivityDashboardTests
//
//  The VIP list (Matt, 2026-10-07): mail from a VIP sender is Important,
//  decided on this Mac. The rules that matter are the ones about what VIP
//  does NOT do — it never overrides a spoof warning, and it never widens
//  the cloud boundary. Synthetic messages only.
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct VIPRulesTests {

    private func message(from address: String, dmarc: AuthVerdict = .pass,
                         listUnsubscribe: String? = nil) -> MailMessage {
        MailMessage(id: "m-\(address)-\(dmarc.rawValue)-\(listUnsubscribe ?? "none")",
                    fromName: "Someone", fromAddress: address,
                    subject: "Hello", date: .now,
                    listUnsubscribe: listUnsubscribe,
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: dmarc),
                    imapUID: 1)
    }

    nonisolated static let vips: Set<String> = ["dad@family.example", "wife@family.example"]

    @Test("A VIP sender's ordinary mail is important")
    func vipMailIsImportant() {
        #expect(LocalRulesEngine.classify(message(from: "dad@family.example"),
                                          vipSenders: Self.vips) == .important)
    }

    @Test("Case and padding in the address don't matter")
    func addressIsNormalized() {
        #expect(LocalRulesEngine.classify(message(from: "  DAD@Family.Example "),
                                          vipSenders: Self.vips) == .important)
    }

    @Test("Mail from everyone else is unchanged")
    func nonVIPMailIsUnchanged() {
        #expect(LocalRulesEngine.classify(message(from: "stranger@example.com"),
                                          vipSenders: Self.vips) == .other)
        #expect(LocalRulesEngine.classify(message(from: "news@example.com",
                                                  listUnsubscribe: "<https://u.example/x>"),
                                          vipSenders: Self.vips) == .newsletter)
    }

    @Test("RELEASE GATE: a spoofed VIP stays a scam — VIP never overrides dmarc=fail")
    func spoofedVIPIsStillScam() {
        let spoof = message(from: "dad@family.example", dmarc: .fail)
        #expect(LocalRulesEngine.classify(spoof, vipSenders: Self.vips) == .scam)
    }

    @Test("A VIP's forwarded newsletter is important, not an unsubscribe candidate")
    func vipOutranksNewsletter() {
        let forwarded = message(from: "dad@family.example",
                                listUnsubscribe: "<https://u.example/x>")
        #expect(LocalRulesEngine.classify(forwarded, vipSenders: Self.vips) == .important)
    }

    @Test("An empty VIP list changes nothing")
    func emptyListIsInert() {
        #expect(LocalRulesEngine.classify(message(from: "dad@family.example"),
                                          vipSenders: []) == .other)
    }

    @Test("Address validation catches slips without rejecting real addresses")
    func addressValidation() {
        #expect(VIPEditor.looksLikeAnAddress("dad@family.example"))
        #expect(VIPEditor.looksLikeAnAddress("first.last+tag@sub.domain.co.uk"))
        #expect(!VIPEditor.looksLikeAnAddress("dad"))
        #expect(!VIPEditor.looksLikeAnAddress("dad@"))
        #expect(!VIPEditor.looksLikeAnAddress("@family.example"))
        #expect(!VIPEditor.looksLikeAnAddress("dad@family"))
        #expect(!VIPEditor.looksLikeAnAddress("dad @family.example"))
    }
}

@MainActor
struct InboxVIPTests {

    typealias FakeCredentialsStore = InboxEventSuggestionTests.FakeCredentialsStore
    typealias BodySource = InboxEventSuggestionTests.BodySource
    typealias OffAnalyzer = InboxEventSuggestionTests.OffAnalyzer

    struct FakeVIPReader: VIPReading {
        let senders: Set<String>
        func vipSenders() -> Set<String> { senders }
    }

    private func message(id: String, from: String) -> MailMessage {
        MailMessage(id: id, fromName: "Someone", fromAddress: from,
                    subject: "Hello", date: .now,
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass),
                    imapUID: 3)
    }

    private func loaded(_ messages: [MailMessage], vips: Set<String>) async -> InboxViewModel {
        let source = BodySource()
        source.messages = messages
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(), mailSource: source)
        vm.cloudAnalyzer = OffAnalyzer()
        vm.scansForEventHints = false
        vm.vipReader = FakeVIPReader(senders: vips)
        await vm.load()
        return vm
    }

    @Test("VIP mail reaches Important Email with no cloud verdict at all")
    func vipMailIsImportantWithoutTheCloud() async {
        let vm = await loaded([message(id: "a", from: "dad@family.example"),
                               message(id: "b", from: "stranger@example.com")],
                              vips: ["dad@family.example"])
        #expect(vm.important.map(\.id) == ["a"])
        #expect(vm.isVIP(vm.important[0]))
        #expect(vm.cloudVerdicts.isEmpty)
    }

    @Test("No VIPs → Important Email behaves exactly as before")
    func noVIPsNoChange() async {
        let vm = await loaded([message(id: "a", from: "dad@family.example")], vips: [])
        #expect(vm.important.isEmpty)
    }
}
