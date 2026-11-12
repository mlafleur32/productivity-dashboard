// Mail/MultiAccountMailSource.swift
//
// Stage 9. One dashboard, several IMAP accounts.
//
// This type owns one IMAPMailSource per stored account and does three
// things, all of them boring on purpose:
//
//   1. fetchRecent fans out, in parallel, and merges newest-first. One
//      account failing does NOT fail the fetch: its error is recorded and
//      the other accounts' mail still reaches the dashboard. Only when
//      EVERY account fails does the error propagate, so the UI can say
//      "nothing could be loaded" rather than showing a silent empty inbox.
//   2. fetchBody and archive DISPATCH BY accountID. IMAP UIDs are
//      mailbox-local: UID 412 on EarthLink and UID 412 on Gmail are
//      different messages. Acting on the wrong account would read — or
//      archive — a message the user never pointed at, so an unknown
//      accountID is refused, never guessed.
//   3. Nothing else. No merging of duplicate messages across accounts (a
//      message delivered to both shows twice, tagged by account, and each
//      copy's actions act on its own account), no cross-account state.
//
// Credentials are read per call by each IMAPMailSource, exactly as before —
// this type holds none.

import Foundation
import os

final class MultiAccountMailSource: MailSource {
    // nonisolated for the same reason as IMAPMailSource.log: these calls
    // run in nonisolated task-group children under MainActor-by-default
    // isolation.
    private nonisolated static let log = Logger(
        subsystem: "LuminalMachines.ProductivityDashboard",
        category: "mail.accounts"
    )

    private let credentialsStore: CredentialsStore

    nonisolated init(credentialsStore: CredentialsStore) {
        self.credentialsStore = credentialsStore
    }

    /// Built fresh per call so adding or removing an account in Settings
    /// takes effect on the next poll with no extra plumbing.
    private nonisolated func sources() -> [(accountID: String, source: IMAPMailSource)] {
        let accounts = (try? credentialsStore.loadAll()) ?? []
        return accounts.map {
            ($0.accountID, IMAPMailSource(credentialsStore: credentialsStore, accountID: $0.accountID))
        }
    }

    nonisolated func fetchRecent(limit: Int) async throws -> [MailMessage] {
        let all = sources()
        guard !all.isEmpty else { throw InboxError.notConfigured }

        var merged: [MailMessage] = []
        var failures: [Error] = []

        await withTaskGroup(of: Result<[MailMessage], Error>.self) { group in
            for entry in all {
                group.addTask {
                    do { return .success(try await entry.source.fetchRecent(limit: limit)) }
                    catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let messages): merged.append(contentsOf: messages)
                case .failure(let error): failures.append(error)
                }
            }
        }

        if merged.isEmpty, let first = failures.first { throw first }
        if !failures.isEmpty {
            // Partial success is the common case on a flaky connection;
            // say so without naming the account's address in the log.
            Self.log.error("\(failures.count, privacy: .public) of \(all.count, privacy: .public) account(s) failed to fetch")
        }
        return merged.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    nonisolated func fetchBody(accountID: String?, imapUID: UInt32) async throws -> String? {
        try await source(for: accountID).fetchBody(accountID: accountID, imapUID: imapUID)
    }

    /// The dispatch rule, in one place: a message carries the account it
    /// came from, and that is the only connection allowed to act on its UID.
    private nonisolated func source(for accountID: String?) throws -> IMAPMailSource {
        let all = sources()
        guard !all.isEmpty else { throw InboxError.notConfigured }
        guard let accountID else {
            // No stamp (preview/test fixture, or a row from before this
            // build): with one account there is no ambiguity; with several
            // there is, and guessing could act on the wrong mailbox.
            guard all.count == 1 else {
                Self.log.error("UID with no account stamp, and more than one account — refused")
                throw InboxError.notConfigured
            }
            return all[0].source
        }
        guard let match = all.first(where: { $0.accountID == accountID }) else {
            Self.log.error("UID addressed to an account that is no longer configured — refused")
            throw InboxError.notConfigured
        }
        return match.source
    }
}

// MARK: - Archive (Stage 6 action, routed per account)

extension MultiAccountMailSource: MailArchiving {
    nonisolated func archive(_ action: ConfirmedArchiveAction) async throws -> ArchiveReceipt {
        // The confirmed action carries the message, and the message carries
        // its account — so the archive lands in the mailbox the user was
        // actually looking at.
        try await source(for: action.message.accountID).archive(action)
    }

    /// Undo of an archive goes back to the SAME account. A log row from
    /// before multiple accounts carries no stamp; source(for:) accepts that
    /// only while exactly one account is configured.
    nonisolated func unarchive(accountID: String?, newUID: UInt32, from mailbox: String) async throws {
        try await source(for: accountID).unarchive(accountID: accountID, newUID: newUID, from: mailbox)
    }
}
