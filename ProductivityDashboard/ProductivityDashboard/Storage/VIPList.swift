// Storage/VIPList.swift
//
// Read and write sides of the VIP list. Same shape as the allowlist's
// reader/editor pair: a protocol so the rules engine can be tested with a
// fake, a NoOp default so the app is well-defined before the real store
// attaches, and one editor that owns the explicit save after every
// mutation (ARCHITECTURE.md storage rule).
//
// Fail-safe direction is the opposite of the allowlist's, because the risk
// is the opposite: a failed read here returns an EMPTY set, which means
// "nobody is a VIP" — mail falls back to the ordinary rules instead of
// being wrongly promoted.

import Foundation
import SwiftData

protocol VIPReading: Sendable {
    /// NORMALIZED sender identifiers (AllowedSender.normalize).
    func vipSenders() -> Set<String>
}

struct EmptyVIPReader: VIPReading {
    func vipSenders() -> Set<String> { [] }
}

struct SwiftDataVIPReader: VIPReading, @unchecked Sendable {
    let context: ModelContext

    func vipSenders() -> Set<String> {
        let descriptor = FetchDescriptor<VIPSender>()
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return Set(rows.map(\.senderIdentifier))
    }
}

enum VIPListError: Error, Equatable {
    case notAnAddress

    var userMessage: String {
        switch self {
        case .notAnAddress: return "That doesn't look like an email address."
        }
    }
}

struct VIPEditor {
    let context: ModelContext

    /// Idempotent: adding an existing VIP updates the label instead of
    /// tripping the unique constraint.
    func add(address: String, displayName: String? = nil) throws {
        let key = AllowedSender.normalize(address)
        guard Self.looksLikeAnAddress(key) else { throw VIPListError.notAnAddress }
        let label = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try existing(key) {
            if let label, !label.isEmpty { existing.displayName = label }
        } else {
            context.insert(VIPSender(senderIdentifier: key,
                                     displayName: (label?.isEmpty ?? true) ? nil : label))
        }
        try context.save()
    }

    func remove(_ sender: VIPSender) throws {
        context.delete(sender)
        try context.save()
    }

    func remove(address: String) throws {
        if let existing = try existing(AllowedSender.normalize(address)) {
            context.delete(existing)
            try context.save()
        }
    }

    func isVIP(address: String) -> Bool {
        ((try? existing(AllowedSender.normalize(address))) ?? nil) != nil
    }

    private func existing(_ key: String) throws -> VIPSender? {
        var descriptor = FetchDescriptor<VIPSender>(
            predicate: #Predicate { $0.senderIdentifier == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Deliberately loose: one @, something either side, no whitespace. The
    /// point is to catch a slip ("dad" or "dad@"), not to re-implement
    /// RFC 5322 and reject someone's real address.
    static func looksLikeAnAddress(_ key: String) -> Bool {
        let parts = key.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return false }
        guard let domain = parts.last, !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return !key.contains(where: \.isWhitespace)
    }
}
