// Storage/AllowedSender.swift
//
// The cloud allowlist, one row per promoted sender. This is the persisted
// backing of the allowlist GATE (Stage 4, Step B) — the spine of the
// privacy design. A sender reaches the Stage 5 Claude API path only if a
// row exists here AND cloudEligible == true. Absence means local-only,
// which is the fail-safe default for everything the user has not
// deliberately promoted.
//
// Identity is the normalized email address ONLY — never a domain. A
// domain-level entry (@gmail.com) would silently allowlist every stranger
// at that provider, which inverts the fail-safe posture. Normalization
// (lowercase + trim) lives in normalize(_:) and MUST be applied on both
// write (here) and read (the gate), or "Alice@Firm.com" and
// "alice@firm.com" would be treated as different senders.
//
// Minimal by design (ARCHITECTURE.md): identifier + eligibility + timestamp.
// No display name, no message content.

import Foundation
import SwiftData

@Model
final class AllowedSender {
    @Attribute(.unique) var senderIdentifier: String
    var cloudEligible: Bool
    var addedAt: Date

    init(senderIdentifier: String, cloudEligible: Bool = true, addedAt: Date = .now) {
        self.senderIdentifier = Self.normalize(senderIdentifier)
        self.cloudEligible = cloudEligible
        self.addedAt = addedAt
    }

    // Single source of truth for how a raw address becomes an allowlist
    // key. Used by both this initializer and the gate's lookup so the two
    // can never disagree.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
