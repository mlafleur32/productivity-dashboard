// Cloud/APIKeyStore.swift
//
// Keychain storage for the Claude API key (Stage 5, Step B). Same discipline
// as KeychainCredentialsStore, same non-negotiables — Security framework
// directly (ARCHITECTURE.md Dependencies bans Keychain wrapper libraries), and:
//
//   - kSecAttrSynchronizable: must stay false, set explicitly on every
//     read AND write. The key must never reach iCloud Keychain.
//   - kSecAttrAccessible: must stay kSecAttrAccessibleWhenUnlocked.
//
// kSecClassGenericPassword (not InternetPassword): an API key has no
// host/port/protocol identity — service+account is the natural composite key.
//
// Fail-safe posture: no stored key simply means the Stage 5 cloud path does
// not run; everything stays local. load() returning nil is a normal state,
// not an error.

import Foundation
import Security

protocol APIKeyStoring: Sendable {
    func save(_ key: String) throws
    func load() throws -> String?
    func delete() throws
}

final class KeychainAPIKeyStore: APIKeyStoring {

    // Composite identity of our single API-key slot.
    private static let service = "ProductivityDashboard.ClaudeAPIKey"
    private static let account = "anthropic-api-key"

    // Hard guard, same rationale as IMAPMailSource.fetchRecent: #Preview
    // instantiates real view trees, and the canvas must never touch the
    // real Keychain. Placed here at the choke point so no future #Preview
    // that forgets to inject a fake can bypass it. Preview behavior:
    // save/delete no-op, load reports "no key" — the safe empty state.
    private var isPreviewCanvas: Bool {
        RealIOGuard.isBlocked
    }

    func save(_ key: String) throws {
        if isPreviewCanvas { return }
        guard let keyData = key.data(using: .utf8) else {
            throw CredentialsError.encodingFailed
        }

        // One slot: delete-then-add is idempotent and can never leave two
        // items answering the same query (same reasoning as the IMAP store).
        SecItemDelete(Self.baseQuery as CFDictionary)

        var addQuery = Self.baseQuery
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        addQuery[kSecValueData] = keyData

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialsError.keychainError(status)
        }
    }

    func load() throws -> String? {
        if isPreviewCanvas { return nil }
        return try Self.readStoredKey()
    }

    /// The Keychain read itself, with no guard. fileprivate: callable only
    /// by load() above and by AgentAPIKeyReader below, each of which applies
    /// its own guard first.
    fileprivate static func readStoredKey() throws -> String? {
        var query = Self.baseQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let keyData = result as? Data,
                  let key = String(data: keyData, encoding: .utf8) else {
                throw CredentialsError.malformedItem
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialsError.keychainError(status)
        }
    }

    func delete() throws {
        if isPreviewCanvas { return }
        let status = SecItemDelete(Self.baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialsError.keychainError(status)
        }
    }

    private static let baseQuery: [CFString: Any] = [
        kSecClass:              kSecClassGenericPassword,
        kSecAttrService:        service,
        kSecAttrAccount:        account,
        kSecAttrSynchronizable: false,
    ]
}

// MARK: - The triage agent's key read

/// Read side only, for the triage agent (Agent/TriageAgent.swift).
protocol AgentAPIKeyReading: Sendable {
    func loadForAgent() throws -> String?
}

/// THE ONE DELIBERATE EXCEPTION to demo mode's Keychain block (settled
/// 2026-11-12). Demo mode exists partly so the agent can be shown working
/// live, and a live run needs the real API key. So this reader is refused
/// in the preview canvas, like everything else, but NOT in demo mode.
///
/// Why this is narrow enough:
///   - It can only READ the API key. No save, no delete, and no access to
///     the IMAP credentials, which live in a different Keychain item that
///     stays fully blocked.
///   - Only TriageAgent uses it. KeychainAPIKeyStore.load(), which the
///     analyzer and Settings use, still returns nil in demo mode, so the
///     shared guard is exactly as strict as before.
///   - In demo mode every source the agent reads from is synthetic
///     (DemoEnvironment), so what the key ends up sending is demo data.
struct AgentAPIKeyReader: AgentAPIKeyReading {
    func loadForAgent() throws -> String? {
        if RealIOGuard.isPreviewCanvas { return nil }
        return try KeychainAPIKeyStore.readStoredKey()
    }
}
