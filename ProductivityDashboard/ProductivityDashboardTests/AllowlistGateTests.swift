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

    /// A trusted stamp that vouches for the From line, so the tests about
    /// the allowlist itself aren't also tests about identity.
    private static let passing = AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass)

    private func message(
        from address: String,
        authentication: AuthenticationResults? = AllowlistGateTests.passing,
        listId: String? = nil
    ) -> MailMessage {
        MailMessage(
            id: UUID().uuidString,
            fromName: nil,
            fromAddress: address,
            subject: "irrelevant",
            date: .now,
            listId: listId,
            authentication: authentication
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

    // MARK: - The From line has to be theirs (2026-11-23, outside review)
    //
    // The From line is written by whoever sends the mail. These tests prove
    // that naming an allowlisted address isn't enough: the receiving
    // server's trusted stamp has to say the message came from that domain.

    @Test("RELEASE GATE: a forged allowlisted From with a List-Id and dmarc=fail is not eligible")
    func forgedListMailBlocked() {
        // The exact attack from the review: the List-Id makes the local scam
        // rule stand aside, so the gate itself has to catch it.
        let reader = FakeReader(eligible: ["known@firm.example"])
        let forged = message(
            from: "known@firm.example",
            authentication: AuthenticationResults(spf: .fail, dkim: .fail, dmarc: .fail,
                                                  dmarcHeaderFrom: "firm.example"),
            listId: "<announce.lists.evil.example>")
        #expect(CloudAllowlist.filter([forged], using: reader).isEmpty)
    }

    @Test("RELEASE GATE: no trusted stamp means not eligible, even for an allowlisted address")
    func noTrustedStampBlocked() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let bare = message(from: "known@firm.example", authentication: nil)
        #expect(CloudAllowlist.filter([bare], using: reader).isEmpty)
    }

    @Test("dmarc=none with no DKIM pass is not eligible")
    func dmarcNoneWithoutDKIMBlocked() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let m = message(from: "known@firm.example",
                        authentication: AuthenticationResults(spf: .pass, dkim: .notPerformed,
                                                              dmarc: .notPerformed))
        #expect(CloudAllowlist.filter([m], using: reader).isEmpty)
    }

    @Test("dmarc=none with a DKIM pass by the From domain is eligible")
    func dmarcNoneWithAlignedDKIMPasses() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let m = message(from: "known@firm.example",
                        authentication: AuthenticationResults(spf: .pass, dkim: .pass,
                                                              dmarc: .notPerformed,
                                                              dkimPassDomains: ["mail.firm.example"]))
        #expect(CloudAllowlist.filter([m], using: reader).count == 1)
    }

    @Test("A DKIM pass by some other domain doesn't vouch for the From line")
    func unalignedDKIMBlocked() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let m = message(from: "known@firm.example",
                        authentication: AuthenticationResults(spf: .pass, dkim: .pass,
                                                              dmarc: .notPerformed,
                                                              dkimPassDomains: ["bulkmailer.example"]))
        #expect(CloudAllowlist.filter([m], using: reader).isEmpty)
    }

    @Test("A dmarc=pass about another domain doesn't vouch for this From line")
    func dmarcPassForOtherDomainBlocked() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let m = message(from: "known@firm.example",
                        authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass,
                                                              dmarcHeaderFrom: "evil.example"))
        #expect(CloudAllowlist.filter([m], using: reader).isEmpty)
    }

    @Test("A dmarc=pass naming the From domain is eligible")
    func dmarcPassForThisDomainPasses() {
        let reader = FakeReader(eligible: ["known@firm.example"])
        let m = message(from: "Known@Firm.Example",
                        authentication: AuthenticationResults(spf: .pass, dkim: .pass, dmarc: .pass,
                                                              dmarcHeaderFrom: "firm.example"))
        #expect(CloudAllowlist.filter([m], using: reader).count == 1)
    }

    @Test("Alignment is by whole domain labels, not by the last two labels")
    func alignmentIsStrict() {
        #expect(SenderIdentity.aligned("firm.example", "firm.example"))
        #expect(SenderIdentity.aligned("mail.firm.example", "firm.example"))
        #expect(SenderIdentity.aligned("firm.example", "news.firm.example"))
        // A sibling under a public suffix is someone else entirely.
        #expect(!SenderIdentity.aligned("evil.co.uk", "bank.co.uk"))
        // A suffix that isn't on a label boundary.
        #expect(!SenderIdentity.aligned("notfirm.example", "firm.example"))
        // A bare public suffix can't sign for everything under it.
        #expect(!SenderIdentity.aligned("example", "firm.example"))
    }
}
