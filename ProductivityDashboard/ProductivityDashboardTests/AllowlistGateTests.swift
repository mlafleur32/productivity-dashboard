//
//  AllowlistGateTests.swift
//  ProductivityDashboardTests
//
//  THE release-gate test (ARCHITECTURE.md Testing + Security & Privacy item 1):
//  prove that an unrecognized / non-allowlisted sender NEVER becomes a
//  CloudEligibleMessage, so it can never reach the Stage 5 network path.
//  Fail-safe behavior is verified here, not assumed. If any test in this
//  file fails, the privacy boundary is broken — treat it as a release
//  blocker, not a normal test failure.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct AllowlistGateTests {

    /// In-memory AllowlistReading — no SwiftData store. Holds exactly the
    /// normalized identifiers a test declares eligible.
    struct FakeReader: AllowlistReading {
        let eligible: Set<String>
        func cloudEligibleSenders() -> Set<String> { eligible }
    }

    private func message(from address: String) -> MailMessage {
        MailMessage(
            id: UUID().uuidString,
            fromName: nil,
            fromAddress: address,
            subject: "irrelevant",
            date: .now
        )
    }

    // MARK: - The fail-safe invariant

    @Test("Empty allowlist blocks EVERYTHING — the core fail-safe")
    func emptyAllowlistYieldsZeroEligible() {
        let reader = FakeReader(eligible: [])
        let result = CloudAllowlist.filter(
            [message(from: "alice@firm.example"), message(from: "bob@other.example")],
            using: reader
        )
        #expect(result.isEmpty)
    }

    @Test("An unrecognized sender is never eligible")
    func unrecognizedSenderBlocked() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let result = CloudAllowlist.filter(
            [message(from: "stranger@evil.example")],
            using: reader
        )
        #expect(result.isEmpty)
    }

    @Test("In a mixed batch, only the promoted sender passes; the rest are dropped")
    func onlyPromotedSenderPasses() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let result = CloudAllowlist.filter(
            [
                message(from: "known@firm.example"),
                message(from: "stranger@evil.example"),
                message(from: "another@nope.example"),
            ],
            using: reader
        )
        #expect(result.count == 1)
        #expect(result.first?.message.fromAddress == "known@firm.example")
    }

    // MARK: - Normalization can't be used to smuggle a sender past the gate

    @Test("Matching is case- and whitespace-insensitive via normalize()")
    func normalizationMatchesRegardlessOfCasing() {
        // Allowlist stores the normalized key; the incoming message uses odd
        // casing and surrounding whitespace. They must still match.
        let reader = FakeReader(eligible: [AllowedSender.normalize("Known@Firm.Example")])
        let result = CloudAllowlist.filter(
            [message(from: "  known@firm.EXAMPLE ")],
            using: reader
        )
        #expect(result.count == 1)
    }

    @Test("A near-miss address (not exactly the allowlisted one) is blocked")
    func nearMissAddressBlocked() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let result = CloudAllowlist.filter(
            [
                message(from: "known@firm.example.evil.example"), // suffix attack
                message(from: "known@firm.exampl"),               // typo
                message(from: "notknown@firm.example"),           // different local part
            ],
            using: reader
        )
        #expect(result.isEmpty)
    }
}
