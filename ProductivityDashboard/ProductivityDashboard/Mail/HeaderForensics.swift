// Mail/HeaderForensics.swift
//
// Deterministic sender-identity checks over a message's own headers
// (Matt, 2026-10-25). Every one of these is a comparison, not a judgment,
// so it runs ON THIS MAC for EVERY message — including the senders the
// cloud path never sees, which is most of the mailbox.
//
// What leaves the Mac: nothing from here except, for an allowlisted
// sender, the FINDINGS — a handful of booleans the app computed itself.
// Raw headers are never sent: they carry routing IPs, the user's own
// address, and provider-internal fields, and they are attacker-controlled
// text that would widen the injection surface of the prompt for no gain
// (the model cannot compare domains better than == can).
//
// Deliberately NOT a verdict. Legitimate bulk mail routinely trips the
// Return-Path and Reply-To checks (Amazon bounces at bounces.amazon.com),
// so these findings inform the row and the cloud summary; they do not by
// themselves categorize anything as a scam. Cry-wolf is the failure mode
// THREAT_PATTERNS.md warns about, and the local .scam rule stays exactly
// where it was: a TRUSTED dmarc=fail on non-list mail.

import Foundation

nonisolated struct HeaderForensics: Hashable, Sendable {
    /// Return-Path (the bounce address) is on a different organizational
    /// domain than From. Normal for bulk senders, notable for a bank.
    var returnPathMismatch = false
    /// Reply-To points at a different organizational domain than From —
    /// the "reply goes to the attacker" shape.
    var replyToMismatch = false
    /// A DKIM signature exists but none of them is on From's domain.
    /// Unsigned mail (no d= at all) is reported as `dkimPresent == false`
    /// rather than as a misalignment.
    var dkimMisaligned = false
    var dkimPresent = false
    /// The DISPLAY NAME contains an email address or domain that
    /// contradicts the real From address: `"support@apple.com" <x@evil.ru>`.
    /// The oldest trick in the book, and invisible in most mail clients.
    var displayNameImpersonates = false
    /// An Authentication-Results header exists, but none from the server we
    /// fetched from — so it proves nothing. (Someone else's stamp, or a
    /// forged one.) Informational: an untrusted stamp is never read.
    var untrustedAuthStampPresent = false

    var anyFinding: Bool {
        returnPathMismatch || replyToMismatch || dkimMisaligned
            || displayNameImpersonates || untrustedAuthStampPresent
    }

    /// Worth showing on a row unprompted. One mismatch alone is common in
    /// legitimate bulk mail, so the bar is the impersonation check (which
    /// has no honest explanation) or two independent mismatches.
    var isNotable: Bool {
        displayNameImpersonates
            || [returnPathMismatch, replyToMismatch, dkimMisaligned].filter { $0 }.count >= 2
    }

    /// Short, human phrases — what the row shows and what the cloud summary
    /// carries. The app's own words, never the sender's text.
    var findings: [String] {
        var out: [String] = []
        if displayNameImpersonates { out.append("display name contradicts the real address") }
        if returnPathMismatch { out.append("bounce address on another domain") }
        if replyToMismatch { out.append("replies go to another domain") }
        if dkimMisaligned { out.append("DKIM signature not from the sender's domain") }
        if !dkimPresent { out.append("no DKIM signature") }
        if untrustedAuthStampPresent { out.append("authentication header from an unrecognized server") }
        return out
    }

    // MARK: - Computing it

    /// - Parameters:
    ///   - fromAddress / fromName: as parsed from the envelope.
    ///   - headers: the message's header block, already parsed.
    ///   - trustedAuthPresent: whether a stamp from the EXPECTED receiving
    ///     server was found (AuthservIDMap + AuthenticationResults.parse).
    static func evaluate(fromAddress: String,
                         fromName: String?,
                         headers: ParsedHeaders,
                         trustedAuthPresent: Bool) -> HeaderForensics {
        var result = HeaderForensics()
        let fromDomain = domain(ofAddress: fromAddress)

        if let returnPath = headers.first("return-path"),
           let rpDomain = domain(ofAddress: stripAngleBrackets(returnPath)),
           let fromDomain {
            result.returnPathMismatch = !sameOrganization(rpDomain, fromDomain)
        }

        if let replyTo = headers.first("reply-to"),
           let rtDomain = domain(ofAddress: stripAngleBrackets(replyTo)),
           let fromDomain {
            result.replyToMismatch = !sameOrganization(rtDomain, fromDomain)
        }

        // Every DKIM-Signature on the message; aligned if ANY signs From's
        // organizational domain (mail legitimately carries several — the
        // Amazon example is signed by both amazon.com and amazonses.com).
        let dkimDomains = headers.all("dkim-signature").compactMap(dkimDomain(in:))
        result.dkimPresent = !dkimDomains.isEmpty
        if let fromDomain, !dkimDomains.isEmpty {
            result.dkimMisaligned = !dkimDomains.contains { sameOrganization($0, fromDomain) }
        }

        if let fromName {
            result.displayNameImpersonates = nameContradictsAddress(fromName, fromAddress: fromAddress)
        }

        result.untrustedAuthStampPresent =
            !trustedAuthPresent && !headers.all("authentication-results").isEmpty

        return result
    }

    // MARK: - Pieces

    static func stripAngleBrackets(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    static func domain(ofAddress raw: String) -> String? {
        let trimmed = stripAngleBrackets(raw).lowercased()
        // A display-name form may sneak in ("Pat <pat@x.example>").
        let candidate: String
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            candidate = String(trimmed[trimmed.index(after: open)..<close])
        } else {
            candidate = trimmed
        }
        guard let at = candidate.lastIndex(of: "@") else { return nil }
        let host = String(candidate[candidate.index(after: at)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " >;,"))
        return host.isEmpty ? nil : host
    }

    /// Same organization if one is a subdomain of the other, or they share
    /// their last two labels. Deliberately loose: the goal is to avoid
    /// crying wolf over bounces.amazon.com vs amazon.com, not to implement
    /// the public suffix list. A two-label comparison treats
    /// "foo.co.uk" and "bar.co.uk" as related, which errs toward silence —
    /// the safe direction for a signal that is advisory, not a verdict.
    static func sameOrganization(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y || x.hasSuffix("." + y) || y.hasSuffix("." + x) { return true }
        return lastTwoLabels(x) == lastTwoLabels(y)
    }

    private static func lastTwoLabels(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    /// `d=` from a DKIM-Signature header value.
    static func dkimDomain(in signature: String) -> String? {
        for field in signature.split(separator: ";") {
            let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("d=") {
                return String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        return nil
    }

    /// A display name that names an address or domain other than the real
    /// sender's. Matches "billing@paypal.com", "paypal.com", and
    /// "PayPal Security (paypal.com)" — but not a bare brand word, which
    /// would flag every newsletter on earth.
    static func nameContradictsAddress(_ name: String, fromAddress: String) -> Bool {
        guard let fromDomain = domain(ofAddress: fromAddress) else { return false }
        let lower = name.lowercased()

        // An address inside the display name.
        if let embedded = domain(ofAddress: lower), embedded.contains(".") {
            return !sameOrganization(embedded, fromDomain)
        }
        // A bare domain-looking token inside the display name.
        for token in lower.split(whereSeparator: { " \t()<>[]\",:;".contains($0) }) {
            let candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            guard candidate.contains("."), !candidate.hasSuffix(".") else { continue }
            let labels = candidate.split(separator: ".")
            guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
                  let tld = labels.last, tld.count >= 2,
                  tld.allSatisfy({ $0.isLetter }) else { continue }
            if !sameOrganization(candidate, fromDomain) { return true }
        }
        return false
    }
}
