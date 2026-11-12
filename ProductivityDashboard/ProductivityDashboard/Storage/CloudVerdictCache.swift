// Storage/CloudVerdictCache.swift
//
// Read/write access to the persisted cloud-verdict cache — the money gate
// of Stage 5. Same architecture as ClassificationCache: a @MainActor
// protocol, a NoOp fallback, and a SwiftData implementation with insert-only
// semantics and explicit saves.
//
// Insert-only matters MORE here than for local classification: local rules
// are deterministic and free, but every cloud re-analysis costs a real API
// call. An existing row — verdict or skipped — is never overwritten.

import Foundation
import SwiftData

/// What one completed cloud analysis concluded. `skipped` is a terminal
/// outcome ("this message can never yield a verdict — stop trying"), not
/// a transient failure.
enum CloudOutcome: Equatable, Sendable {
    case verdict(CloudVerdict)
    case skipped
}

@MainActor
protocol CloudVerdictCaching {
    func outcome(forMessageID id: String) -> CloudOutcome?
    /// Persist the first outcome for a message. Insert-only.
    func store(_ outcome: CloudOutcome, forMessageID id: String)
}

/// Fallback when no store is attached (previews, or before ContentView wires
/// the ModelContext in). Always misses and never persists — with the real
/// analyzer that would mean re-paying per poll, so ContentView MUST attach
/// the SwiftData cache before analysis can run in production.
@MainActor
struct NoOpCloudVerdictCache: CloudVerdictCaching {
    func outcome(forMessageID id: String) -> CloudOutcome? { nil }
    func store(_ outcome: CloudOutcome, forMessageID id: String) {}
}

@MainActor
struct SwiftDataCloudVerdictCache: CloudVerdictCaching {
    let context: ModelContext

    func outcome(forMessageID id: String) -> CloudOutcome? {
        var descriptor = FetchDescriptor<CloudVerdictEntry>(
            predicate: #Predicate { $0.messageID == id }
        )
        descriptor.fetchLimit = 1
        guard let entry = (try? context.fetch(descriptor))?.first else { return nil }
        return Self.decode(entry)
    }

    func store(_ outcome: CloudOutcome, forMessageID id: String) {
        guard self.outcome(forMessageID: id) == nil else { return }
        let entry: CloudVerdictEntry
        switch outcome {
        case .skipped:
            entry = CloudVerdictEntry(messageID: id, outcomeRaw: "skipped")
        case .verdict(let verdict):
            entry = CloudVerdictEntry(
                messageID: id,
                outcomeRaw: "verdict",
                importanceRaw: verdict.importance.rawValue,
                scamRaw: verdict.scam.rawValue,
                tasksJSON: (try? JSONEncoder().encode(verdict.tasks))
                    .flatMap { String(data: $0, encoding: .utf8) }
            )
        }
        context.insert(entry)
        // Explicit save, never auto-save (ARCHITECTURE.md storage rules).
        try? context.save()
    }

    /// A row that exists but can't be reconstructed (corrupt enum raw, bad
    /// JSON) decodes as .skipped: the fail-safe direction is "don't re-spend",
    /// and the message keeps its local classification either way.
    private static func decode(_ entry: CloudVerdictEntry) -> CloudOutcome {
        guard entry.outcomeRaw == "verdict",
              let importance = entry.importanceRaw.flatMap(CloudVerdict.Importance.init(rawValue:)),
              let scam = entry.scamRaw.flatMap(CloudVerdict.ScamJudgment.init(rawValue:)) else {
            return .skipped
        }
        let tasks = entry.tasksJSON
            .flatMap { try? JSONDecoder().decode([CloudVerdict.ExtractedTask].self, from: Data($0.utf8)) }
            ?? []
        return .verdict(CloudVerdict(importance: importance, scam: scam, tasks: tasks))
    }
}
