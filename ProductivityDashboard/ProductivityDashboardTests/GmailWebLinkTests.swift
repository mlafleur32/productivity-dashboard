//
//  GmailWebLinkTests.swift
//  ProductivityDashboardTests
//
//  "Open in Gmail" (settled 2026-09-16). The link is built only from the
//  message's own Message-ID and the user's Gmail account, always points at
//  https://mail.google.com, and the opener refuses anything else. Synthetic
//  IDs and addresses only.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct GmailWebLinkTests {

    @Test("Builds a Gmail search link for the Message-ID, brackets stripped")
    func buildsLink() throws {
        let url = try #require(GmailWebLink.url(forMessageID: "<abc.123@mail.list.example.com>",
                                                account: "user@gmail.example"))
        #expect(url.absoluteString ==
            "https://mail.google.com/mail/?authuser=user%40gmail.example#search/rfc822msgid%3Aabc.123%40mail.list.example.com")
        #expect(GmailLinkOpener.isAllowed(url))
    }

    @Test("Special characters in the Message-ID can't inject into the URL")
    func encodesStrictly() throws {
        let url = try #require(GmailWebLink.url(forMessageID: "<a+b/c=d&e#f%g?h@list.example.com>",
                                                account: "user@gmail.example"))
        let fragment = try #require(url.fragment(percentEncoded: true))
        #expect(fragment == "search/rfc822msgid%3Aa%2Bb%2Fc%3Dd%26e%23f%25g%3Fh%40list.example.com")
        #expect(url.host() == "mail.google.com")
        #expect(url.query(percentEncoded: true) == "authuser=user%40gmail.example")
    }

    @Test("No usable Message-ID → no link",
          arguments: ["uid-42", "", "<>", "no-at-sign", "has space@list.example.com",
                      "<nested<id>@list.example.com>", "ünicode@list.example.com"])
    func rejectsUnusableIDs(_ id: String) {
        #expect(GmailWebLink.url(forMessageID: id, account: "user@gmail.example") == nil)
    }

    @Test("Only Gmail IMAP servers count as Gmail",
          arguments: [("imap.gmail.com", true), (" IMAP.Gmail.com ", true), ("imap.googlemail.com", true),
                      ("imap.mail.example.com", false), ("gmail.com.evil.example", false)])
    func gmailServerDetection(_ c: (String, Bool)) {
        #expect(GmailWebLink.isGmailServer(c.0) == c.1)
    }

    @Test("Opener allows only https://mail.google.com",
          arguments: [("https://mail.google.com/mail/#search/x", true),
                      ("http://mail.google.com/mail/", false),
                      ("https://mail.google.com.evil.example/", false),
                      ("https://evil.example/mail.google.com", false),
                      ("https://user@mail.google.com/", false),
                      ("https://mail.google.com:8443/", false),
                      ("https://unsub.example.com/u", false)])
    func openerAllowlist(_ c: (String, Bool)) {
        #expect(GmailLinkOpener.isAllowed(URL(string: c.0)!) == c.1)
    }
}
