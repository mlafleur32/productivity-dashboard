//
//  AuthenticationResultsTests.swift
//  ProductivityDashboardTests
//
//  Verifies RFC 8601 parsing AND the anti-forgery rules: only the receiving
//  server's stamp (matching authserv-id, topmost instance) is trusted. The
//  injection tests are the security-critical ones — a forged
//  Authentication-Results must never be read as a legitimate pass.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct AuthenticationResultsTests {

    private let gmail = "mx.google.com"

    // MARK: - Basic parsing

    @Test("Parses a normal all-pass Gmail header")
    func parsesAllPass() {
        let value = " mx.google.com; spf=pass smtp.mailfrom=example.com; " +
                    "dkim=pass header.i=@example.com; dmarc=pass (p=REJECT) header.from=example.com"
        let result = AuthenticationResults.parse(headerValues: [value], expectedAuthservID: gmail)
        #expect(result?.spf == .pass)
        #expect(result?.dkim == .pass)
        #expect(result?.dmarc == .pass)
    }

    @Test("Parses a dmarc=fail verdict")
    func parsesDmarcFail() {
        let value = "mx.google.com; spf=softfail smtp.mailfrom=spoof.example; " +
                    "dkim=fail; dmarc=fail (p=REJECT) header.from=bank.example"
        let result = AuthenticationResults.parse(headerValues: [value], expectedAuthservID: gmail)
        #expect(result?.dmarc == .fail)
        #expect(result?.spf == .softfail)
        #expect(result?.dkim == .fail)
    }

    @Test("A header with no method clauses parses as all-not-performed")
    func parsesNone() {
        let result = AuthenticationResults.parse(headerValues: ["mx.google.com; none"],
                                                 expectedAuthservID: gmail)
        #expect(result?.dmarc == .notPerformed)
        #expect(result?.spf == .notPerformed)
    }

    // MARK: - Anti-forgery (the security-critical cases)

    @Test("Forged header BELOW the real one loses: topmost matching authserv-id wins")
    func topmostTrustedInstanceWins() {
        // Real receiver stamp (Gmail prepends this) says FAIL.
        let real = "mx.google.com; dmarc=fail (p=REJECT) header.from=bank.example"
        // Attacker embedded this in the message they sent; it sits BELOW.
        let forged = "mx.google.com; dmarc=pass header.from=bank.example"
        let result = AuthenticationResults.parse(headerValues: [real, forged],
                                                 expectedAuthservID: gmail)
        #expect(result?.dmarc == .fail)   // must NOT be fooled into .pass
    }

    @Test("Forged header with a DIFFERENT authserv-id is ignored even if topmost")
    func wrongAuthservIDIgnored() {
        // Attacker uses their own/an upstream authserv-id, placed on top.
        let forgedTop = "attacker.example; dmarc=pass header.from=bank.example"
        // The genuine Gmail stamp is below and says fail.
        let realBelow = "mx.google.com; dmarc=fail (p=REJECT) header.from=bank.example"
        let result = AuthenticationResults.parse(headerValues: [forgedTop, realBelow],
                                                 expectedAuthservID: gmail)
        #expect(result?.dmarc == .fail)   // skipped the wrong-id top, used the real one
    }

    @Test("No header matches the expected authserv-id -> nil (no trusted verdict)")
    func noMatchingAuthservIDYieldsNil() {
        let onlyForged = ["evil.example; dmarc=pass", "relay.other.example; dmarc=pass"]
        let result = AuthenticationResults.parse(headerValues: onlyForged, expectedAuthservID: gmail)
        #expect(result == nil)
    }

    @Test("Empty header list -> nil")
    func emptyYieldsNil() {
        #expect(AuthenticationResults.parse(headerValues: [], expectedAuthservID: gmail) == nil)
    }

    @Test("Unknown provider (no expected authserv-id) -> nil, never a guess")
    func unknownProviderYieldsNil() {
        // Simulates AuthservIDMap returning nil for a non-Gmail server: an
        // empty expected id must yield nil, not match everything.
        let value = "some.server; dmarc=pass"
        #expect(AuthenticationResults.parse(headerValues: [value], expectedAuthservID: "") == nil)
    }

    @Test("authserv-id match is case-insensitive")
    func authservIDCaseInsensitive() {
        let value = "MX.GOOGLE.COM; dmarc=pass header.from=example.com"
        let result = AuthenticationResults.parse(headerValues: [value], expectedAuthservID: gmail)
        #expect(result?.dmarc == .pass)
    }

    @Test("authserv-id with a trailing version number still matches")
    func authservIDWithVersion() {
        let value = "mx.google.com 1; dmarc=pass header.from=example.com"
        let result = AuthenticationResults.parse(headerValues: [value], expectedAuthservID: gmail)
        #expect(result?.dmarc == .pass)
    }

    // MARK: - AuthservIDMap

    @Test("Gmail servers map to mx.google.com; others map to nil")
    func authservIDMapping() {
        #expect(AuthservIDMap.expectedAuthservID(forServer: "imap.gmail.com") == "mx.google.com")
        #expect(AuthservIDMap.expectedAuthservID(forServer: "imap.fastmail.com") == nil)
    }
}

// MARK: - Stage 9: EarthLink / Mindspring (verified from a real header)

@MainActor
struct EarthLinkAuthservIDTests {

    /// The shape of the stamp EarthLink puts on mail delivered to a
    /// Mindspring address, as observed 2026-10-25. The authserv-id and the
    /// field layout are real; the sending IP (a documentation address), the
    /// DKIM selector and the sender domain are synthetic.
    nonisolated static let earthlinkHeader = """
    earthlink-vadesecure.net; iprev=pass policy.iprev=192.0.2.10; \
    spf=pass (sender IP is 192.0.2.10) smtp.mailfrom=bounces.shop.example; \
    dkim=pass header.d=shop.example header.s=sel2026 \
    header.i=@shop.example; dmarc=pass action=quarantine header.from=shop.example; arc=none;
    """

    @Test("Mindspring and EarthLink hosts expect the Vade Secure stamp")
    func earthlinkHostsMapped() {
        #expect(AuthservIDMap.expectedAuthservID(forServer: "imap.mindspring.com")
                == "earthlink-vadesecure.net")
        #expect(AuthservIDMap.expectedAuthservID(forServer: "imap.earthlink.net")
                == "earthlink-vadesecure.net")
        #expect(AuthservIDMap.expectedAuthservID(forServer: "IMAP.EarthLink.NET")
                == "earthlink-vadesecure.net")
    }

    @Test("Gmail is unchanged, and an unknown provider still yields no verdict")
    func otherProvidersUnchanged() {
        #expect(AuthservIDMap.expectedAuthservID(forServer: "imap.gmail.com") == "mx.google.com")
        #expect(AuthservIDMap.expectedAuthservID(forServer: "imap.fastmail.com") == nil)
    }

    @Test("The real EarthLink header parses to pass/pass/pass")
    func realHeaderParses() throws {
        let result = try #require(AuthenticationResults.parse(
            headerValues: [Self.earthlinkHeader],
            expectedAuthservID: "earthlink-vadesecure.net"))
        #expect(result.spf == .pass)
        #expect(result.dkim == .pass)
        #expect(result.dmarc == .pass)
    }

    @Test("RELEASE GATE: a stamp from any other authserv-id is not trusted")
    func foreignStampIgnored() {
        // What a spoofer embeds: a plausible-looking line with the WRONG id.
        let forged = "mx.google.com; spf=pass; dkim=pass; dmarc=pass"
        #expect(AuthenticationResults.parse(
            headerValues: [forged],
            expectedAuthservID: "earthlink-vadesecure.net") == nil)
    }

    @Test("RELEASE GATE: the receiver's stamp wins over one the sender embedded")
    func topmostStampWins() throws {
        let forged = "earthlink-vadesecure.net; spf=pass; dkim=pass; dmarc=pass"
        let real = "earthlink-vadesecure.net; spf=fail; dkim=fail; dmarc=fail"
        // Delivered order: the receiving server PREPENDS, so its line is first.
        let result = try #require(AuthenticationResults.parse(
            headerValues: [real, forged],
            expectedAuthservID: "earthlink-vadesecure.net"))
        #expect(result.dmarc == .fail)
    }
}
