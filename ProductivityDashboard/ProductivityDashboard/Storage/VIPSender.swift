// Storage/VIPSender.swift
//
// The VIP list (Matt, 2026-10-07): senders whose mail is ALWAYS surfaced in
// Important Email, decided on this Mac with no API call. Mirrors Apple
// Mail's VIPs in spirit; the dashboard is sandboxed and cannot read Mail's
// own list, so this is the app's own, kept in Settings.
//
// This list is NOT a privacy boundary — unlike AllowedSender, being a VIP
// grants nothing and sends nothing anywhere. It only decides which section
// of the dashboard a message appears in. That is why a typed address is
// allowed here (the allowlist deliberately forbids one): a typo costs a
// missing highlight, never an unintended cloud send.
//
// Identity is the normalized email address ONLY, sharing
// AllowedSender.normalize so the two lists can't disagree about what
// "the same sender" means. Minimal by design: address, optional display
// name the user typed, timestamp. No message content.

import Foundation
import SwiftData

@Model
final class VIPSender {
    @Attribute(.unique) var senderIdentifier: String
    /// What the user typed as a label, if anything. Never taken from mail.
    var displayName: String?
    var addedAt: Date

    init(senderIdentifier: String, displayName: String? = nil, addedAt: Date = .now) {
        self.senderIdentifier = AllowedSender.normalize(senderIdentifier)
        self.displayName = displayName
        self.addedAt = addedAt
    }
}
