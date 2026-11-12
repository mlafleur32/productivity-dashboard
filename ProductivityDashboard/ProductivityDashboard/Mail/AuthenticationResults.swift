// Mail/AuthenticationResults.swift
//
// Parses RFC 8601 Authentication-Results headers into SPF/DKIM/DMARC
// verdicts — with the critical anti-forgery rule that only the instance
// stamped by the ACTUAL receiving mail server is trusted.
//
// Threat: any upstream hop, including the sending attacker, can put an
// `Authentication-Results:` header into a message. A phisher trivially
// embeds `Authentication-Results: mx.google.com; dmarc=pass` in the mail
// they send. If we naively read "the first dmarc= we find", we read the
// forgery. Two defenses, both required:
//
//   1. authserv-id match. We trust a header ONLY if its authserv-id equals
//      the expected id of the server we actually fetched from (Gmail =
//      mx.google.com). Headers stamped by other hops (or by an attacker
//      using a different id) are ignored outright.
//
//   2. Topmost wins. Receiving servers PREPEND their Authentication-Results,
//      so the real receiver's stamp sits ABOVE any the sender embedded. We
//      take the FIRST header (in delivered top-to-bottom order) whose
//      authserv-id matches. A forged `mx.google.com` line the sender put in
//      their own message necessarily appears BELOW Gmail's real one, so it
//      loses. (If a provider we can't identify is used, expectedAuthservID
//      is unknown, we match nothing, and return nil — no trusted verdict,
//      rather than a guessed one.)
//
// See THREAT_PATTERNS.md → "Sender Spoofing Red Flags".

import Foundation

enum AuthVerdict: String, Sendable, Hashable {
    case pass
    case fail
    case softfail
    case neutral
    // RFC result "none" (no authentication performed). Named .notPerformed,
    // not .none, to avoid Swift's Optional.none collision — comparing an
    // AuthVerdict? against a bare `.none` would silently mean "== nil".
    case notPerformed = "none"
    case temperror
    case permerror
    case policy
    case unknown

    static func parse(_ raw: String) -> AuthVerdict {
        AuthVerdict(rawValue: raw.lowercased()) ?? .unknown
    }
}

struct AuthenticationResults: Sendable, Hashable {
    let spf: AuthVerdict
    let dkim: AuthVerdict
    let dmarc: AuthVerdict

    /// Parse the trusted Authentication-Results verdict, or nil if no header
    /// stamped by the expected receiving server is present.
    ///
    /// - Parameters:
    ///   - headerValues: values of every `Authentication-Results` header, in
    ///     delivered order (topmost first). Pass the value only — i.e. the
    ///     text AFTER "Authentication-Results:".
    ///   - expectedAuthservID: the receiving server's authserv-id, e.g.
    ///     "mx.google.com". Compared case-insensitively.
    static func parse(
        headerValues: [String],
        expectedAuthservID: String
    ) -> AuthenticationResults? {
        let expected = expectedAuthservID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !expected.isEmpty else { return nil }

        for value in headerValues {
            let unfolded = value
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")

            guard let authservID = Self.authservID(of: unfolded) else { continue }
            guard authservID == expected else { continue }

            // First matching (topmost) instance is the receiving server's.
            // Any later same-id header is a sender-embedded forgery — ignore.
            return Self.parseVerdicts(from: unfolded)
        }
        return nil
    }

    // The authserv-id is the token immediately after the colon (which the
    // caller has already stripped), up to the first ";" or whitespace. An
    // optional version number may follow it before the first ";", which we
    // don't need. Lowercased for comparison.
    private static func authservID(of value: String) -> String? {
        let beforeSemicolon = value.split(separator: ";", maxSplits: 1,
                                          omittingEmptySubsequences: false)[0]
        let firstToken = beforeSemicolon
            .split(whereSeparator: { $0 == " " })
            .first
        guard let token = firstToken, !token.isEmpty else { return nil }
        return token.lowercased()
    }

    private static func parseVerdicts(from value: String) -> AuthenticationResults {
        var spf: AuthVerdict = .notPerformed
        var dkim: AuthVerdict = .notPerformed
        var dmarc: AuthVerdict = .notPerformed

        // Drop the authserv-id (+ optional version): everything after the
        // first ";" is the list of "method=result ..." clauses.
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count > 1 else {
            return AuthenticationResults(spf: spf, dkim: dkim, dmarc: dmarc)
        }

        for clause in parts.dropFirst() {
            let trimmed = clause.trimmingCharacters(in: .whitespaces)
            // A clause is "method=result key=value key=value". We only need
            // the leading "method=result".
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let method = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let afterEq = trimmed[trimmed.index(after: eq)...]
            // result is the token up to whitespace or "(" (a comment).
            let result = afterEq.prefix { $0 != " " && $0 != "(" && $0 != "\t" }
            let verdict = AuthVerdict.parse(String(result))

            switch method {
            case "spf":   spf = verdict
            case "dkim":  dkim = verdict
            case "dmarc": dmarc = verdict
            default:      break   // auth, arc, etc. — not used by our rules
            }
        }

        return AuthenticationResults(spf: spf, dkim: dkim, dmarc: dmarc)
    }
}

// Maps an IMAP server host to the authserv-id its receiving MX stamps into
// Authentication-Results. Provider-specific knowledge: only Gmail is known
// today. An unknown provider returns nil → we cannot trust any A-R header
// for it (parse() returns nil), which is the fail-safe: no verdict rather
// than a guessed one. Add providers here as they're supported.
// Which authserv-id each provider's receiving server stamps. Entries are
// added ONLY from a real header observed on that provider — never guessed
// from the IMAP hostname, because the two often differ: EarthLink's own
// servers hand filtering to Vade Secure and stamp
// "earthlink-vadesecure.net", which no rule derived from
// "imap.mindspring.com" would ever produce.
//
// Unknown provider ⇒ nil ⇒ no trusted verdict at all (fail-safe): the
// local scam rule never fires on that account's mail, rather than trusting
// a stamp we cannot attribute.
enum AuthservIDMap {
    nonisolated static func expectedAuthservID(forServer server: String) -> String? {
        let host = server.lowercased()
        if host.contains("gmail.com") || host.contains("google") {
            return "mx.google.com"
        }
        // EarthLink, and the Mindspring brand it absorbed, both deliver
        // through Vade Secure. Verified 2026-10-25 against a real header on
        // a Mindspring account (imap.mindspring.com):
        //   Authentication-Results: earthlink-vadesecure.net; ... dmarc=pass ...
        if host.contains("earthlink.net") || host.contains("mindspring.com") {
            return "earthlink-vadesecure.net"
        }
        return nil
    }
}
