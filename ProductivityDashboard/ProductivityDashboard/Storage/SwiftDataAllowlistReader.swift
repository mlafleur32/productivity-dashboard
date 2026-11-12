// Storage/SwiftDataAllowlistReader.swift
//
// Production AllowlistReading backed by the SwiftData store. Reads the
// cloud-eligible AllowedSender rows and returns their (already-normalized)
// identifiers.
//
// Fail-safe on error: if the fetch throws for any reason, we return an EMPTY
// set — which the gate treats as "nothing eligible," i.e. everything stays
// local-only. A storage failure must never open the network path.

import Foundation
import SwiftData

/// Fail-safe default reader for code paths where no store is attached yet
/// (previews, or before ContentView wires the ModelContext in): nothing is
/// eligible, so the gate blocks everything — the privacy-safe empty state.
struct EmptyAllowlistReader: AllowlistReading {
    func cloudEligibleSenders() -> Set<String> { [] }
}

struct SwiftDataAllowlistReader: AllowlistReading {
    let context: ModelContext

    func cloudEligibleSenders() -> Set<String> {
        let descriptor = FetchDescriptor<AllowedSender>(
            predicate: #Predicate { $0.cloudEligible }
        )
        guard let rows = try? context.fetch(descriptor) else {
            return []
        }
        // senderIdentifier is normalized at write time (AllowedSender.init),
        // so the gate's normalized lookup matches without re-normalizing here.
        return Set(rows.map(\.senderIdentifier))
    }
}
