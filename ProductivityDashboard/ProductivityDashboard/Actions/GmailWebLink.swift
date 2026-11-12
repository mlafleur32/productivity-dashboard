// Actions/GmailWebLink.swift
//
// Stage 7 (settled 2026-09-16): when the app can't unsubscribe safely by
// itself — a one-click request the sender's server refused, or a sender
// that offers no safe method — the user can open the exact message in
// Gmail in their browser and use Gmail's own Unsubscribe button.
//
// This is NOT a sender-chosen web page. The URL is built entirely by the
// app: fixed scheme and host (https://mail.google.com), the user's own
// Gmail account, and a search for the message's own Message-ID. Nothing
// from List-Unsubscribe or the body is used. The opener re-checks the host
// before handing anything to the browser (defense in depth). Opening
// Gmail changes nothing by itself, so there is no confirmation dialog —
// the unsubscribe decision happens in Gmail, by the user.

import AppKit
import Foundation

enum GmailWebLink {
    nonisolated static let host = "mail.google.com"

    /// IMAP servers for which the account is a Google mailbox.
    static func isGmailServer(_ server: String) -> Bool {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "imap.gmail.com" || s == "imap.googlemail.com"
    }

    private static let strictAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Link to the message in Gmail, or nil when there's no usable
    /// RFC 5322 Message-ID (e.g. the app's "uid-…" fallback ids).
    static func url(forMessageID rawID: String, account: String) -> URL? {
        var id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") && id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
        guard !id.isEmpty, id.count <= 998, id.contains("@"), !id.hasPrefix("uid-"),
              id.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }),
              !id.contains("<"), !id.contains(">")
        else { return nil }
        let acct = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !acct.isEmpty,
              let encodedAccount = acct.addingPercentEncoding(withAllowedCharacters: strictAllowed),
              let encodedID = id.addingPercentEncoding(withAllowedCharacters: strictAllowed)
        else { return nil }
        return URL(string: "https://\(host)/mail/?authuser=\(encodedAccount)#search/rfc822msgid%3A\(encodedID)")
    }
}

protocol WebLinkOpening: Sendable {
    func open(_ url: URL)
}

/// Opens only https://mail.google.com links in the default browser.
struct GmailLinkOpener: WebLinkOpening {
    nonisolated static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host(percentEncoded: true)?.lowercased() == GmailWebLink.host
            && url.user == nil && url.port == nil
    }

    func open(_ url: URL) {
        guard Self.isAllowed(url), !RealIOGuard.isBlocked else { return }
        NSWorkspace.shared.open(url)
    }
}
