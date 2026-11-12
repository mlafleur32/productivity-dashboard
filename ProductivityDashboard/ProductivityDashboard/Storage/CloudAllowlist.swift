// Storage/CloudAllowlist.swift
//
// THE ALLOWLIST GATE — the spine of the privacy design (ARCHITECTURE.md Security &
// Privacy item 1). Every message destined for the Stage 5 Claude API path
// passes through filter() exactly once. A message survives only if its
// normalized sender is on the cloud-eligible allowlist; everything else is
// dropped and stays local-only. This is the fail-safe default: unknown ⇒ out.
//
// Type-safe enforcement, not just a runtime check: CloudEligibleMessage has a
// fileprivate init, so the ONLY code in the entire app that can construct one
// is filter(), below. Stage 5's API client will accept only
// [CloudEligibleMessage] — making "a non-allowlisted message reaches the
// network" a COMPILE error, not something a future code path can forget to
// guard. The fail-safe default is the belt; the private init is the suspenders.
//
// This file must stay small and obvious. Anything that constructs a
// CloudEligibleMessage lives here and nowhere else — that is the whole point.

import Foundation

/// A message that has been proven cloud-eligible by passing through the
/// allowlist gate. Cannot be constructed any other way (fileprivate init).
struct CloudEligibleMessage: Identifiable, Sendable {
    let message: MailMessage
    var id: String { message.id }

    fileprivate init(_ message: MailMessage) {
        self.message = message
    }
}

/// Read side of the allowlist. Abstracted so the gate can be unit-tested with
/// a fake, without a live SwiftData store. Returns the set of NORMALIZED
/// (see AllowedSender.normalize) sender identifiers that are cloud-eligible.
protocol AllowlistReading: Sendable {
    func cloudEligibleSenders() -> Set<String>
}

enum CloudAllowlist {
    /// The gate. Keeps only messages whose sender is explicitly cloud-eligible.
    ///
    /// Fail-safe by construction: `eligible` is a finite allowlist, and a
    /// message is kept only on a positive membership hit. An empty allowlist,
    /// an unrecognized sender, or a reader that failed to load (returns [])
    /// all yield zero eligible messages — the privacy-safe outcome.
    static func filter(
        _ messages: [MailMessage],
        using reader: AllowlistReading
    ) -> [CloudEligibleMessage] {
        let eligible = reader.cloudEligibleSenders()
        return messages.compactMap { message in
            let key = AllowedSender.normalize(message.fromAddress)
            guard eligible.contains(key) else { return nil }
            return CloudEligibleMessage(message)
        }
    }
}
