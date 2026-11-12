// Mail/LocalRulesEngine.swift
//
// The on-device rules engine (Stage 4). Runs locally on ALL mail — free, no
// network, no allowlist involved (local analysis is always safe because
// nothing leaves the Mac). Assigns each message a single MailCategory.
//
// Scope at Stage 4: newsletter/bulk detection and OBVIOUS scam detection.
// Importance scoring and nuanced phishing judgment are Stage 5 cloud tasks
// (ARCHITECTURE.md architecture), so this engine emits only .newsletter, .scam,
// or .other — never .important. Rules are documented in THREAT_PATTERNS.md;
// keep the two in sync.
//
// Ordering is deliberate (see classify): scam is checked first BUT is
// defined to exclude mailing-list mail, because legitimate lists routinely
// fail DMARC (the list rewrites the message), and flagging a real list as a
// scam is exactly the cry-wolf failure THREAT_PATTERNS.md warns against.

import Foundation

enum LocalRulesEngine {

    static func classify(_ message: MailMessage) -> MailCategory {
        if isLikelyScam(message) { return .scam }
        if isLikelyNewsletter(message) { return .newsletter }
        return .other
    }

    /// With a VIP list (Matt, 2026-10-07). The ONLY way this engine emits
    /// .important: mail from a sender the user marked VIP.
    ///
    /// Order matters, and scam deliberately comes first: impersonating
    /// someone you trust is the classic attack, so a trusted dmarc=fail
    /// stays .scam no matter whose name is on it — being a VIP can never
    /// talk the app out of a spoof warning.
    ///
    /// VIP does outrank .newsletter: a person you marked VIP forwarding a
    /// newsletter is mail from that person, and it also keeps their mail
    /// out of Unsubscribe Candidates, where acting on a forwarded
    /// List-Unsubscribe header would unsubscribe from the original
    /// sender's list, not theirs.
    static func classify(_ message: MailMessage, vipSenders: Set<String>) -> MailCategory {
        if isLikelyScam(message) { return .scam }
        if isVIP(message, vipSenders: vipSenders) { return .important }
        return classify(message)
    }

    static func isVIP(_ m: MailMessage, vipSenders: Set<String>) -> Bool {
        guard !vipSenders.isEmpty else { return false }
        return vipSenders.contains(AllowedSender.normalize(m.fromAddress))
    }

    // Obvious spoof: the receiving server's TRUSTED verdict says DMARC failed,
    // AND this isn't list mail. DMARC is the alignment check; a trusted
    // dmarc=fail on non-list mail is the highest-precision local spoof signal
    // we have. We require the trusted verdict (nil auth ⇒ not scam) so an
    // absent/forged header can't trigger a flag, and we exclude list mail so
    // legitimate mailing lists (which break DMARC by design) aren't flagged.
    static func isLikelyScam(_ m: MailMessage) -> Bool {
        guard !hasListHeaders(m) else { return false }
        if let auth = m.authentication, auth.dmarc == .fail { return true }
        return false
    }

    // Bulk/marketing mail — an unsubscribe candidate. List-Unsubscribe is the
    // canonical signal; List-Id and Precedence reinforce it; a bulk-shaped
    // from-address local part is a weaker standalone fallback.
    static func isLikelyNewsletter(_ m: MailMessage) -> Bool {
        if hasListHeaders(m) { return true }
        if let p = m.precedence?.lowercased(),
           ["bulk", "list", "junk"].contains(p) { return true }
        if hasBulkLocalPart(m.fromAddress) { return true }
        return false
    }

    // MARK: - Signals

    private static func hasListHeaders(_ m: MailMessage) -> Bool {
        m.listUnsubscribe != nil || m.listId != nil
    }

    private static let bulkLocalParts: Set<String> = [
        "noreply", "no-reply", "donotreply", "do-not-reply",
        "newsletter", "news", "marketing", "notifications",
        "notification", "updates", "mailer", "bounce", "email",
    ]

    private static func hasBulkLocalPart(_ address: String) -> Bool {
        let local = address
            .split(separator: "@", maxSplits: 1)
            .first
            .map { String($0).lowercased() } ?? ""
        return bulkLocalParts.contains(local)
    }
}
