//
//  MIMETextExtractorTests.swift
//  ProductivityDashboardTests
//
//  Synthetic MIME fixtures only (git hygiene rule). Covers the shapes Gmail
//  actually delivers — multipart/alternative, nested multipart/mixed,
//  quoted-printable, base64 — plus HTML-only fallback stripping, the
//  deliberate nils (attachments), and charset fallbacks. Tuning the
//  extractor means adding a fixture here first.
//

import Testing
import Foundation
@testable import ProductivityDashboard

struct MIMETextExtractorTests {

    private func extract(ct: String?, cte: String? = nil, body: String) -> String? {
        MIMETextExtractor.plainText(
            contentType: ct,
            transferEncoding: cte,
            body: Data(body.utf8))
    }

    // MARK: - Single-part

    @Test("Bare text/plain passes through")
    func plainPassthrough() {
        #expect(extract(ct: "text/plain; charset=UTF-8", body: "Hello there.\nSecond line.")
                == "Hello there.\nSecond line.")
    }

    @Test("Missing Content-Type defaults to text/plain (RFC 2045)")
    func missingContentTypeDefaults() {
        #expect(extract(ct: nil, body: "No headers at all.") == "No headers at all.")
    }

    @Test("CRLF bodies normalize to LF")
    func crlfNormalized() {
        #expect(extract(ct: "text/plain", body: "line one\r\nline two") == "line one\nline two")
    }

    @Test("text/html alone falls back to stripped text (widened 2026-07-05)")
    func htmlOnlyStripped() {
        #expect(extract(ct: "text/html; charset=UTF-8", body: "<p>Hello</p>") == "Hello")
    }

    @Test("Non-text single part (application/pdf) yields nil")
    func attachmentOnlyIsNil() {
        #expect(extract(ct: "application/pdf", cte: "base64", body: "JVBERi0=") == nil)
    }

    // MARK: - Transfer encodings

    @Test("Quoted-printable: hex escapes and soft line breaks")
    func quotedPrintable() {
        // "café" with é as =C3=A9 (UTF-8), plus a soft break splitting a word.
        let body = "See you at the caf=C3=A9 tomo=\r\nrrow."
        #expect(extract(ct: "text/plain; charset=utf-8", cte: "quoted-printable", body: body)
                == "See you at the café tomorrow.")
    }

    @Test("Quoted-printable: LF-only soft break and lowercase hex")
    func quotedPrintableLFSoftBreak() {
        #expect(extract(ct: "text/plain", cte: "quoted-printable", body: "a=e2=80=99b c=\nd")
                == "a\u{2019}b cd")
    }

    @Test("Malformed QP escape keeps the literal bytes instead of dropping data")
    func quotedPrintableMalformed() {
        #expect(extract(ct: "text/plain", cte: "quoted-printable", body: "100=ZZ done")
                == "100=ZZ done")
    }

    @Test("Base64 with line wrapping decodes")
    func base64Wrapped() {
        // "Meeting moved to Friday." split across lines as delivered.
        let body = "TWVldGluZyBtb3ZlZCB0\r\nbyBGcmlkYXku"
        #expect(extract(ct: "text/plain; charset=UTF-8", cte: "base64", body: body)
                == "Meeting moved to Friday.")
    }

    // MARK: - Charsets

    @Test("ISO-8859-1 bytes decode via declared charset")
    func latin1Charset() {
        let data = Data([UInt8](("caf".utf8)) + [0xE9])   // 0xE9 = é in Latin-1
        #expect(MIMETextExtractor.plainText(
            contentType: "text/plain; charset=iso-8859-1",
            transferEncoding: nil, body: data) == "café")
    }

    @Test("Windows-1252 curly apostrophe (0x92) decodes via declared charset")
    func windows1252Charset() {
        let data = Data([UInt8]("don".utf8) + [0x92] + [UInt8]("t".utf8))
        #expect(MIMETextExtractor.plainText(
            contentType: "text/plain; charset=windows-1252",
            transferEncoding: nil, body: data) == "don\u{2019}t")
    }

    @Test("Declared UTF-8 with invalid bytes falls back to Latin-1, never nil")
    func utf8FallsBackToLatin1() {
        let data = Data([UInt8]("half ".utf8) + [0xE9])   // bare 0xE9 is invalid UTF-8
        #expect(MIMETextExtractor.plainText(
            contentType: "text/plain; charset=utf-8",
            transferEncoding: nil, body: data) == "half é")
    }

    @Test("Unknown charset tries UTF-8 first")
    func unknownCharset() {
        #expect(extract(ct: "text/plain; charset=x-mystery", body: "plain enough") == "plain enough")
    }

    // MARK: - Multipart

    @Test("multipart/alternative picks the text/plain part over text/html")
    func multipartAlternative() {
        let body = """
        --BOUND1\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        The plain version.\r
        --BOUND1\r
        Content-Type: text/html; charset=UTF-8\r
        \r
        <p>The HTML version.</p>\r
        --BOUND1--\r
        """
        #expect(extract(ct: "multipart/alternative; boundary=BOUND1", body: body)
                == "The plain version.")
    }

    @Test("Quoted boundary parameter parses")
    func quotedBoundary() {
        let body = """
        --=_abc123\r
        Content-Type: text/plain\r
        \r
        Inside quoted boundary.\r
        --=_abc123--\r
        """
        #expect(extract(ct: "multipart/alternative; boundary=\"=_abc123\"", body: body)
                == "Inside quoted boundary.")
    }

    @Test("Nested multipart/mixed(alternative(plain,html), attachment) finds the plain part")
    func nestedMultipart() {
        let body = """
        --OUTER\r
        Content-Type: multipart/alternative; boundary=INNER\r
        \r
        --INNER\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Nested caf=C3=A9 text.\r
        --INNER\r
        Content-Type: text/html\r
        \r
        <p>html</p>\r
        --INNER--\r
        --OUTER\r
        Content-Type: application/pdf; name="doc.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0=\r
        --OUTER--\r
        """
        #expect(extract(ct: "multipart/mixed; boundary=OUTER", body: body)
                == "Nested café text.")
    }

    @Test("multipart with only HTML falls back to stripped text")
    func multipartHTMLOnly() {
        let body = """
        --B\r
        Content-Type: text/html\r
        \r
        <p>only html</p>\r
        --B--\r
        """
        #expect(extract(ct: "multipart/alternative; boundary=B", body: body) == "only html")
    }

    @Test("Missing closing delimiter is tolerated (truncated fetch)")
    func missingTerminator() {
        let body = """
        --B\r
        Content-Type: text/plain\r
        \r
        Survived truncation.
        """
        #expect(extract(ct: "multipart/alternative; boundary=B", body: body)
                == "Survived truncation.")
    }

    @Test("multipart without a boundary parameter yields nil, not a crash")
    func multipartNoBoundary() {
        #expect(extract(ct: "multipart/alternative", body: "--x\r\nwhatever") == nil)
    }

    @Test("Base64 text part inside multipart decodes")
    func base64InsideMultipart() {
        let body = """
        --B\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: base64\r
        \r
        SGVsbG8gZnJvbSBiYXNlNjQu\r
        --B--\r
        """
        #expect(extract(ct: "multipart/mixed; boundary=B", body: body)
                == "Hello from base64.")
    }

    // MARK: - HTML fallback (widened 2026-07-05)

    @Test("HTML stripping: structure tags become line breaks, style/script/comments vanish")
    func htmlStructureStripped() {
        let body = """
        <head><title>ignored</title></head>
        <style>p { color: red }</style>
        <script>alert("never seen")</script>
        <!-- hidden comment -->
        <p>Your order has <b>shipped</b>.</p>
        <p>Arriving <i>Friday</i>.</p>
        """
        // Paragraphs stay separated by one blank line.
        #expect(extract(ct: "text/html; charset=UTF-8", body: body)
                == "Your order has shipped.\n\nArriving Friday.")
    }

    @Test("HTML table cells stay word-separated, not fused")
    func htmlTableCells() {
        let body = "<table><tr><td>Due</td><td>Friday</td></tr></table>"
        #expect(extract(ct: "text/html", body: body) == "Due Friday")
    }

    @Test("HTML entities decode single-pass", arguments: [
        ("Tom &amp; Jerry", "Tom & Jerry"),
        ("don&#8217;t", "don\u{2019}t"),
        ("don&#x2019;t", "don\u{2019}t"),
        ("5&nbsp;PM", "5 PM"),
        ("&amp;lt;not a tag&amp;gt;", "&lt;not a tag&gt;"),   // no double-decode
        ("A &undefined; entity", "A &undefined; entity"),     // unknown kept literal
    ])
    func htmlEntities(_ input: String, _ expected: String) {
        #expect(extract(ct: "text/html", body: "<p>\(input)</p>") == expected)
    }

    @Test("HTML part earlier in the tree never shadows a plain part later in it")
    func htmlNeverShadowsPlain() {
        let body = """
        --B\r
        Content-Type: text/html\r
        \r
        <p>the html one</p>\r
        --B\r
        Content-Type: text/plain\r
        \r
        the plain one\r
        --B--\r
        """
        #expect(extract(ct: "multipart/mixed; boundary=B", body: body) == "the plain one")
    }

    @Test("Quoted-printable HTML part decodes, then strips")
    func htmlQuotedPrintable() {
        let body = """
        --B\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <p>caf=C3=A9 open=\r
        ing</p>\r
        --B--\r
        """
        #expect(extract(ct: "multipart/alternative; boundary=B", body: body) == "café opening")
    }

    @Test("HTML that strips to nothing yields nil, not empty string")
    func htmlEmptyAfterStrip() {
        #expect(extract(ct: "text/html", body: "<style>body { margin: 0 }</style>") == nil)
    }

    // MARK: - Degenerate inputs

    @Test("Empty body yields nil")
    func emptyBody() {
        #expect(MIMETextExtractor.plainText(contentType: "text/plain", transferEncoding: nil, body: Data()) == nil)
    }
}
