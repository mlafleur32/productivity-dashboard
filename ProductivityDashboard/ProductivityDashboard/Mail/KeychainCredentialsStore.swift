// Mail/KeychainCredentialsStore.swift
//
// Security framework wrapper for IMAPCredentials. Uses
// kSecClassInternetPassword (designed for host+port+protocol+username+password
// tuples) rather than kSecClassGenericPassword (which would require us to
// glue a composite key by hand).
//
// Never change — explicit constraints, do not relax without re-reading
// ARCHITECTURE.md Security & Privacy:
//
//   - kSecAttrSynchronizable: must stay false.
//       true syncs the item to iCloud Keychain. ARCHITECTURE.md is explicit
//       that this app is single-device and credentials must not leave
//       this Mac. The attribute is set explicitly on every read AND
//       write so the constraint cannot be silently flipped by a
//       Keychain default change.
//
//   - kSecAttrAccessible: must stay kSecAttrAccessibleWhenUnlocked.
//       More permissive values (e.g. kSecAttrAccessibleAlways,
//       kSecAttrAccessibleAfterFirstUnlock) would let the credential
//       be read at boot before the user logs in, broadening the
//       window where a process running as the user could access it.

import Foundation
import Security
import os

enum CredentialsError: Error {
    case encodingFailed
    case malformedItem
    case keychainError(OSStatus)
}

final class KeychainCredentialsStore: CredentialsStore {
    // Status codes only — never an account, server or password.
    private nonisolated static let log = Logger(
        subsystem: "LuminalMachines.ProductivityDashboard",
        category: "keychain"
    )

    nonisolated func save(_ credentials: IMAPCredentials) throws {
        // Demo mode / preview canvas: the real Keychain is never touched.
        if RealIOGuard.isBlocked { throw CredentialsError.encodingFailed }
        guard let passwordData = credentials.password.data(using: .utf8) else {
            throw CredentialsError.encodingFailed
        }

        // Stage 9: delete only THIS account's item, not every IMAPS item.
        // (Before multiple accounts this deleted them all, so reconfiguring
        // could not orphan a stale credential; now the account+server pair
        // is the identity, and a narrow delete is what keeps the other
        // account's item alive.) Delete-then-add stays idempotent;
        // errSecItemNotFound on the delete is fine.
        SecItemDelete(Self.itemQuery(account: credentials.account,
                                     server: credentials.server) as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass:              kSecClassInternetPassword,
            kSecAttrServer:         credentials.server,
            kSecAttrPort:           credentials.port,
            kSecAttrProtocol:       kSecAttrProtocolIMAPS,
            kSecAttrAccount:        credentials.account,
            kSecAttrSynchronizable: false,
            kSecAttrAccessible:     kSecAttrAccessibleWhenUnlocked,
            kSecValueData:          passwordData,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialsError.keychainError(status)
        }
    }

    /// Every stored account, in TWO steps, and that is load-bearing:
    /// asking for kSecMatchLimitAll together with kSecReturnData does not
    /// reliably return the passwords on macOS — the match comes back
    /// without data (or empty), which looked exactly like "no accounts
    /// configured" (field bug, 2026-10-25: the Accounts screen showed
    /// nothing while the app was happily fetching that very account).
    /// So: list the ATTRIBUTES of every item, then read each password with
    /// its own single-item query, which is the shape that has always
    /// worked here.
    nonisolated func loadAll() throws -> [IMAPCredentials] {
        if RealIOGuard.isBlocked { return [] }
        let listQuery: [CFString: Any] = [
            kSecClass:              kSecClassInternetPassword,
            kSecAttrProtocol:       kSecAttrProtocolIMAPS,
            kSecAttrSynchronizable: false,
            kSecMatchLimit:         kSecMatchLimitAll,
            kSecReturnAttributes:   true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                throw CredentialsError.malformedItem
            }
            // A single unreadable item must not hide the healthy ones.
            let decoded = items.compactMap { Self.credentialsReadingPassword(for: $0) }
            Self.log.info("loadAll: \(items.count, privacy: .public) item(s) listed, \(decoded.count, privacy: .public) readable")
            return decoded.sorted { $0.accountID < $1.accountID }
        case errSecItemNotFound:
            Self.log.info("loadAll: no IMAPS items stored")
            return []
        default:
            Self.log.error("loadAll: SecItemCopyMatching failed, OSStatus \(status, privacy: .public)")
            throw CredentialsError.keychainError(status)
        }
    }

    /// Second step: the password for one listed item.
    private nonisolated static func credentialsReadingPassword(
        for attributes: [String: Any]
    ) -> IMAPCredentials? {
        guard let server = attributes[kSecAttrServer as String] as? String,
              let port = attributes[kSecAttrPort as String] as? Int,
              let account = attributes[kSecAttrAccount as String] as? String else {
            return nil
        }
        var query = itemQuery(account: account, server: server)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return IMAPCredentials(server: server, port: port, account: account, password: password)
    }

    nonisolated func load(accountID: String) throws -> IMAPCredentials? {
        try loadAll().first { $0.accountID == accountID }
    }

    nonisolated func delete(accountID: String) throws {
        if RealIOGuard.isBlocked { return }
        guard let existing = try load(accountID: accountID) else { return }
        let status = SecItemDelete(Self.itemQuery(account: existing.account,
                                                  server: existing.server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialsError.keychainError(status)
        }
    }

    // MARK: - Helpers

    nonisolated private static func itemQuery(account: String, server: String) -> [CFString: Any] {
        [
            kSecClass:              kSecClassInternetPassword,
            kSecAttrProtocol:       kSecAttrProtocolIMAPS,
            kSecAttrServer:         server,
            kSecAttrAccount:        account,
            kSecAttrSynchronizable: false,
        ]
    }


}
