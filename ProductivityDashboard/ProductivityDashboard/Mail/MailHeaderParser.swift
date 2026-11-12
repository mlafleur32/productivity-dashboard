// Mail/MailHeaderParser.swift
//
// Parses a raw RFC 5322 header block — the bytes returned by IMAP
// BODY.PEEK[HEADER.FIELDS (...)] — into field name/value pairs. Handles:
//   - folding: a line starting with space/tab continues the previous field.
//   - case-insensitive field names.
//   - repeated fields (e.g. multiple Authentication-Results), preserved in
//     delivered order so the anti-forgery "topmost wins" rule downstream
//     can rely on ordering.
//
// Pure and header-only; does not touch bodies. Kept separate from
// IMAPMailSource so it can be unit-tested without a network.

import Foundation

// nonisolated: read on the fetch path and by HeaderForensics, both of
// which run off the main actor under this project's MainActor-by-default
// isolation.
nonisolated struct ParsedHeaders {
    // (lowercased name, raw value) in delivered order.
    let fields: [(name: String, value: String)]

    /// First value for a field (case-insensitive), or nil.
    func first(_ name: String) -> String? {
        let key = name.lowercased()
        return fields.first { $0.name == key }?.value
    }

    /// All values for a field (case-insensitive), in delivered order.
    func all(_ name: String) -> [String] {
        let key = name.lowercased()
        return fields.filter { $0.name == key }.map(\.value)
    }
}

nonisolated enum MailHeaderParser {
    static func parse(_ raw: String) -> ParsedHeaders {
        // Normalize line endings, then split. A blank line ends the header
        // block (defensive — HEADER.FIELDS usually returns headers only).
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var fields: [(name: String, value: String)] = []
        var currentName: String?
        var currentValue = ""

        func flush() {
            if let name = currentName {
                fields.append((name, currentValue.trimmingCharacters(in: .whitespaces)))
            }
            currentName = nil
            currentValue = ""
        }

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }  // end of header block

            let isFold = line.first == " " || line.first == "\t"
            if isFold {
                // Continuation of the current field's value. Join with a
                // single space (unfolding).
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let colon = line.firstIndex(of: ":") else {
                // Malformed line with no colon and not a fold — skip it.
                continue
            }
            flush()
            currentName = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            currentValue = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        flush()

        return ParsedHeaders(fields: fields)
    }
}
