// Mail/MailTypes.swift
//
// The testable surface of the mail layer: domain model, credentials struct,
// error enum, and the MailSource / CredentialsStore protocols. Deliberately
// has no Network framework, no Security framework, no EventKit imports —
// purely Foundation types. The concrete implementations live in
// IMAPMailSource.swift (Network framework) and KeychainCredentialsStore.swift
// (Security framework). Same separation pattern as Calendar/CalendarTypes.swift.

import Foundation

struct MailMessage: Identifiable, Hashable, Sendable {
    let id: String
    let fromName: String?
    let fromAddress: String
    let subject: String
    let date: Date
    // Header-derived signals for the local rules engine (Stage 4). Each is
    // nil when the header was absent, or when the fetch hasn't been expanded
    // to request it. authentication is the TRUSTED verdict only (see
    // AuthenticationResults) — nil means no trustworthy A-R was present.
    let listUnsubscribe: String?
    // RFC 8058 one-click marker (Stage 7). Only meaningful alongside an
    // https: List-Unsubscribe URI and a trusted dkim=pass — see
    // ListUnsubscribeParser and the Stage 7 spec in ARCHITECTURE.md.
    let listUnsubscribePost: String?
    let listId: String?
    let precedence: String?
    let authentication: AuthenticationResults?
    // IMAP UID within INBOX, kept so Stage 5 can lazily fetch this message's
    // body later in the poll cycle (fetchBody(imapUID:)). In-memory only —
    // UIDs are mailbox-local and can be invalidated by UIDVALIDITY changes,
    // so they are never persisted. nil for non-IMAP sources (previews, tests).
    let imapUID: UInt32?
    // Stage 9: which account this message came from (IMAPCredentials.accountID),
    // nil for previews, tests and any single-source path. IMAP UIDs are
    // mailbox-local, so every UID-keyed operation — body fetch, archive —
    // must be dispatched to THIS account's connection and no other.
    let accountID: String?
    // Sender-identity checks computed on THIS MAC from the message's own
    // headers. The headers themselves are not kept; these booleans are.
    let forensics: HeaderForensics?

    init(
        id: String,
        fromName: String?,
        fromAddress: String,
        subject: String,
        date: Date,
        listUnsubscribe: String? = nil,
        listUnsubscribePost: String? = nil,
        listId: String? = nil,
        precedence: String? = nil,
        authentication: AuthenticationResults? = nil,
        imapUID: UInt32? = nil,
        accountID: String? = nil,
        forensics: HeaderForensics? = nil
    ) {
        self.id = id
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.subject = subject
        self.date = date
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.listId = listId
        self.precedence = precedence
        self.authentication = authentication
        self.imapUID = imapUID
        self.accountID = accountID
        self.forensics = forensics
    }
}

// IMAPCredentials holds the secret in a plain Swift String. Swift has no
// SecureString type and copy-on-write means we cannot guarantee zeroing.
// Two mitigations make this acceptable for our threat model
// (single-user desktop, attacker-with-root is out of scope):
//   1. The struct's description / debugDescription are overridden to redact
//      the password, so accidental `print(creds)` or string interpolation
//      in error messages cannot leak the secret.
//   2. The view model and IMAPMailSource fetch credentials on demand from
//      the CredentialsStore and discard the instance after use — the
//      credential is resident only for the seconds of a connection setup.
struct IMAPCredentials: Sendable {
    let server: String
    let port: Int
    let account: String
    let password: String
}

extension IMAPCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "IMAPCredentials(server: \(server):\(port), account: \(account), password: <redacted>)"
    }
    var debugDescription: String { description }
}

/// What a completed archive reports back (Stage 6). `archivedTo` +
/// `newUID` together are the undo handle: UID MOVE gives the message a
/// fresh UID in the destination mailbox, reported via UIDPLUS COPYUID.
/// `newUID` is nil when the server didn't report one — undo then falls
/// back to searching the destination by Message-ID. Like all UIDs, valid
/// for the current UIDVALIDITY only; the action log treats it as a hint,
/// never a guarantee.
struct ArchiveReceipt: Equatable, Sendable {
    let messageID: String
    let archivedTo: String
    let newUID: UInt32?
}

enum InboxError: Error, Sendable, Equatable {
    case notConfigured
    case loginFailed
    case networkUnreachable
    case tlsFailure
    case rateLimited
    case unexpectedResponse
    case connectionDropped
    case timedOut
    case credentialsSaveFailed
    case archiveFailed
    /// The server answered the SPECIAL-USE query but advertises neither
    /// \All nor \Archive (Stage 9: older servers may not implement RFC
    /// 6154 at all). Distinct from archiveFailed so the user is told what
    /// to do rather than just that it didn't work — the app still refuses
    /// to guess a mailbox name.
    case archiveNoDestination
}

extension InboxError {
    // User-facing copy. Deliberately vague about WHY login failed: could be
    // wrong password, wrong email, revoked app-specific password, or wrong
    // server. All paths lead to "fix your credentials," and naming the
    // specific cause incorrectly is worse than naming it generically.
    var userMessage: String {
        switch self {
        case .notConfigured:      return "Email not set up."
        case .loginFailed:        return "Email login failed. Check your app-specific password."
        case .networkUnreachable: return "Can't reach the mail server. Trying again shortly."
        case .tlsFailure:         return "Couldn't establish a secure connection to the mail server."
        case .rateLimited:        return "Mail server is temporarily limiting us. Will retry in a few minutes."
        case .unexpectedResponse: return "Couldn't read the mail server's response."
        case .connectionDropped:  return "Connection to the mail server was interrupted."
        case .timedOut:           return "The mail server took too long to respond. Trying again shortly."
        case .credentialsSaveFailed:
            return "Couldn't save your credentials to the Keychain. Click Configure to try again."
        case .archiveNoDestination:
            return "This account doesn't publish an Archive or All Mail folder, so the app won't guess one. Pick the folder in Settings ▸ Accounts."
        case .archiveFailed:
            return "Couldn't archive the message. It's still in your inbox."
        }
    }
}

// MailSource exists so the view model depends on a protocol, not on
// NWConnection or raw IMAP wire code. A future test can construct
// InboxViewModel with a fake MailSource and verify state transitions
// without opening a real socket.
protocol MailSource: Sendable {
    func fetchRecent(limit: Int) async throws -> [MailMessage]

    /// Stage 5 lazy body fetch: the plain-text body of ONE message, by IMAP
    /// UID — called only for messages that already passed the ambiguity
    /// filter and the allowlist gate. Returns nil when the message has no
    /// extractable text/plain part (or no longer exists); callers treat nil
    /// as "skip cloud analysis, keep the local verdict".
    /// `accountID` names the account whose INBOX the UID belongs to
    /// (Stage 9). A single-account source ignores it; the multi-account
    /// source dispatches on it, and refuses rather than guessing when it
    /// names an account it does not have.
    func fetchBody(accountID: String?, imapUID: UInt32) async throws -> String?
}

extension MailSource {
    // Fail-safe default so previews and test fakes without bodies keep
    // compiling: no body means the cloud path simply doesn't run.
    func fetchBody(accountID: String?, imapUID: UInt32) async throws -> String? { nil }
}

// CredentialsStore exists for two reasons:
//   1. Same testability story — a fake store in tests removes the need to
//      touch the real macOS Keychain.
//   2. Centralizes the credential lifetime contract: the only place that
//      knows the password byte sequence is the store (load) and whatever
//      caller is mid-connection. Nothing else holds it.
// load() returns nil for "no credentials stored" — that's a normal
// first-run state, not an error.
// Stage 9: many accounts, one store. accountID (below) is the key —
// "account|server", lowercased — so two addresses on the same server, or
// the same address on two servers, stay distinct items.
// nonisolated throughout: credentials are read from the nonisolated fetch
// paths (IMAPMailSource, MultiAccountMailSource) under this project's
// MainActor-by-default isolation.
protocol CredentialsStore: Sendable {
    /// Idempotent per accountID: saving the same account again replaces it.
    nonisolated func save(_ credentials: IMAPCredentials) throws
    /// Every stored account, oldest-known order not guaranteed.
    nonisolated func loadAll() throws -> [IMAPCredentials]
    nonisolated func load(accountID: String) throws -> IMAPCredentials?
    nonisolated func delete(accountID: String) throws
}

extension CredentialsStore {
    /// The first account, for the "is anything configured at all?" question.
    nonisolated func load() throws -> IMAPCredentials? { try loadAll().first }

    /// Derived from loadAll() so a store only has to implement one read.
    /// The Keychain store overrides nothing here; it just reads once.
    nonisolated func load(accountID: String) throws -> IMAPCredentials? {
        try loadAll().first { $0.accountID == accountID }
    }
}

extension IMAPCredentials {
    /// Stable identity of an account across launches. Never contains the
    /// password, so it is safe to carry on a MailMessage and in logs.
    /// nonisolated: read from the nonisolated fetch paths, same reason as
    /// IMAPMailSource.log.
    nonisolated var accountID: String { Self.accountID(account: account, server: server) }

    nonisolated static func accountID(account: String, server: String) -> String {
        "\(account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    /// What the account tag on a row shows: the address alone when it is
    /// unambiguous, which it is for one address per server.
    nonisolated var displayName: String { account }
}
