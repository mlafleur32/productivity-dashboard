//
//  ListUnsubscribeParserTests.swift
//  ProductivityDashboardTests
//
//  Stage 7, Step A. Parameterized (table-driven) tests for the
//  List-Unsubscribe / List-Unsubscribe-Post parser. These headers are
//  attacker-controllable, so the URL-safety table is a security table:
//  every rejected row is a request the app must never be able to make.
//  All hosts and addresses are synthetic (example.com / .example).
//

import Testing
import Foundation
@testable import ProductivityDashboard

// @MainActor: the app target defaults to MainActor isolation, so its
// types (and their conformances) are main-actor-isolated; running the
// suite there too removes the cross-isolation warnings (cleanup pass).
@MainActor
struct ListUnsubscribeParserTests {

    // MARK: - https URL safety

    struct URLCase: Sendable, CustomTestStringConvertible {
        let name: String
        let raw: String
        let accepted: Bool
        var testDescription: String { name }
    }

    nonisolated static let urlCases: [URLCase] = [
        // Accepted shapes
        .init(name: "plain https", raw: "https://unsub.example.com/u?t=abc123", accepted: true),
        .init(name: "uppercase scheme and host", raw: "HTTPS://Unsub.Example.COM/u", accepted: true),
        .init(name: "explicit default port", raw: "https://unsub.example.com:443/u", accepted: true),
        .init(name: "trailing-dot FQDN", raw: "https://unsub.example.com./u", accepted: true),
        .init(name: "punycode label", raw: "https://xn--bcher-kva.example.com/u", accepted: true),
        .init(name: "punycode TLD", raw: "https://list.example.xn--p1ai/u", accepted: true),
        // Wrong scheme
        .init(name: "http", raw: "http://unsub.example.com/u", accepted: false),
        .init(name: "javascript", raw: "javascript:alert(1)", accepted: false),
        .init(name: "data", raw: "data:text/html,hello", accepted: false),
        .init(name: "file", raw: "file:///etc/hosts", accepted: false),
        .init(name: "ftp", raw: "ftp://unsub.example.com/u", accepted: false),
        .init(name: "mailto is not https", raw: "mailto:unsub@list.example.com", accepted: false),
        // Userinfo / port
        .init(name: "userinfo", raw: "https://user@unsub.example.com/u", accepted: false),
        .init(name: "user and password", raw: "https://user:pw@unsub.example.com/u", accepted: false),
        .init(name: "non-default port", raw: "https://unsub.example.com:8443/u", accepted: false),
        // IP literals in every notation
        .init(name: "IPv4 loopback", raw: "https://127.0.0.1/u", accepted: false),
        .init(name: "IPv4 private", raw: "https://10.0.0.5/u", accepted: false),
        .init(name: "IPv6 loopback", raw: "https://[::1]/u", accepted: false),
        .init(name: "integer IPv4", raw: "https://2130706433/u", accepted: false),
        .init(name: "hex IPv4", raw: "https://0x7f.0x0.0x0.0x1/u", accepted: false),
        .init(name: "octal IPv4", raw: "https://0177.0.0.01/u", accepted: false),
        // Local / private names
        .init(name: "localhost", raw: "https://localhost/u", accepted: false),
        .init(name: "sub.localhost", raw: "https://api.localhost/u", accepted: false),
        .init(name: ".local", raw: "https://printer.local/u", accepted: false),
        .init(name: ".home.arpa", raw: "https://nas.home.arpa/u", accepted: false),
        .init(name: ".internal", raw: "https://svc.internal/u", accepted: false),
        .init(name: ".lan", raw: "https://router.lan/u", accepted: false),
        .init(name: "single-label host", raw: "https://intranet/u", accepted: false),
        // Malformed
        .init(name: "empty host", raw: "https:///u", accepted: false),
        .init(name: "no authority", raw: "https:unsub.example.com/u", accepted: false),
        .init(name: "leading-hyphen label", raw: "https://-bad.example.com/u", accepted: false),
        .init(name: "empty label", raw: "https://unsub..example.com/u", accepted: false),
        .init(name: "embedded whitespace", raw: "https://unsub.example.com/u u", accepted: false),
        .init(name: "non-ASCII host", raw: "https://ünsub.example.com/u", accepted: false),
    ]

    @Test("https URL safety", arguments: urlCases)
    func httpsURLSafety(_ c: URLCase) {
        #expect((ListUnsubscribeParser.safeHTTPSURL(c.raw) != nil) == c.accepted)
    }

    // MARK: - mailto sanitizing

    struct MailtoCase: Sendable, CustomTestStringConvertible {
        let name: String
        let raw: String
        let expected: MailtoUnsubscribe?
        var testDescription: String { name }
    }

    nonisolated static let mailtoCases: [MailtoCase] = [
        .init(name: "bare recipient",
              raw: "mailto:unsub@list.example.com",
              expected: MailtoUnsubscribe(recipient: "unsub@list.example.com", subject: nil, body: nil)),
        .init(name: "subject",
              raw: "mailto:unsub@list.example.com?subject=unsubscribe",
              expected: MailtoUnsubscribe(recipient: "unsub@list.example.com", subject: "unsubscribe", body: nil)),
        .init(name: "uppercase scheme, percent-encoded subject and body",
              raw: "MAILTO:unsub@list.example.com?subject=Unsubscribe%20me&body=please%20remove",
              expected: MailtoUnsubscribe(recipient: "unsub@list.example.com", subject: "Unsubscribe me", body: "please remove")),
        .init(name: "percent-encoded @ in recipient",
              raw: "mailto:unsub%40list.example.com",
              expected: MailtoUnsubscribe(recipient: "unsub@list.example.com", subject: nil, body: nil)),
        .init(name: "plus-tagged local part",
              raw: "mailto:leave+tok-123@list.example.com",
              expected: MailtoUnsubscribe(recipient: "leave+tok-123@list.example.com", subject: nil, body: nil)),
        .init(name: "cc, bcc and extra to are dropped",
              raw: "mailto:unsub@list.example.com?subject=x&cc=a@other.example.com&bcc=b@other.example.com&to=c@other.example.com",
              expected: MailtoUnsubscribe(recipient: "unsub@list.example.com", subject: "x", body: nil)),
        .init(name: "CRLF in subject drops the subject",
              raw: "mailto:unsub@list.example.com?subject=hi%0D%0ABcc:%20b@other.example.com",
              expected: MailtoUnsubscribe(recipient: "unsub@list.example.com", subject: nil, body: nil)),
        .init(name: "newlines allowed in body",
              raw: "mailto:unsub@list.example.com?body=line1%0Aline2",
              expected: MailtoUnsubscribe(recipient: "unsub@list.example.com", subject: nil, body: "line1\nline2")),
        .init(name: "over-long subject dropped",
              raw: "mailto:unsub@list.example.com?subject=" + String(repeating: "a", count: 201),
              expected: MailtoUnsubscribe(recipient: "unsub@list.example.com", subject: nil, body: nil)),
        // Rejected outright
        .init(name: "two recipients", raw: "mailto:a@list.example.com,b@other.example.com", expected: nil),
        .init(name: "recipient only in ?to=", raw: "mailto:?to=unsub@list.example.com", expected: nil),
        .init(name: "no domain", raw: "mailto:unsub", expected: nil),
        .init(name: "IP-literal domain", raw: "mailto:unsub@127.0.0.1", expected: nil),
        .init(name: "localhost domain", raw: "mailto:unsub@localhost", expected: nil),
        .init(name: ".local domain", raw: "mailto:unsub@mail.local", expected: nil),
        .init(name: "double @", raw: "mailto:a@b@list.example.com", expected: nil),
        .init(name: "empty local part", raw: "mailto:@list.example.com", expected: nil),
        .init(name: "not mailto", raw: "https://unsub.example.com/u", expected: nil),
    ]

    @Test("mailto sanitizing", arguments: mailtoCases)
    func mailtoSanitizing(_ c: MailtoCase) {
        #expect(ListUnsubscribeParser.mailto(c.raw) == c.expected)
    }

    // MARK: - List-Unsubscribe-Post

    struct PostCase: Sendable, CustomTestStringConvertible {
        let value: String?
        let oneClick: Bool
        var testDescription: String { value.map { "\"\($0)\"" } ?? "nil" }
    }

    nonisolated static let postCases: [PostCase] = [
        .init(value: "List-Unsubscribe=One-Click", oneClick: true),
        .init(value: "  List-Unsubscribe=One-Click  ", oneClick: true),
        .init(value: "list-unsubscribe=one-click", oneClick: true),
        .init(value: nil, oneClick: false),
        .init(value: "", oneClick: false),
        .init(value: "One-Click", oneClick: false),
        .init(value: "List-Unsubscribe=One-Click-Maybe", oneClick: false),
        .init(value: "List-Unsubscribe=One-Click; extra", oneClick: false),
    ]

    @Test("List-Unsubscribe-Post one-click detection", arguments: postCases)
    func oneClickDetection(_ c: PostCase) {
        #expect(ListUnsubscribeParser.isOneClick(c.value) == c.oneClick)
    }

    // MARK: - Whole-header parsing

    @Test func typicalHeaderYieldsBothMethods() throws {
        let options = ListUnsubscribeParser.parse(
            listUnsubscribe: "<mailto:unsub@list.example.com?subject=unsubscribe>, <https://unsub.example.com/u?t=abc>",
            listUnsubscribePost: "List-Unsubscribe=One-Click")
        #expect(options.oneClickDeclared)
        #expect(options.httpsURLs.map(\.absoluteString) == ["https://unsub.example.com/u?t=abc"])
        #expect(options.mailtos == [.init(recipient: "unsub@list.example.com", subject: "unsubscribe", body: nil)])
    }

    @Test func nilHeaderIsNone() {
        #expect(ListUnsubscribeParser.parse(listUnsubscribe: nil,
                                            listUnsubscribePost: "List-Unsubscribe=One-Click") == .none)
    }

    @Test func unsafeEntriesAreDroppedSafeOnesKept() {
        let options = ListUnsubscribeParser.parse(
            listUnsubscribe: "<http://unsub.example.com/u>, <javascript:alert(1)>, <https://10.0.0.1/u>, <https://ok.example.com/u>",
            listUnsubscribePost: nil)
        #expect(options.httpsURLs.map(\.absoluteString) == ["https://ok.example.com/u"])
        #expect(options.mailtos.isEmpty)
        #expect(!options.oneClickDeclared)
    }

    @Test func textOutsideBracketsIsIgnored() {
        let options = ListUnsubscribeParser.parse(
            listUnsubscribe: "https://unsub.example.com/u, unsub@list.example.com",
            listUnsubscribePost: nil)
        #expect(options == ListUnsubscribeOptions(httpsURLs: [], mailtos: [], oneClickDeclared: false))
    }

    @Test func unterminatedBracketYieldsNothing() {
        let options = ListUnsubscribeParser.parse(
            listUnsubscribe: "<https://unsub.example.com/u",
            listUnsubscribePost: nil)
        #expect(options.httpsURLs.isEmpty)
    }

    @Test func duplicatesCollapse() {
        let options = ListUnsubscribeParser.parse(
            listUnsubscribe: "<https://unsub.example.com/u>, <https://unsub.example.com/u>, <mailto:a@list.example.com>, <mailto:a@list.example.com>",
            listUnsubscribePost: nil)
        #expect(options.httpsURLs.count == 1)
        #expect(options.mailtos.count == 1)
    }

    @Test func excessURIsAreIgnored() {
        let many = (1...12).map { "<https://u\($0).example.com/u>" }.joined(separator: ", ")
        let options = ListUnsubscribeParser.parse(listUnsubscribe: many, listUnsubscribePost: nil)
        #expect(options.httpsURLs.count == ListUnsubscribeParser.maxURIs)
    }

    /// End to end with the real header parser: a folded List-Unsubscribe
    /// line (CRLF + whitespace inside the URI) still yields the clean URI.
    @Test func foldedHeaderThroughMailHeaderParser() {
        let raw = "List-Unsubscribe: <mailto:unsub@list.example.com>,\r\n <https://unsub.example.com/very/\r\n long/path?t=abc>\r\n" +
                  "List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n"
        let headers = MailHeaderParser.parse(raw)
        let options = ListUnsubscribeParser.parse(
            listUnsubscribe: headers.first("list-unsubscribe"),
            listUnsubscribePost: headers.first("list-unsubscribe-post"))
        #expect(options.oneClickDeclared)
        #expect(options.httpsURLs.map(\.absoluteString) == ["https://unsub.example.com/very/long/path?t=abc"])
        #expect(options.mailtos.map(\.recipient) == ["unsub@list.example.com"])
    }
}
