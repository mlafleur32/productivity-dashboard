// Mail/EmailStripper.swift
//
// Minimize-what-is-transmitted (ARCHITECTURE.md Security & Privacy item 3): strip
// quoted reply threads and signatures from a plain-text email body BEFORE it
// is eligible for a Claude API call. This runs between the allowlist gate and
// the analyzer — nothing reaches the network without passing through here.
//
// Bias: over-stripping is privacy-safe (less leaves the Mac, we lose a little
// signal); under-stripping transmits other people's words from deeper in the
// thread. When a heuristic is uncertain, cut.
//
// Pure function on Foundation types only — no network, no imports beyond
// Foundation — so the parameterized test suite (EmailStripperTests) can pin
// every marker. Tune by adding (input, expected) rows there, then the marker
// here; keep the two in sync.

import Foundation

enum EmailStripper {

    /// Returns the sender's own new content: everything up to the first
    /// thread or signature marker, with any residual quoted lines removed.
    static func strip(_ rawBody: String) -> String {
        // IMAP delivers CRLF line endings; normalize once so every marker
        // check below can assume "\n".
        let normalized = rawBody.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        // Truncate at the FIRST boundary of either kind. A signature ends
        // the sender's content just as surely as a quoted thread does, so
        // whichever appears first wins. Content after the boundary is
        // dropped even if it looks fresh — inline replies below an
        // "On ... wrote:" line are sacrificed deliberately (see bias note).
        if let cut = lines.firstIndex(where: { isThreadMarker($0) || isSignatureMarker($0) }) {
            lines = Array(lines[..<cut])
        }

        // Residual inline quotes ("> ..." fragments quoted mid-body without
        // a marker line) never belong to the sender.
        lines = lines.filter { !$0.hasPrefix(">") }

        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Thread markers (start of quoted history)

    private static func isThreadMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Gmail / Apple Mail attribution: "On <date>, <name> wrote:"
        // Anchored both ends so a sentence that merely contains "wrote:"
        // doesn't trigger. Wrapped two-line attributions are a known gap —
        // tune here when one shows up.
        if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:") { return true }

        if trimmed == "-----Original Message-----" { return true }   // Outlook classic
        if trimmed == "Begin forwarded message:" { return true }     // Apple Mail forward
        if trimmed == "---------- Forwarded message ---------" { return true } // Gmail forward

        // Outlook mobile/web separator: a long run of underscores.
        if trimmed.count >= 10, trimmed.allSatisfy({ $0 == "_" }) { return true }

        return false
    }

    // MARK: - Signature markers (start of sender's boilerplate)

    private static func isSignatureMarker(_ line: String) -> Bool {
        // RFC 3676 signature delimiter is exactly "-- " (dash dash space);
        // many clients drop the trailing space, so accept a bare "--" too.
        if line == "-- " || line == "--" { return true }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Sent from my ") { return true }        // iPhone/iPad/etc.
        if trimmed == "Get Outlook for iOS" || trimmed == "Get Outlook for Android" { return true }

        return false
    }
}
