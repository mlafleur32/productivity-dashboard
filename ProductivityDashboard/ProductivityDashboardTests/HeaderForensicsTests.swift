//
//  HeaderForensicsTests.swift
//  ProductivityDashboardTests
//
//  Sender-identity checks (Matt, 2026-10-25). These run on every message,
//  on this Mac, and feed both the row and — as findings only, never raw
//  headers — the cloud summary. The tests that matter most are the ones
//  pinning what must NOT be flagged: legitimate bulk mail trips single
//  checks constantly, and a dashboard that cries wolf is worse than one
//  that says nothing. Synthetic headers plus one real-shaped example.
//

import Testing
import Foundation
@testable import ProductivityDashboard

@MainActor
struct HeaderForensicsTests {

    private func forensics(from raw: String, fromAddress: String, fromName: String? = nil,
                           trustedAuth: Bool = true) -> HeaderForensics {
        HeaderForensics.evaluate(fromAddress: fromAddress,
                                 fromName: fromName,
                                 headers: MailHeaderParser.parse(raw),
                                 trustedAuthPresent: trustedAuth)
    }

    // MARK: - What must NOT be flagged

    @Test("Amazon's real shape: subdomain bounce and a second signer are fine")
    func legitimateBulkMailIsQuiet() {
        // The shape of large-retailer bulk mail; token and selectors synthetic.
        let f = forensics(from: """
        Return-Path: <0000000001-SYNTHETICTOKEN@bounces.amazon.com>
        Dkim-Signature: v=1; a=rsa-sha256; d=amazon.com; s=sel1; h=Date:From
        Dkim-Signature: v=1; a=rsa-sha256; d=amazonses.com; s=sel2; h=Date:From
        """, fromAddress: "store-news@amazon.com", fromName: "Amazon.com")
        #expect(!f.returnPathMismatch)      // bounces.amazon.com is amazon.com
        #expect(!f.dkimMisaligned)          // one signature aligns; that's enough
        #expect(!f.displayNameImpersonates) // "Amazon.com" matches amazon.com
        #expect(f.dkimPresent)
        #expect(!f.isNotable)
    }

    @Test("A plain personal message with no extra headers is quiet")
    func plainMailIsQuiet() {
        let f = forensics(from: "Subject: lunch", fromAddress: "robin@example.com")
        #expect(!f.anyFinding || !f.isNotable)
        #expect(!f.returnPathMismatch)
        #expect(!f.replyToMismatch)
    }

    @Test("A brand word in the display name is not impersonation")
    func brandWordIsNotImpersonation() {
        #expect(!HeaderForensics.nameContradictsAddress("Amazon.com", fromAddress: "x@amazon.com"))
        #expect(!HeaderForensics.nameContradictsAddress("Lakeshore Bird Society",
                                                        fromAddress: "news@lakeshorebirds.example"))
        #expect(!HeaderForensics.nameContradictsAddress("Alex Morgan",
                                                        fromAddress: "alex@mail.example"))
    }

    @Test("One mismatch alone is never notable")
    func singleMismatchIsNotNotable() {
        let f = forensics(from: "Reply-To: replies@mailer.example", fromAddress: "news@shop.example")
        #expect(f.replyToMismatch)
        #expect(!f.isNotable)
    }

    // MARK: - What must be flagged

    @Test("A display name naming another domain is impersonation")
    func displayNameImpersonation() {
        let f = forensics(from: "Subject: Verify", fromAddress: "x@evil.example",
                          fromName: "support@apple.com")
        #expect(f.displayNameImpersonates)
        #expect(f.isNotable)   // this one has no honest explanation
    }

    @Test("A bare domain in the display name counts too")
    func bareDomainImpersonation() {
        #expect(HeaderForensics.nameContradictsAddress("PayPal Security (paypal.com)",
                                                       fromAddress: "billing@secure-pay.ru"))
    }

    @Test("Replies and bounces both pointing elsewhere is notable")
    func twoMismatchesAreNotable() {
        let f = forensics(from: """
        Return-Path: <bounce@mailer.ru>
        Reply-To: billing@collections.ru
        """, fromAddress: "invoices@yourbank.example")
        #expect(f.returnPathMismatch)
        #expect(f.replyToMismatch)
        #expect(f.isNotable)
    }

    @Test("DKIM signed only by a foreign domain is a misalignment")
    func dkimMisalignment() {
        let f = forensics(from: "Dkim-Signature: v=1; d=sendgrid.ru; s=k1",
                          fromAddress: "security@yourbank.example")
        #expect(f.dkimPresent)
        #expect(f.dkimMisaligned)
    }

    @Test("An auth stamp we can't attribute is reported, never read")
    func untrustedStampReported() {
        let f = forensics(from: "Authentication-Results: someone-else.example; dmarc=pass",
                          fromAddress: "x@example.com", trustedAuth: false)
        #expect(f.untrustedAuthStampPresent)
    }

    // MARK: - Domain comparison

    @Test("Organizational domain comparison")
    func organizationComparison() {
        #expect(HeaderForensics.sameOrganization("bounces.amazon.com", "amazon.com"))
        #expect(HeaderForensics.sameOrganization("amazon.com", "mail.amazon.com"))
        #expect(HeaderForensics.sameOrganization("AMAZON.COM", "amazon.com"))
        #expect(!HeaderForensics.sameOrganization("amazon.com", "amaz0n.com"))
        #expect(!HeaderForensics.sameOrganization("amazon.com.evil.ru", "amazon.com"))
    }

    @Test("d= is pulled out of a DKIM-Signature")
    func dkimDomainExtraction() {
        #expect(HeaderForensics.dkimDomain(in: "v=1; a=rsa-sha256; d=amazon.com; s=sel") == "amazon.com")
        #expect(HeaderForensics.dkimDomain(in: "v=1; a=rsa-sha256; s=sel") == nil)
    }

    // MARK: - The privacy line

    @Test("RELEASE GATE: findings are the app's own words, carrying no header text")
    func findingsCarryNoHeaderContent() {
        let f = forensics(from: """
        Return-Path: <0000000001-SYNTHETICTOKEN@bounces.evil.ru>
        Reply-To: billing@collections.ru
        Authentication-Results: someone-else.example; dmarc=pass
        """, fromAddress: "invoices@yourbank.example", trustedAuth: false)
        let text = f.findings.joined(separator: " ")
        // Nothing identifying from the headers themselves may appear.
        #expect(!text.contains("SYNTHETICTOKEN"))
        #expect(!text.contains("collections.ru"))
        #expect(!text.contains("someone-else.example"))
        #expect(!text.contains("@"))
    }
}
