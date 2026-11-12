//
//  MultiAccountTests.swift
//  ProductivityDashboardTests
//
//  Stage 9. Two accounts, one dashboard. The rules worth pinning are the
//  ones about NOT mixing them up: IMAP UIDs are mailbox-local, so a UID
//  addressed to the wrong account would read or archive a message the user
//  never pointed at. Synthetic credentials only — no Keychain, no network.
//

import Testing
import Foundation
@testable import ProductivityDashboard

/// In-memory store standing in for the Keychain. At file scope and
/// `nonisolated` on purpose: CredentialsStore's requirements are
/// nonisolated (the fetch paths read credentials off the main actor), and a
/// type nested in a @MainActor suite keeps main-actor isolation for its
/// stored properties, which those requirements then can't touch. Serial use
/// in tests is what makes @unchecked Sendable honest.
nonisolated final class FakeCredentialStore: CredentialsStore, @unchecked Sendable {
    private(set) var saved: [IMAPCredentials] = []
    init(_ accounts: [IMAPCredentials] = []) { saved = accounts }
    func save(_ credentials: IMAPCredentials) throws {
        saved.removeAll { $0.accountID == credentials.accountID }
        saved.append(credentials)
    }
    func loadAll() throws -> [IMAPCredentials] { saved }
    func delete(accountID: String) throws {
        saved.removeAll { $0.accountID == accountID }
    }
}

@MainActor
struct AccountIdentityTests {

    @Test("accountID is the address and server, normalized")
    func accountIDNormalizes() {
        let a = IMAPCredentials(server: "IMAP.Mindspring.com", port: 993,
                                account: " Pat@Mindspring.com ", password: "x")
        let b = IMAPCredentials(server: "imap.mindspring.com", port: 993,
                                account: "pat@mindspring.com", password: "y")
        #expect(a.accountID == b.accountID)
    }

    @Test("The same address on two servers is two accounts")
    func sameAddressDifferentServers() {
        let a = IMAPCredentials(server: "imap.mindspring.com", port: 993,
                                account: "someone@example.com", password: "x")
        let b = IMAPCredentials(server: "imap.earthlink.net", port: 993,
                                account: "someone@example.com", password: "x")
        #expect(a.accountID != b.accountID)
    }

    @Test("A credential's accountID never contains the password")
    func accountIDHasNoSecret() {
        let c = IMAPCredentials(server: "imap.example.com", port: 993,
                                account: "user@example.com", password: "hunter2-secret")
        #expect(!c.accountID.contains("hunter2-secret"))
    }
}

@MainActor
struct MultiAccountRoutingTests {

    nonisolated static let mindspring = IMAPCredentials(
        server: "imap.mindspring.com", port: 993,
        account: "pat@mindspring.com", password: "a")
    nonisolated static let gmail = IMAPCredentials(
        server: "imap.gmail.com", port: 993,
        account: "someone@gmail.com", password: "b")

    @Test("Saving two accounts keeps both; saving one again replaces it")
    func storeHoldsManyAccounts() throws {
        let store = FakeCredentialStore()
        try store.save(Self.mindspring)
        try store.save(Self.gmail)
        #expect(try store.loadAll().count == 2)

        try store.save(IMAPCredentials(server: "imap.mindspring.com", port: 993,
                                       account: "pat@mindspring.com", password: "new"))
        #expect(try store.loadAll().count == 2)
        #expect(try store.load(accountID: Self.mindspring.accountID)?.password == "new")
    }

    @Test("Removing one account leaves the other alone")
    func removeOneAccount() throws {
        let store = FakeCredentialStore([Self.mindspring, Self.gmail])
        try store.delete(accountID: Self.gmail.accountID)
        #expect(try store.loadAll().map(\.accountID) == [Self.mindspring.accountID])
    }

    @Test("RELEASE GATE: a UID for an unknown account is refused, not guessed")
    func unknownAccountIsRefused() async {
        let source = MultiAccountMailSource(
            credentialsStore: FakeCredentialStore([Self.mindspring, Self.gmail]))
        await #expect(throws: InboxError.self) {
            _ = try await source.fetchBody(accountID: "nobody@nowhere.example|imap.nowhere.example",
                                           imapUID: 412)
        }
    }

    @Test("RELEASE GATE: an unstamped UID is refused while several accounts exist")
    func unstampedUIDRefusedWithManyAccounts() async {
        let source = MultiAccountMailSource(
            credentialsStore: FakeCredentialStore([Self.mindspring, Self.gmail]))
        // With two accounts there is no safe default: UID 412 exists in both.
        await #expect(throws: InboxError.self) {
            _ = try await source.fetchBody(accountID: nil, imapUID: 412)
        }
    }

    @Test("No accounts configured reads as not configured")
    func noAccounts() async {
        let source = MultiAccountMailSource(credentialsStore: FakeCredentialStore())
        await #expect(throws: InboxError.self) {
            _ = try await source.fetchRecent(limit: 10)
        }
    }
}

@MainActor
struct MergedInboxTests {

    typealias FakeCredentialsStore = InboxEventSuggestionTests.FakeCredentialsStore

    final class TwoAccountSource: MailSource, @unchecked Sendable {
        var messages: [MailMessage] = []
        func fetchRecent(limit: Int) async throws -> [MailMessage] {
            messages.sorted { $0.date > $1.date }
        }
    }

    final class OffAnalyzer: CloudAnalyzing, @unchecked Sendable {
        func isConfigured() -> Bool { false }
        func analyze(_ eligible: CloudEligibleMessage, rawBody: String) async throws -> CloudVerdict {
            throw CloudAnalysisError.notConfigured
        }
    }

    private func message(id: String, account: String?, minutesAgo: Int) -> MailMessage {
        MailMessage(id: id, fromName: "Someone", fromAddress: "s@example.com",
                    subject: "Hello", date: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)),
                    imapUID: 1, accountID: account)
    }

    @Test("Both accounts' mail lands in one list, newest first")
    func mergedNewestFirst() async {
        let source = TwoAccountSource()
        source.messages = [
            message(id: "old-gmail", account: "a|imap.gmail.com", minutesAgo: 30),
            message(id: "new-mindspring", account: "b|imap.mindspring.com", minutesAgo: 5),
        ]
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(), mailSource: source)
        vm.cloudAnalyzer = OffAnalyzer()
        vm.scansForEventHints = false
        await vm.load()
        #expect(vm.messages.map(\.id) == ["new-mindspring", "old-gmail"])
    }

    @Test("A message keeps the account it came from")
    func messageKeepsItsAccount() async {
        let source = TwoAccountSource()
        source.messages = [message(id: "m", account: "b|imap.mindspring.com", minutesAgo: 1)]
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(), mailSource: source)
        vm.cloudAnalyzer = OffAnalyzer()
        vm.scansForEventHints = false
        await vm.load()
        #expect(vm.messages.first?.accountID == "b|imap.mindspring.com")
    }
}

@MainActor
struct AccountTagTests {

    @Test("The row tag is short: local part and provider")
    func shortTag() {
        #expect(InboxViewModel.shortTag(for: "pat@mindspring.com") == "pat · mindspring")
        #expect(InboxViewModel.shortTag(for: "someone@gmail.com") == "someone · gmail")
    }

    @Test("An address it can't split is shown as-is")
    func oddAddressPassesThrough() {
        #expect(InboxViewModel.shortTag(for: "not-an-address") == "not-an-address")
    }
}

@MainActor
struct ArchiveMailboxPreferenceTests {

    private func scratchDefaults() -> UserDefaults {
        let suite = "archive-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Unset means automatic — the app asks the server")
    func unsetIsAutomatic() {
        let d = scratchDefaults()
        #expect(ArchiveMailboxPreference.mailbox(for: "a|imap.example.com", defaults: d) == nil)
    }

    @Test("A chosen folder is remembered per account")
    func perAccountChoice() {
        let d = scratchDefaults()
        ArchiveMailboxPreference.set("Saved Mail", for: "a|imap.mindspring.com", defaults: d)
        #expect(ArchiveMailboxPreference.mailbox(for: "a|imap.mindspring.com", defaults: d) == "Saved Mail")
        // The other account is untouched.
        #expect(ArchiveMailboxPreference.mailbox(for: "b|imap.gmail.com", defaults: d) == nil)
    }

    @Test("Clearing it goes back to automatic")
    func clearingReturnsToAutomatic() {
        let d = scratchDefaults()
        ArchiveMailboxPreference.set("Saved Mail", for: "a|imap.mindspring.com", defaults: d)
        ArchiveMailboxPreference.set(nil, for: "a|imap.mindspring.com", defaults: d)
        #expect(ArchiveMailboxPreference.mailbox(for: "a|imap.mindspring.com", defaults: d) == nil)
    }

    @Test("Whitespace-only is treated as automatic, never as a folder named ' '")
    func blankIsAutomatic() {
        let d = scratchDefaults()
        ArchiveMailboxPreference.set("   ", for: "a|imap.mindspring.com", defaults: d)
        #expect(ArchiveMailboxPreference.mailbox(for: "a|imap.mindspring.com", defaults: d) == nil)
    }

    @Test("No account stamp means automatic")
    func noAccountIsAutomatic() {
        #expect(ArchiveMailboxPreference.mailbox(for: nil) == nil)
    }
}

@MainActor
struct SetupServerSuggestionTests {

    @Test("Validated providers get their IMAP server filled in")
    func knownProviders() {
        #expect(InboxSetupSheet.suggestedServer(forEmail: "pat@gmail.com") == "imap.gmail.com")
        #expect(InboxSetupSheet.suggestedServer(forEmail: "pat@mindspring.com") == "imap.mindspring.com")
        #expect(InboxSetupSheet.suggestedServer(forEmail: "Pat@EarthLink.net ") == "imap.earthlink.net")
    }

    @Test("Anything else stays blank rather than guessed")
    func unknownProvidersStayBlank() {
        #expect(InboxSetupSheet.suggestedServer(forEmail: "pat@example.com") == nil)
        #expect(InboxSetupSheet.suggestedServer(forEmail: "not-an-address") == nil)
    }
}
