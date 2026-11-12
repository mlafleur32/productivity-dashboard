//
//  InboxUnsubscribeTests.swift
//  ProductivityDashboardTests
//
//  Stage 7, Step D wiring: the view model offers unsubscribe only for mail
//  its own local classification put in .newsletter, executes exactly the
//  confirmed action, logs only on success, never removes the message, and
//  surfaces failures. The dialog copy names the destination host — never
//  the tokenized URL. Actions are minted through the REAL gate only.
//
//  Synthetic messages only (git hygiene rule).
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct InboxUnsubscribeTests {

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
        func fetchRecent(limit: Int) async throws -> [MailMessage] { messages }
    }

    final class OffAnalyzer: CloudAnalyzing, @unchecked Sendable {
        func isConfigured() -> Bool { false }
        func analyze(_ eligible: CloudEligibleMessage, rawBody: String) async throws -> CloudVerdict {
            throw CloudAnalysisError.notConfigured
        }
    }

    final class SpyUnsubscriber: MailUnsubscribing, @unchecked Sendable {
        var result: Result<UnsubscribeOutcome, UnsubscribeError>
        private(set) var executedIDs: [String] = []
        init(result: Result<UnsubscribeOutcome, UnsubscribeError> = .success(.oneClickAccepted(status: 200))) {
            self.result = result
        }
        var redirectTarget: URL?
        var followResult: Result<UnsubscribeOutcome, UnsubscribeError> = .success(.oneClickAccepted(status: 202))
        private(set) var followedTargets: [URL] = []

        func unsubscribe(_ action: ConfirmedUnsubscribeAction) async throws -> UnsubscribeOutcome {
            executedIDs.append(action.message.id)
            if let redirectTarget,
               let pending = UnsubscribeRedirectPolicy.pendingApproval(for: action, status: 307, target: redirectTarget) {
                return .redirectNeedsApproval(pending)
            }
            return try result.get()
        }

        func followRedirect(_ redirect: ConfirmedUnsubscribeRedirect) async throws -> UnsubscribeOutcome {
            followedTargets.append(redirect.target)
            return try followResult.get()
        }
    }

    struct GmailCredentialsStore: CredentialsStore {
        nonisolated func save(_ credentials: IMAPCredentials) throws {}
        nonisolated func loadAll() throws -> [IMAPCredentials] {
            [
            IMAPCredentials(server: "imap.gmail.com", port: 993,
                            account: "user@gmail.example", password: "test")
            ]
        }
        nonisolated func delete(accountID: String) throws {}
    }

    final class SpyOpener: WebLinkOpening, @unchecked Sendable {
        private(set) var opened: [URL] = []
        func open(_ url: URL) { opened.append(url) }
    }

    final class SpyLog: UnsubscribeLogRecording, @unchecked Sendable {
        private(set) var recorded: [(messageID: String, sender: String, outcome: UnsubscribeOutcome)] = []
        func record(messageID: String, senderAddress: String, outcome: UnsubscribeOutcome, at date: Date) {
            recorded.append((messageID, senderAddress, outcome))
        }
        private(set) var gmailHandoffs: [(messageID: String, sender: String)] = []
        func recordGmailHandoff(messageID: String, senderAddress: String, at date: Date) {
            gmailHandoffs.append((messageID, senderAddress))
        }
    }

    // MARK: - Helpers

    /// Newsletter-shaped (List-Id + one-click headers + dkim=pass) so the
    /// local rules engine classifies it .newsletter.
    private func newsletter(id: String) -> MailMessage {
        MailMessage(id: id, fromName: "Synthetic List", fromAddress: "news@list.example.com",
                    subject: "Synthetic newsletter", date: .now,
                    listUnsubscribe: "<https://unsub.example.com/u?t=secret-token>",
                    listUnsubscribePost: "List-Unsubscribe=One-Click",
                    listId: "<list.example.com>",
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass),
                    imapUID: 7)
    }

    /// Personal-shaped: no list headers → local .other, even though it
    /// carries a (forged) List-Unsubscribe-Post header.
    private func personal(id: String) -> MailMessage {
        MailMessage(id: id, fromName: "A Person", fromAddress: "person@example.com",
                    subject: "Lunch?", date: .now,
                    listUnsubscribePost: "List-Unsubscribe=One-Click",
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass),
                    imapUID: 8)
    }

    private func loadedViewModel(_ messages: [MailMessage],
                                 unsubscriber: SpyUnsubscriber? = nil,
                                 log: SpyLog? = nil,
                                 gmail: Bool = false) async -> InboxViewModel {
        let source = FakeMailSource()
        source.messages = messages
        let store: CredentialsStore = gmail ? GmailCredentialsStore() : FakeCredentialsStore()
        let vm = InboxViewModel(credentialsStore: store, mailSource: source)
        vm.cloudAnalyzer = OffAnalyzer()
        vm.unsubscriber = unsubscriber ?? SpyUnsubscriber()
        vm.unsubscribeLog = log ?? SpyLog()
        await vm.load()
        return vm
    }

    private func confirmed(_ vm: InboxViewModel, _ message: MailMessage) throws -> ConfirmedUnsubscribeAction {
        guard case .offer(let offer) = vm.unsubscribeDecision(for: message) else {
            Issue.record("expected an offer")
            throw CancellationError()
        }
        let flow = UnsubscribeConfirmationFlow()
        flow.request(offer)
        return try #require(flow.confirm())
    }

    // MARK: - Decisions come from the VM's own classification

    @Test("A locally-classified newsletter gets a one-click offer")
    func newsletterOffered() async {
        let msg = newsletter(id: "n1")
        let vm = await loadedViewModel([msg])
        guard case .offer(let offer) = vm.unsubscribeDecision(for: msg) else {
            Issue.record("expected an offer")
            return
        }
        #expect(offer.method.destinationLabel == "unsub.example.com")
    }

    @Test("Non-newsletter mail is never offered, even with unsubscribe headers")
    func personalNotOffered() async {
        let msg = personal(id: "p1")
        let vm = await loadedViewModel([msg])
        guard case .refused(.notNewsletter) = vm.unsubscribeDecision(for: msg) else {
            Issue.record("expected notNewsletter")
            return
        }
    }

    @Test("A message not in the current batch is never offered")
    func unknownMessageNotOffered() async {
        let vm = await loadedViewModel([])
        guard case .refused(.notNewsletter) = vm.unsubscribeDecision(for: newsletter(id: "ghost")) else {
            Issue.record("expected notNewsletter")
            return
        }
    }

    // MARK: - Execution

    @Test("A confirmed unsubscribe executes once, logs once, and the message stays")
    func successLogsAndKeepsMessage() async throws {
        let spy = SpyUnsubscriber()
        let log = SpyLog()
        let msg = newsletter(id: "n2")
        let vm = await loadedViewModel([msg], unsubscriber: spy, log: log)

        await vm.unsubscribe(try confirmed(vm, msg))

        #expect(spy.executedIDs == ["n2"])
        #expect(log.recorded.count == 1)
        #expect(log.recorded.first?.sender == "news@list.example.com")
        #expect(log.recorded.first?.outcome == .oneClickAccepted(status: 200))
        #expect(vm.messages.contains { $0.id == "n2" })
        #expect(vm.unsubscribeError == nil)
        #expect(vm.unsubscribingIDs.isEmpty)
    }

    @Test("A failed unsubscribe logs nothing and shows the error")
    func failureLogsNothing() async throws {
        let spy = SpyUnsubscriber(result: .failure(.redirectRefused(toHost: nil)))
        let log = SpyLog()
        let msg = newsletter(id: "n3")
        let vm = await loadedViewModel([msg], unsubscriber: spy, log: log)

        await vm.unsubscribe(try confirmed(vm, msg))

        #expect(log.recorded.isEmpty)
        #expect(vm.unsubscribeError == UnsubscribeError.redirectRefused(toHost: nil).userMessage)
        vm.dismissUnsubscribeError()
        #expect(vm.unsubscribeError == nil)
    }

    // MARK: - Cross-site redirect (second dialog)

    @Test("A cross-site hand-off asks: nothing logged, redirect staged for the second dialog")
    func redirectStagesSecondDialog() async throws {
        let spy = SpyUnsubscriber()
        spy.redirectTarget = URL(string: "https://links.vendor.example.net/u?t=tok")
        let log = SpyLog()
        let msg = newsletter(id: "r1")
        let vm = await loadedViewModel([msg], unsubscriber: spy, log: log)

        await vm.unsubscribe(try confirmed(vm, msg))

        #expect(log.recorded.isEmpty)
        #expect(vm.unsubscribeError == nil)
        #expect(vm.redirectFlow.pending?.targetHost == "links.vendor.example.net")
        #expect(spy.followedTargets.isEmpty)
    }

    @Test("Cancelling the second dialog sends nothing and logs nothing")
    func redirectCancelSendsNothing() async throws {
        let spy = SpyUnsubscriber()
        spy.redirectTarget = URL(string: "https://links.vendor.example.net/u")
        let log = SpyLog()
        let msg = newsletter(id: "r2")
        let vm = await loadedViewModel([msg], unsubscriber: spy, log: log)

        await vm.unsubscribe(try confirmed(vm, msg))
        vm.redirectFlow.cancel()

        #expect(vm.redirectFlow.confirm() == nil)
        #expect(spy.followedTargets.isEmpty)
        #expect(log.recorded.isEmpty)
    }

    @Test("Approving the second dialog follows once and logs the success once")
    func redirectApprovedLogsOnce() async throws {
        let spy = SpyUnsubscriber()
        spy.redirectTarget = URL(string: "https://links.vendor.example.net/u")
        let log = SpyLog()
        let msg = newsletter(id: "r3")
        let vm = await loadedViewModel([msg], unsubscriber: spy, log: log)

        await vm.unsubscribe(try confirmed(vm, msg))
        let approved = try #require(vm.redirectFlow.confirm())
        await vm.followRedirect(approved)

        #expect(spy.followedTargets.map(\.host) == ["links.vendor.example.net"])
        #expect(log.recorded.count == 1)
        #expect(log.recorded.first?.outcome == .oneClickAccepted(status: 202))
        #expect(log.recorded.first?.messageID == "r3")
    }

    @Test("Second-dialog copy names both hosts and what the new company sees — no tokens")
    func redirectDialogCopy() async throws {
        let spy = SpyUnsubscriber()
        spy.redirectTarget = URL(string: "https://links.vendor.example.net/u?t=secret-token")
        let msg = newsletter(id: "r4")
        let vm = await loadedViewModel([msg], unsubscriber: spy)

        await vm.unsubscribe(try confirmed(vm, msg))
        let pending = try #require(vm.redirectFlow.pending)
        let text = UnsubscribeDialogCopy.redirectMessage(pending)
        #expect(text.contains("unsub.example.com"))
        #expect(text.contains("links.vendor.example.net"))
        #expect(text.contains("IP address"))
        #expect(!text.contains("secret-token"))
        #expect(!text.contains("https://"))
    }

    // MARK: - Choices after a failed one-click

    private func failingOneClickNewsletter(id: String) -> MailMessage {
        MailMessage(id: "<\(id)@mail.list.example.com>", fromName: "Synthetic List",
                    fromAddress: "news@list.example.com", subject: "Synthetic newsletter", date: .now,
                    listUnsubscribe: "<mailto:leave@list.example.com>, <https://unsub.example.com/u?t=tok>",
                    listUnsubscribePost: "List-Unsubscribe=One-Click",
                    listId: "<list.example.com>",
                    authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass),
                    imapUID: 11)
    }

    @Test("A failed one-click offers Open in Gmail and the email fallback")
    func failedOneClickOffersChoices() async throws {
        let spy = SpyUnsubscriber(result: .failure(.rejected(status: 405)))
        let opener = SpyOpener()
        let msg = failingOneClickNewsletter(id: "f1")
        let vm = await loadedViewModel([msg], unsubscriber: spy, gmail: true)
        vm.webLinkOpener = opener

        await vm.unsubscribe(try confirmed(vm, msg))

        let failed = try #require(vm.failedUnsubscribe)
        #expect(failed.id == msg.id)
        let fallback = try #require(vm.mailtoFallbackOffer(for: failed))
        #expect(fallback.method.destinationLabel == "leave@list.example.com")

        vm.openInGmail(failed)
        #expect(opener.opened.count == 1)
        #expect(opener.opened.first?.host() == "mail.google.com")

        vm.dismissUnsubscribeError()
        #expect(vm.failedUnsubscribe == nil)
    }

    @Test("Open in Gmail records the choice exactly once")
    func openInGmailRecordsChoice() async {
        let log = SpyLog()
        let opener = SpyOpener()
        let msg = failingOneClickNewsletter(id: "g1")
        let vm = await loadedViewModel([msg], log: log, gmail: true)
        vm.webLinkOpener = opener

        vm.openInGmail(msg)

        #expect(opener.opened.count == 1)
        #expect(log.gmailHandoffs.count == 1)
        #expect(log.gmailHandoffs.first?.sender == "news@list.example.com")
        #expect(log.recorded.isEmpty)
    }

    @Test("No Gmail link → nothing opened, nothing recorded")
    func openInGmailWithoutLinkRecordsNothing() async {
        let log = SpyLog()
        let opener = SpyOpener()
        let msg = failingOneClickNewsletter(id: "g2")
        let vm = await loadedViewModel([msg], log: log, gmail: false)
        vm.webLinkOpener = opener

        vm.openInGmail(msg)

        #expect(opener.opened.isEmpty)
        #expect(log.gmailHandoffs.isEmpty)
    }

    @Test("Non-Gmail accounts never get an Open in Gmail link")
    func nonGmailNoLink() async {
        let msg = failingOneClickNewsletter(id: "f2")
        let vm = await loadedViewModel([msg], gmail: false)
        #expect(vm.gmailAccounts.isEmpty)
        #expect(vm.gmailLink(for: msg) == nil)
    }

    @Test("A failed email handoff doesn't offer the one-click choices")
    func failedMailtoNoChoices() async throws {
        let msg = MailMessage(id: "<f3@mail.list.example.com>", fromName: nil, fromAddress: "news@list.example.com",
                              subject: "Synthetic newsletter", date: .now,
                              listUnsubscribe: "<mailto:leave@list.example.com>",
                              listId: "<list.example.com>", imapUID: 12)
        let spy = SpyUnsubscriber(result: .failure(.mailAppUnavailable))
        let vm = await loadedViewModel([msg], unsubscriber: spy, gmail: true)

        await vm.unsubscribe(try confirmed(vm, msg))

        #expect(vm.unsubscribeError != nil)
        #expect(vm.failedUnsubscribe == nil)
    }

    // MARK: - Dialog copy

    @Test("One-click dialog names sender, subject and host — never the tokenized URL")
    func oneClickDialogCopy() async {
        let msg = newsletter(id: "n4")
        let vm = await loadedViewModel([msg])
        guard case .offer(let offer) = vm.unsubscribeDecision(for: msg) else {
            Issue.record("expected an offer")
            return
        }
        let text = UnsubscribeDialogCopy.message(offer)
        #expect(text.contains("Synthetic List"))
        #expect(text.contains("Synthetic newsletter"))
        #expect(text.contains("unsub.example.com"))
        #expect(!text.contains("secret-token"))
        #expect(!text.contains("https://"))
        #expect(text.contains("can't be undone"))
        #expect(UnsubscribeDialogCopy.confirmTitle(offer.method) == "Unsubscribe")
    }

    @Test("mailto dialog names the recipient and says nothing is sent until you send it")
    func mailtoDialogCopy() async {
        let msg = MailMessage(id: "n5", fromName: nil, fromAddress: "news@list.example.com",
                              subject: "Synthetic newsletter", date: .now,
                              listUnsubscribe: "<mailto:leave@list.example.com?subject=unsubscribe>",
                              listId: "<list.example.com>", imapUID: 9)
        let vm = await loadedViewModel([msg])
        guard case .offer(let offer) = vm.unsubscribeDecision(for: msg) else {
            Issue.record("expected an offer")
            return
        }
        let text = UnsubscribeDialogCopy.message(offer)
        #expect(text.contains("leave@list.example.com"))
        #expect(text.contains("Nothing is sent until you press Send"))
        #expect(UnsubscribeDialogCopy.confirmTitle(offer.method) == "Open Draft in Mail")
    }
}
