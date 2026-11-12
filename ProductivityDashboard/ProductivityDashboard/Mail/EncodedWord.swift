// Mail/EncodedWord.swift
//
// RFC 2047 "MIME encoded-word" decoder for header values. swift-nio-imap
// gives us raw header strings; encoded-word decoding is MIME-layer, above
// IMAP. Real Gmail returns subjects and from-names with =?CHARSET?B?...?=
// or =?CHARSET?Q?...?= for any non-ASCII content. Without this decoder
// we'd display raw encoded strings (e.g. "=?UTF-8?B?VGVzdA==?=" instead
// of "Test") for a large fraction of real-world mail.
//
// Supports the two encodings defined by RFC 2047:
//   - B: base64
//   - Q: quoted-printable (with the underscore-for-space variant)
// Charsets handled: UTF-8, ISO-8859-1, US-ASCII, Windows-1252. Anything
// unknown falls back to UTF-8 best-effort and on failure the raw input
// is returned (better to show "=?UNKNOWN?B?...?=" than to drop the field).
//
// Per RFC 2047 §6.2, whitespace between two adjacent encoded-words is
// dropped from the decoded output (so a 76-char-wrapped header doesn't
// pick up spurious spaces). That rule is implemented.

import Foundation

enum EncodedWord {
    private static let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#

    static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return input }

        var result = ""
        var cursor = 0
        var lastEndedAsEncodedWord = false

        for match in matches {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let allWhitespace = !between.isEmpty && between.allSatisfy { $0.isWhitespace }

            if !(lastEndedAsEncodedWord && allWhitespace) {
                result += between
            }

            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))

            let decoded: String? = {
                switch encoding {
                case "B":
                    guard let data = Data(base64Encoded: payload) else { return nil }
                    return String(data: data, encoding: encodingFor(charset))
                case "Q":
                    return decodeQuotedPrintable(payload, charset: charset)
                default:
                    return nil
                }
            }()

            result += decoded ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
            lastEndedAsEncodedWord = true
        }

        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    private static func encodingFor(_ charset: String) -> String.Encoding {
        switch charset.uppercased() {
        case "UTF-8":        return .utf8
        case "ISO-8859-1":   return .isoLatin1
        case "US-ASCII":     return .ascii
        case "WINDOWS-1252": return .windowsCP1252
        default:             return .utf8
        }
    }

    private static func decodeQuotedPrintable(_ input: String, charset: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = input.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "=":
                guard let h1 = iterator.next(), let h2 = iterator.next(),
                      let hi = hexValue(h1), let lo = hexValue(h2) else {
                    return nil
                }
                bytes.append(UInt8(hi * 16 + lo))
            case "_":
                bytes.append(0x20)
            default:
                let v = scalar.value
                if v < 128 {
                    bytes.append(UInt8(v))
                } else {
                    return nil
                }
            }
        }
        return String(data: Data(bytes), encoding: encodingFor(charset))
    }

    private static func hexValue(_ s: UnicodeScalar) -> Int? {
        let v = s.value
        if v >= 0x30 && v <= 0x39 { return Int(v - 0x30) }
        if v >= 0x41 && v <= 0x46 { return Int(v - 0x41 + 10) }
        if v >= 0x61 && v <= 0x66 { return Int(v - 0x61 + 10) }
        return nil
    }
}
