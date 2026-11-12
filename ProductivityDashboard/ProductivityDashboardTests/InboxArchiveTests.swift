//
//  InboxArchiveTests.swift
//  ProductivityDashboardTests
//
//  Stage 6 Step C wiring: the view model executes exactly the confirmed
//  action, removes the message from the local batch on success, keeps it
//  (with user-facing copy) on failure, and stays inert when no archiver is
//  available. Every action here is minted through the REAL confirmation
//  flow — there is no other way to obtain a ConfirmedArchiveAction, which
//  is itself the point of the gate.
//
//  Synthetic messages only (git hygiene rule).
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct InboxArchiveTests {

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

    final class SpyArchiver: MailArchiving, @unchecked Sendable {
        var result: Result<ArchiveReceipt, InboxError>
        var unarchiveError: InboxError?
        private(set) var archivedMessageIDs: [String] = []
        private(set) var unarchives: [(accountID: String?, newUID: UInt32, mailbox: String)] = []

        init(result: Result<ArchiveReceipt, InboxError> = .success(
            ArchiveReceipt(messageID: "unset", archivedTo: "[Gmail]/All Mail", newUID: 4242))
        ) {
            self.result = result
        }

        func archive(_ action: ConfirmedArchiveAction) async throws -> ArchiveReceipt {
            archivedMessageIDs.append(action.message.id)
            return try result.get()
        }

        func unarchive(accountID: String?, newUID: UInt32, from mailbox: String) async throws {
            unarchives.append((accountID, newUID, mailbox))
            if let unarchiveError { throw unarchiveError }
        }
    }

    /// Records log calls; the undo tests assert an entry is closed only
    /// after the reverse move succeeded.
    final class SpyArchiveLog: ArchiveLogRecording, @unchecked Sendable {
        private(set) var recorded: [(messageID: String, sender: String, archivedTo: String, newUID: UInt32?, accountID: String?, at: Date)] = []
        private(set) var undone: [String] = []

        func record(messageID: String, senderAddress: String,
                    archivedTo: String, newUID: UInt32?, accountID: String?, at date: Date) {
            recorded.append((messageID, senderAddress, archivedTo, newUID, accountID, date))
        }

        func markUndone(messageID: String, at date: Date) {
            undone.append(messageID)
        }
    }

    final class OffAnalyzer: CloudAnalyzing, @unchecked Sendable {
        func isConfigured() -> Bool { false }
        func analyze(_ eligible: CloudEligibleMessage, rawBody: String) async throws -> CloudVerdict {
            throw CloudAnalysisError.notConfigured
        }
    }

    // MARK: - Helpers

    private func message(id: String, uid: UInt32? = 7) -> MailMessage {
        MailMessage(id: id, fromName: "Synthetic Sender",
                    fromAddress: "sender@example.invalid",
                    subject: "Synthetic subject", date: .now, imapUID: uid)
    }

    /// A loaded view model whose inbox contains the given messages, with the
    /// cloud pass off (no key, no spend) and the spy standing in for IMAP.
    private func loadedViewModel(
        messages: [MailMessage],
        archiver: MailArchiving?
    ) async -> InboxViewModel {
        let source = FakeMailSource()
        source.messages = messages
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(),
                                mailSource: source)
        vm.cloudAnalyzer = OffAnalyzer()
        vm.archiver = archiver
        await vm.load()
        return vm
    }

    /// Mint through the real gate — the only mint site in the app.
    private func confirmed(_ message: MailMessage) throws -> ConfirmedArchiveAction {
        let flow = ArchiveConfirmationFlow()
        flow.request(message)
        return try #require(flow.confirm())
    }

    // MARK: - Tests

    @Test("A confirmed archive reaches the archiver and the message leaves the batch")
    func successRemovesMessage() async throws {
        let spy = SpyArchiver()
        let vm = await loadedViewModel(
            messages: [message(id: "keep"), message(id: "archive-me")],
            archiver: spy)

        await vm.archive(try confirmed(message(id: "archive-me")))

        #expect(spy.archivedMessageIDs == ["archive-me"])
        #expect(vm.messages.map(\.id) == ["keep"])
        #expect(!vm.categorized.contains { $0.id == "archive-me" })
        #expect(vm.archiveError == nil)
        #expect(vm.archivingIDs.isEmpty)
    }

    @Test("A failed archive keeps the message and surfaces the error")
    func failureKeepsMessage() async throws {
        let spy = SpyArchiver(result: .failure(.archiveFailed))
        let vm = await loadedViewModel(messages: [message(id: "m1")], archiver: spy)

        await vm.archive(try confirmed(message(id: "m1")))

        #expect(vm.messages.map(\.id) == ["m1"])
        #expect(vm.archiveError == InboxError.archiveFailed.userMessage)
        vm.dismissArchiveError()
        #expect(vm.archiveError == nil)
    }

    @Test("No archiver available: inert failure, nothing removed")
    func noArchiverIsInert() async throws {
        let vm = await loadedViewModel(messages: [message(id: "m1")], archiver: nil)

        await vm.archive(try confirmed(message(id: "m1")))

        #expect(vm.messages.map(\.id) == ["m1"])
        #expect(vm.archiveError != nil)
    }

    @Test("The default archiver is the mail source only when it can archive")
    func archiverDefaultsFromMailSource() {
        // FakeMailSource is not MailArchiving, so the default must be nil —
        // never a write path the source didn't explicitly provide.
        let vm = InboxViewModel(credentialsStore: FakeCredentialsStore(),
                                mailSource: FakeMailSource())
        #expect(vm.archiver == nil)
    }

    // MARK: - Step D: log + undo

    @Test("A successful archive records the receipt's undo handle to the log")
    func successRecordsToLog() async throws {
        let spy = SpyArchiver(result: .success(
            ArchiveReceipt(messageID: "m1", archivedTo: "[Gmail]/All Mail", newUID: 4242)))
        let log = SpyArchiveLog()
        let vm = await loadedViewModel(messages: [message(id: "m1")], archiver: spy)
        vm.archiveLog = log

        await vm.archive(try confirmed(message(id: "m1")))

        let entry = try #require(log.recorded.first)
        #expect(entry.messageID == "m1")
        #expect(entry.sender == "sender@example.invalid")
        #expect(entry.archivedTo == "[Gmail]/All Mail")
        #expect(entry.newUID == 4242)
    }

    @Test("A failed archive records nothing to the log")
    func failureRecordsNothing() async throws {
        let spy = SpyArchiver(result: .failure(.archiveFailed))
        let log = SpyArchiveLog()
        let vm = await loadedViewModel(messages: [message(id: "m1")], archiver: spy)
        vm.archiveLog = log

        await vm.archive(try confirmed(message(id: "m1")))
        #expect(log.recorded.isEmpty)
    }

    @Test("Undo reverses the move with the handle, closes the entry, reloads")
    func undoSuccess() async throws {
        let spy = SpyArchiver()
        let log = SpyArchiveLog()
        let vm = await loadedViewModel(messages: [message(id: "m1")], archiver: spy)
        vm.archiveLog = log

        await vm.undoArchive(messageID: "m1", newUID: 4242, archivedTo: "[Gmail]/All Mail")

        #expect(spy.unarchives.count == 1)
        #expect(spy.unarchives.first?.newUID == 4242)
        #expect(spy.unarchives.first?.mailbox == "[Gmail]/All Mail")
        #expect(log.undone == ["m1"])
        #expect(vm.archiveError == nil)
    }

    @Test("A failed undo leaves the log entry open and surfaces honest copy")
    func undoFailureKeepsEntryOpen() async {
        let spy = SpyArchiver()
        spy.unarchiveError = .archiveFailed
        let log = SpyArchiveLog()
        let vm = await loadedViewModel(messages: [], archiver: spy)
        vm.archiveLog = log

        await vm.undoArchive(messageID: "m1", newUID: 4242, archivedTo: "[Gmail]/All Mail")

        #expect(log.undone.isEmpty)
        let copy = vm.archiveError ?? ""
        #expect(copy.contains("[Gmail]/All Mail"))
        #expect(!copy.contains("inbox"))  // archiveFailed's stock copy would lie here
    }

    @Test("Undo without a COPYUID handle never touches the network")
    func undoWithoutHandleIsInert() async {
        let spy = SpyArchiver()
        let log = SpyArchiveLog()
        let vm = await loadedViewModel(messages: [], archiver: spy)
        vm.archiveLog = log

        await vm.undoArchive(messageID: "m1", newUID: nil, archivedTo: "[Gmail]/All Mail")

        #expect(spy.unarchives.isEmpty)
        #expect(log.undone.isEmpty)
        #expect(vm.archiveError != nil)
    }
}
