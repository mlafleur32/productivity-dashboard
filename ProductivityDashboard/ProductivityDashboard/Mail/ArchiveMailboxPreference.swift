// Mail/ArchiveMailboxPreference.swift
//
// Where "archive" puts a message on a server that doesn't publish the
// answer (Stage 9, Matt 2026-10-25). EarthLink is the case in point: the
// app asks for the RFC 6154 SPECIAL-USE flags and gets nothing marked
// \All or \Archive, and ARCHITECTURE.md's rule is that it must refuse rather
// than guess a mailbox name.
//
// The way out is not a cleverer guess — it's the user choosing, from the
// server's OWN list of mailboxes, which folder to use. Discovery by
// attribute stays the default; this preference is the explicit override,
// per account.
//
// Stored in UserDefaults, not the Keychain: a folder name is configuration,
// not a secret. Keyed by accountID so two accounts can differ.

import Foundation

nonisolated enum ArchiveMailboxPreference {
    private static func key(for accountID: String) -> String {
        "archiveMailbox.\(accountID)"
    }

    /// The user's chosen mailbox for this account, or nil for "ask the
    /// server" (the default).
    static func mailbox(for accountID: String?,
                        defaults: UserDefaults = .standard) -> String? {
        guard let accountID else { return nil }
        let raw = defaults.string(forKey: key(for: accountID))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    static func set(_ mailbox: String?, for accountID: String,
                    defaults: UserDefaults = .standard) {
        let trimmed = mailbox?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: key(for: accountID))
        } else {
            defaults.removeObject(forKey: key(for: accountID))
        }
    }
}
