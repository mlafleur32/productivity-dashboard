// Mail/ListUnsubscribeParser.swift
//
// Stage 7, Step A. Turns the raw List-Unsubscribe (RFC 2369) and
// List-Unsubscribe-Post (RFC 8058) header values into the ONLY
// unsubscribe destinations the app will ever consider. Pure, no network,
// no Apple-only frameworks — unit-tested by ListUnsubscribeParserTests.
//
// Everything here is attacker-controllable input (a header is just text
// the sender wrote), so the posture is an allowlist of shapes, not a
// blocklist of known-bad ones. Rules are documented in THREAT_PATTERNS.md
// ("Unsubscribe safety"); keep the two in sync.
//
//   - https URIs: https scheme, default port, no userinfo, a public-looking
//     DNS hostname (no IP literals in any notation, no localhost / .local /
//     .internal / .home.arpa / .lan, no single-label hosts).
//   - mailto URIs: exactly one safe recipient; only `subject` and `body`
//     kept — `to`, `cc`, `bcc` and everything else are dropped so a draft
//     can never quietly copy a third party. Subject/body with control
//     characters or excessive length are dropped (the recipient is what
//     list servers key on).
//   - Anything else (http:, javascript:, data:, file:, ftp:, …) is ignored.
//
// This file decides what is SAFE TO CONSIDER. It does not decide what to
// OFFER — that needs the message's category, cloud verdict and trusted
// dkim/dmarc result, and lives in Stage 7 Step B's eligibility gate.

import Foundation

/// A sanitized mailto: unsubscribe target (Apple Mail draft, Step C).
// nonisolated: pure value type; keeps its Equatable conformance usable
// from test tables (the target defaults to MainActor isolation).
nonisolated struct MailtoUnsubscribe: Equatable, Sendable {
    let recipient: String
    let subject: String?
    let body: String?
}

/// Everything usable that a message's unsubscribe headers offer.
nonisolated struct ListUnsubscribeOptions: Equatable, Sendable {
    /// Safe https URIs, in header order, de-duplicated.
    let httpsURLs: [URL]
    /// Safe mailto targets, in header order, de-duplicated.
    let mailtos: [MailtoUnsubscribe]
    /// List-Unsubscribe-Post declared RFC 8058 one-click. On its own this
    /// proves nothing — Step B also requires an https URI and trusted
    /// dkim=pass before one-click is offered.
    let oneClickDeclared: Bool

    static let none = ListUnsubscribeOptions(httpsURLs: [], mailtos: [], oneClickDeclared: false)
}

enum ListUnsubscribeParser {

    /// Headers with more URIs than this are malformed or abusive; the
    /// excess is ignored.
    static let maxURIs = 8
    static let maxURILength = 2048
    static let maxSubjectLength = 200
    static let maxBodyLength = 1000

    // MARK: - Entry point

    static func parse(listUnsubscribe: String?, listUnsubscribePost: String?) -> ListUnsubscribeOptions {
        guard let header = listUnsubscribe else { return .none }
        var urls: [URL] = []
        var mailtos: [MailtoUnsubscribe] = []
        for raw in bracketedURIs(in: header).prefix(maxURIs) {
            if let url = safeHTTPSURL(raw) {
                if !urls.contains(url) { urls.append(url) }
            } else if let target = mailto(raw) {
                if !mailtos.contains(target) { mailtos.append(target) }
            }
        }
        return ListUnsubscribeOptions(
            httpsURLs: urls,
            mailtos: mailtos,
            oneClickDeclared: isOneClick(listUnsubscribePost))
    }

    /// RFC 8058: the header's content is exactly `List-Unsubscribe=One-Click`.
    /// Surrounding whitespace and letter case are tolerated; nothing else is.
    static func isOneClick(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("List-Unsubscribe=One-Click") == .orderedSame
    }

    /// RFC 2369: URIs are enclosed in angle brackets; text outside brackets
    /// is ignored, and whitespace inside a URI (left over from header
    /// folding) is removed. An unterminated bracket yields nothing.
    static func bracketedURIs(in header: String) -> [String] {
        var result: [String] = []
        var current: String?
        for ch in header {
            switch ch {
            case "<":
                current = ""          // a stray '<' restarts the capture
            case ">":
                if let captured = current, !captured.isEmpty { result.append(captured) }
                current = nil
            default:
                if current != nil, !ch.isWhitespace { current?.append(ch) }
            }
        }
        return result
    }

    // MARK: - https

    static func safeHTTPSURL(_ raw: String) -> URL? {
        guard raw.count <= maxURILength,
              raw.allSatisfy({ $0.isASCII && !$0.isWhitespace }),
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              // encodedHost, not host: Foundation IDNA-decodes `host` to
              // Unicode (xn--bcher-kva → bücher); the wire form is ASCII.
              let host = components.encodedHost, isSafePublicHostname(host),
              let url = components.url
        else { return nil }
        return url
    }

    // MARK: - mailto

    static func mailto(_ raw: String) -> MailtoUnsubscribe? {
        guard raw.count <= maxURILength,
              raw.allSatisfy({ $0.isASCII && !$0.isWhitespace }),
              raw.lowercased().hasPrefix("mailto:"),
              let components = URLComponents(string: raw)
        else { return nil }

        // `path` is percent-decoded. Exactly one recipient, in the path —
        // a recipient supplied only via ?to= is not accepted.
        let recipient = components.path
        guard isSafeAddress(recipient) else { return nil }

        var subject: String?
        var body: String?
        for item in components.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": subject = item.value
            case "body":    body = item.value
            default:        continue   // to / cc / bcc / in-reply-to / … dropped
            }
        }
        if let s = subject, s.count > maxSubjectLength || s.unicodeScalars.contains(where: isControl) {
            subject = nil   // e.g. CRLF smuggling another header into the draft
        }
        if let b = body, b.count > maxBodyLength ||
            b.unicodeScalars.contains(where: { isControl($0) && $0 != "\n" && $0 != "\r" }) {
            body = nil
        }
        return MailtoUnsubscribe(recipient: recipient, subject: subject, body: body)
    }

    static func isSafeAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        guard (1...64).contains(local.count),
              local.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._+-=".contains($0)) }),
              local.first != ".", local.last != "."
        else { return false }
        return isSafePublicHostname(String(parts[1]))
    }

    // MARK: - Hostnames

    /// Private-network / non-public name suffixes. A sender-chosen request
    /// must never be aimed at the user's own machine or LAN.
    static let blockedHostSuffixes = ["localhost", "local", "internal", "home.arpa", "lan"]

    /// A public-looking DNS name: ≥2 LDH labels, alphabetic (or punycode)
    /// TLD. The TLD rule is what rejects every IP-literal notation —
    /// dotted-decimal, integer, hex, octal — and IPv6 fails the label
    /// character check.
    static func isSafePublicHostname(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253 else { return false }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.count),
                  label.allSatisfy(isLDH),
                  label.first != "-", label.last != "-"
            else { return false }
        }

        guard let tld = labels.last else { return false }
        let alphabeticTLD = tld.count >= 2 && tld.allSatisfy { $0.isASCII && $0.isLowercase }
        guard alphabeticTLD || tld.hasPrefix("xn--") else { return false }

        for suffix in blockedHostSuffixes where host == suffix || host.hasSuffix("." + suffix) {
            return false
        }
        return true
    }

    /// Letter-digit-hyphen, lowercase ASCII only (host is lowercased first).
    // nonisolated: passed as a function value to allSatisfy.
    nonisolated private static func isLDH(_ c: Character) -> Bool {
        c.isASCII && (c.isLowercase || c.isNumber || c == "-")
    }

    nonisolated private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}
