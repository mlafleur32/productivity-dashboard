//
//  UnsubscribeLogTests.swift
//  ProductivityDashboardTests
//
//  Stage 7, Step D. SwiftDataUnsubscribeLog records the privacy-minimal
//  fields — and structurally CANNOT record a destination: the model has no
//  URL/address field and the recording API takes only an outcome. One
//  shared in-memory container, serialized (same pattern as ArchiveLogTests).
//

import Testing
import Foundation
import SwiftData
@testable import ProductivityDashboard

@MainActor
@Suite(.serialized)
struct UnsubscribeLogTests {

    static let container: ModelContainer = {
        try! ModelContainer(
            for: UnsubscribeLogEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private var log: SwiftDataUnsubscribeLog {
        SwiftDataUnsubscribeLog(context: Self.container.mainContext)
    }

    private func entries(forMessageID id: String) -> [UnsubscribeLogEntry] {
        let descriptor = FetchDescriptor<UnsubscribeLogEntry>(
            predicate: #Predicate { $0.messageID == id })
        return (try? Self.container.mainContext.fetch(descriptor)) ?? []
    }

    @Test("One-click success records method, outcome, status and a normalized sender")
    func oneClickRoundTrip() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(messageID: "u-1", senderAddress: "  News@List.Example.com ",
                   outcome: .oneClickAccepted(status: 204), at: stamp)

        let entry = try #require(entries(forMessageID: "u-1").first)
        #expect(entry.senderAddress == "news@list.example.com")
        #expect(entry.method == UnsubscribeLogMethod.oneClick.rawValue)
        #expect(entry.outcome == UnsubscribeLogOutcome.accepted.rawValue)
        #expect(entry.httpStatus == 204)
        #expect(entry.timestamp == stamp)
    }

    @Test("mailto handoff records draftOpened with no status")
    func mailtoRoundTrip() throws {
        log.record(messageID: "u-2", senderAddress: "news@list.example.com",
                   outcome: .draftHandedOff, at: .now)

        let entry = try #require(entries(forMessageID: "u-2").first)
        #expect(entry.method == UnsubscribeLogMethod.mailto.rawValue)
        #expect(entry.outcome == UnsubscribeLogOutcome.draftOpened.rawValue)
        #expect(entry.httpStatus == nil)
    }

    @Test("Open in Gmail records the choice as a Gmail hand-off")
    func gmailHandoffRoundTrip() throws {
        log.recordGmailHandoff(messageID: "u-4", senderAddress: "News@List.Example.com", at: .now)

        let entry = try #require(entries(forMessageID: "u-4").first)
        #expect(entry.senderAddress == "news@list.example.com")
        #expect(entry.method == UnsubscribeLogMethod.gmail.rawValue)
        #expect(entry.outcome == UnsubscribeLogOutcome.handedToGmail.rawValue)
        #expect(entry.httpStatus == nil)
        #expect(Self.container.mainContext.hasChanges == false)
    }

    @Test("Every mutation is explicitly saved")
    func explicitlySaved() {
        log.record(messageID: "u-3", senderAddress: "news@list.example.com",
                   outcome: .draftHandedOff, at: .now)
        #expect(Self.container.mainContext.hasChanges == false)
    }

    @Test("The persisted entry has no field that could hold a URL, address, subject or body")
    func noDestinationOrContentFields() {
        let entry = UnsubscribeLogEntry(messageID: "m", senderAddress: "s@list.example.com",
                                        method: "oneClick", outcome: "accepted",
                                        httpStatus: 200, timestamp: .now)
        let stored = Set(Mirror(reflecting: entry).children.compactMap(\.label)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "_")) })
        let forbidden = ["url", "destination", "host", "recipient", "mailto", "subject", "body", "link"]
        for name in stored {
            for word in forbidden {
                #expect(!name.lowercased().contains(word), "field \(name) looks like it could hold \(word)")
            }
        }
    }
}
