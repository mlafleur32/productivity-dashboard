// Mail/MIMETextExtractor.swift
//
// Turns a raw IMAP BODY[TEXT] payload into the message's plain text
// (Stage 5, Step D). Input: the top-level Content-Type and
// Content-Transfer-Encoding header values plus the raw body bytes; output:
// the decoded text/plain content, or nil when there is none.
//
// Scope is deliberately narrow (settled in the Stage 5 design):
//   - text/plain preferred; when a message has no text/plain part anywhere,
//     a text/html part is accepted and reduced to plain text by a small
//     tag stripper below (added 2026-07-05 — the original text/plain-only
//     scope said "widen here if HTML-only mail proves too lossy"; it did).
//     Deliberately NOT NSAttributedString's HTML importer: that route is
//     main-thread-bound WebKit machinery that can fetch remote resources,
//     which this app must never do implicitly.
//   - Encodings: 7bit/8bit/binary (as-is), quoted-printable, base64.
//   - Charsets: UTF-8 (+ US-ASCII), ISO-8859-1, Windows-1252; anything
//     else tries UTF-8 and falls back to Latin-1 (byte-preserving) rather
//     than failing — mis-rendered accents beat a lost message.
//   - multipart/* recurses (multipart/alternative inside multipart/mixed
//     is Gmail's standard shape) with a depth cap against hostile nesting.
//
// Pure Foundation; no NIO types — unit-tested with synthetic MIME fixtures
// in MIMETextExtractorTests, no network anywhere near this code.

import Foundation

enum MIMETextExtractor {

    private static let maxDepth = 5

    /// The decoded plain-text content of a message body, or nil if none.
    /// text/plain wins when present; otherwise a text/html part is
    /// stripped to text. Two passes, not one, so an HTML part earlier in
    /// the MIME tree can never shadow a plain part later in it.
    static func plainText(
        contentType: String?,
        transferEncoding: String?,
        body: Data
    ) -> String? {
        if let plain = extract(contentType: contentType, transferEncoding: transferEncoding,
                               body: body, depth: 0, accepting: "text/plain") {
            return plain
        }
        guard let html = extract(contentType: contentType, transferEncoding: transferEncoding,
                                 body: body, depth: 0, accepting: "text/html") else {
            return nil
        }
        let stripped = htmlToPlainText(html)
        return stripped.isEmpty ? nil : stripped
    }

    private static func extract(
        contentType: String?,
        transferEncoding: String?,
        body: Data,
        depth: Int,
        accepting acceptedType: String
    ) -> String? {
        guard depth <= maxDepth, !body.isEmpty else { return nil }

        let (mediaType, parameters) = parseContentType(contentType)

        if mediaType.hasPrefix("multipart/") {
            guard let boundary = parameters["boundary"], !boundary.isEmpty else { return nil }
            return extractFromMultipart(body: body, boundary: boundary, depth: depth,
                                        accepting: acceptedType)
        }

        guard mediaType == acceptedType else { return nil }

        let decodedBytes: Data
        switch transferEncoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            // Latin-1 is a total 1:1 byte↔character mapping, so this round
            // trip preserves the base64 alphabet exactly; ignoreUnknown
            // absorbs the line wrapping.
            guard let text = String(data: body, encoding: .isoLatin1),
                  let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
            else { return nil }
            decodedBytes = decoded
        case "quoted-printable":
            decodedBytes = decodeQuotedPrintable(body)
        default: // 7bit, 8bit, binary, absent
            decodedBytes = body
        }

        return decodeCharset(decodedBytes, charset: parameters["charset"])
            .map { $0.replacingOccurrences(of: "\r\n", with: "\n")
                     .trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Multipart

    private static func extractFromMultipart(
        body: Data, boundary: String, depth: Int, accepting acceptedType: String
    ) -> String? {
        // Latin-1 decode preserves every byte 1:1, so splitting on boundary
        // lines is safe even if some part payload is 8-bit; each part's
        // bytes are recovered exactly on the way back down.
        guard let text = String(data: body, encoding: .isoLatin1) else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        let delimiter = "--" + boundary
        var parts: [String] = []
        var current: [String]?

        for line in normalized.components(separatedBy: "\n") {
            // .whitespacesAndNewlines (not .whitespaces): a body that ends
            // without a final CRLF leaves a lone \r on the closing delimiter
            // after normalization, and an unrecognized delimiter would leak
            // boundary garbage into the extracted text.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == delimiter + "--" {          // closing delimiter
                if let c = current { parts.append(c.joined(separator: "\n")) }
                current = nil
                break
            } else if trimmed == delimiter {          // part separator
                if let c = current { parts.append(c.joined(separator: "\n")) }
                current = []
            } else {
                current?.append(line)
            }
        }
        // Tolerate a missing closing delimiter (truncated fetch).
        if let c = current { parts.append(c.joined(separator: "\n")) }

        // First part that yields the accepted type wins — in
        // multipart/alternative the plain variant conventionally comes
        // first anyway, and parts that aren't the accepted type (or don't
        // contain one) return nil.
        for part in parts {
            let (headerBlock, partBody) = splitPart(part)
            let headers = MailHeaderParser.parse(headerBlock)
            if let found = extract(
                contentType: headers.first("content-type"),
                transferEncoding: headers.first("content-transfer-encoding"),
                body: Data(partBody.unicodeScalars.map { UInt8($0.value & 0xFF) }),
                depth: depth + 1,
                accepting: acceptedType
            ) {
                return found
            }
        }
        return nil
    }

    /// Split one MIME part into (header block, body) at the first blank line.
    private static func splitPart(_ part: String) -> (headers: String, body: String) {
        // Parts arrive CRLF-normalized to "\n" by the caller. A part with no
        // blank line is all headers and no body.
        if let range = part.range(of: "\n\n") {
            return (String(part[..<range.lowerBound]),
                    String(part[range.upperBound...]))
        }
        return (part, "")
    }

    // MARK: - Content-Type parsing

    /// "text/plain; charset=\"UTF-8\"" → ("text/plain", ["charset": "UTF-8"]).
    /// nil / empty defaults to text/plain per RFC 2045 §5.2.
    private static func parseContentType(_ value: String?) -> (mediaType: String, parameters: [String: String]) {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ("text/plain", [:])
        }
        let segments = value.components(separatedBy: ";")
        let mediaType = segments[0].trimmingCharacters(in: .whitespaces).lowercased()

        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            parameters[key] = val
        }
        return (mediaType, parameters)
    }

    // MARK: - HTML → text

    /// Reduce an HTML body to readable plain text: drop invisible
    /// containers, turn line-structure tags into newlines, strip the rest,
    /// decode entities, collapse whitespace. Good enough for
    /// classification; not a renderer.
    ///
    /// Known acceptance: CSS-hidden text (display:none spans etc.) is NOT
    /// removed, so the classifier can see text a human wouldn't — a
    /// prompt-injection channel unique to HTML mail. Bounded by the
    /// posture in THREAT_PATTERNS.md "Prompt Injection": worst case is a
    /// skewed verdict, never an action.
    private static func htmlToPlainText(_ html: String) -> String {
        var s = html
        // Containers whose content is never message text.
        for pattern in ["<!--.*?-->",
                        "<script\\b[^>]*>.*?</script>",
                        "<style\\b[^>]*>.*?</style>",
                        "<head\\b[^>]*>.*?</head>"] {
            s = regexReplace(s, pattern: pattern, with: " ")
        }
        // Line structure becomes newlines BEFORE tags are stripped, so
        // paragraphs/rows don't fuse into one run-on line.
        s = regexReplace(s, pattern: "<br\\b[^>]*>", with: "\n")
        s = regexReplace(s, pattern: "</(p|div|li|tr|h[1-6]|blockquote|table|ul|ol)>", with: "\n")
        // Inline formatting tags vanish — "has <b>shipped</b>." must give
        // "has shipped.", not "has shipped ." (space before the period).
        s = regexReplace(
            s,
            pattern: "</?(a|b|i|u|em|strong|span|code|small|big|sup|sub|font|abbr|time|mark)\\b[^>]*>",
            with: "")
        // Everything else renders as a word separator, not as nothing —
        // "<td>Due</td><td>Friday</td>" must not become "DueFriday".
        s = regexReplace(s, pattern: "<[^>]+>", with: " ")
        s = decodeHTMLEntities(s)

        // Collapse: runs of horizontal space to one, trim each line, and
        // runs of blank lines to a single blank line.
        s = regexReplace(s, pattern: "[ \\t\\r]+", with: " ")
        var lines: [String] = []
        var lastWasBlank = true
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !lastWasBlank { lines.append("") }
                lastWasBlank = true
            } else {
                lines.append(line)
                lastWasBlank = false
            }
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexReplace(_ s: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return s }
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Single-pass entity decode: the common named entities plus numeric
    /// (`&#8217;` / `&#x2019;`) forms. Single-pass on purpose — "&amp;lt;"
    /// decodes to the literal text "&lt;", never to "<".
    private static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&",
               let semi = s[i...].firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 10,
               let decoded = decodeEntity(String(s[s.index(after: i)..<semi])) {
                out.append(decoded)
                i = s.index(after: semi)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func decodeEntity(_ name: String) -> Character? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "mdash": return "\u{2014}"
        case "ndash": return "\u{2013}"
        case "rsquo": return "\u{2019}"
        case "lsquo": return "\u{2018}"
        case "rdquo": return "\u{201D}"
        case "ldquo": return "\u{201C}"
        case "copy": return "\u{00A9}"
        case "reg": return "\u{00AE}"
        case "trade": return "\u{2122}"
        case "hellip": return "\u{2026}"
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
    }

    // MARK: - Decoders

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        let eq = UInt8(ascii: "=")
        while i < bytes.count {
            guard bytes[i] == eq else {
                out.append(bytes[i]); i += 1; continue
            }
            // Soft line break: "=\n" or "=\r\n" disappears entirely.
            if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                i += 2; continue
            }
            if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                i += 3; continue
            }
            // "=XY" hex escape.
            if i + 2 < bytes.count,
               let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo); i += 3; continue
            }
            // Malformed escape — keep the literal byte rather than dropping data.
            out.append(bytes[i]); i += 1
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    private static func decodeCharset(_ data: Data, charset: String?) -> String? {
        switch charset?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii", nil:
            // Declared-or-default UTF-8 that fails to decode falls back to
            // Latin-1 (total mapping): mangled accents beat a lost message.
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        case "iso-8859-1", "latin1", "latin-1":
            return String(data: data, encoding: .isoLatin1)
        case "windows-1252", "cp1252", "cp-1252":
            return String(data: data, encoding: .windowsCP1252)
        default:
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        }
    }
}
