// Actions/UnsubscribeExecutor.swift
//
// Stage 7, Step C. The ONLY code that carries out an unsubscribe. It
// implements MailUnsubscribing, whose single entry point takes a
// ConfirmedUnsubscribeAction — mintable only by the confirmation dialog
// (UnsubscribeConfirmation.swift). Nothing here can run unconfirmed.
//
// Two methods, both chosen upstream from headers only:
//
//   One-click (RFC 8058): exactly one POST, body `List-Unsubscribe=One-Click`,
//   through a locked-down transport — ephemeral session, no cookies, no
//   cache, no stored credentials, redirects refused, auth challenges other
//   than normal TLS server trust cancelled, short timeouts, generic
//   User-Agent (no app name / OS build). The destination is re-validated
//   here immediately before every request (defense in depth). Success is a
//   2xx. Redirects (settled 2026-09-16, after a live 307 from a real
//   sender): URLSession never follows them; this executor follows AT MOST
//   ONE hop, and only a 307/308 (which repeat the POST — never 301/302/303,
//   which turn it into a GET page visit) to a URL that passes every safety
//   rule. Same-site targets (approved host or a subdomain) are followed
//   automatically; a cross-site target stops and returns
//   .redirectNeedsApproval so the user can approve the new host in a second
//   dialog (settled 2026-09-16) — followRedirect() then sends exactly one
//   more POST and follows nothing further. Everything else is refused, and
//   the alert names the host it tried to go to.
//
//   mailto: build a sanitized mailto: URL (recipient + subject + body only,
//   strictly percent-encoded) and hand it to Apple Mail as a draft. The app
//   never sends mail; the user reviews and sends from Mail (or doesn't).
//
// No new entitlements: com.apple.security.network.client already covers
// outbound HTTPS; NSWorkspace URL handoff needs none. Logging is status
// only — never URLs, hosts, recipients, senders, or subjects.

import AppKit
import Foundation
import os

// MARK: - Errors

enum UnsubscribeError: Error, Equatable, Sendable {
    case unsafeDestination
    case redirectRefused(toHost: String?)
    case rejected(status: Int)
    case networkFailure
    case mailAppUnavailable
    case draftFailed

    var userMessage: String {
        switch self {
        case .unsafeDestination:
            return "Didn't unsubscribe — the unsubscribe address didn't pass safety checks."
        case .redirectRefused(let host):
            let destination = host.map { " to \($0)" } ?? ""
            return "Didn't unsubscribe — the sender's server tried to redirect the request\(destination), which the app doesn't follow. Archive the message instead."
        case .rejected(let status):
            return "The sender's server didn't accept the unsubscribe request (HTTP \(status)). You may still be subscribed."
        case .networkFailure:
            return "Couldn't reach the sender's unsubscribe server. Nothing was changed; you can try again."
        case .mailAppUnavailable:
            return "Couldn't find Apple Mail to open the unsubscribe draft."
        case .draftFailed:
            return "Couldn't open the unsubscribe draft in Apple Mail."
        }
    }
}

// MARK: - Seams (protocols so tests never open a socket or launch Mail)

protocol UnsubscribeHTTPTransport: Sendable {
    /// Perform the request and return the FIRST response — a redirect is
    /// returned as-is (3xx), never followed.
    func perform(_ request: URLRequest) async throws -> HTTPURLResponse
}

protocol MailDraftOpening: Sendable {
    /// Open `mailtoURL` as a draft in Apple Mail. Throws UnsubscribeError.
    func openDraft(_ mailtoURL: URL) async throws
}

// MARK: - Executor

struct UnsubscribeExecutor: MailUnsubscribing {
    let transport: UnsubscribeHTTPTransport
    let draftOpener: MailDraftOpening

    init(transport: UnsubscribeHTTPTransport = EphemeralUnsubscribeTransport(),
         draftOpener: MailDraftOpening = AppleMailDraftOpener()) {
        self.transport = transport
        self.draftOpener = draftOpener
    }

    private static let log = Logger(subsystem: "LuminalMachines.ProductivityDashboard",
                                    category: "unsubscribe")

    func unsubscribe(_ action: ConfirmedUnsubscribeAction) async throws -> UnsubscribeOutcome {
        switch action.method {
        case .oneClick(let url):
            return try await performOneClick(url, action: action)
        case .mailto(let target):
            guard let url = Self.mailtoURL(for: target) else {
                throw UnsubscribeError.unsafeDestination
            }
            try await draftOpener.openDraft(url)
            Self.log.info("mailto draft handed to Apple Mail")
            return .draftHandedOff
        }
    }

    static let maxRedirectHops = 1

    private func performOneClick(_ approved: URL, action: ConfirmedUnsubscribeAction) async throws -> UnsubscribeOutcome {
        var current = approved
        var hops = 0
        while true {
            let response = try await post(to: current)
            let status = response.statusCode
            switch status {
            case 200...299:
                return .oneClickAccepted(status: status)
            case 300...399:
                let target = Self.redirectTarget(of: response, from: current)
                if let target, hops < Self.maxRedirectHops {
                    if Self.isFollowableRedirect(status: status, to: target, approved: approved) {
                        hops += 1
                        current = target
                        Self.log.info("following one same-site \(status, privacy: .public) redirect")
                        continue
                    }
                    if let pending = UnsubscribeRedirectPolicy.pendingApproval(
                        for: action, status: status, target: target) {
                        Self.log.info("cross-site \(status, privacy: .public) redirect awaiting user approval")
                        return .redirectNeedsApproval(pending)
                    }
                }
                throw UnsubscribeError.redirectRefused(toHost: target?.host(percentEncoded: true))
            default:
                throw UnsubscribeError.rejected(status: status)
            }
        }
    }

    func followRedirect(_ redirect: ConfirmedUnsubscribeRedirect) async throws -> UnsubscribeOutcome {
        let response = try await post(to: redirect.target)
        let status = response.statusCode
        switch status {
        case 200...299:
            return .oneClickAccepted(status: status)
        case 300...399:
            // One hop was the limit; a hand-off that redirects again stops.
            let target = Self.redirectTarget(of: response, from: redirect.target)
            throw UnsubscribeError.redirectRefused(toHost: target?.host(percentEncoded: true))
        default:
            throw UnsubscribeError.rejected(status: status)
        }
    }

    /// One locked-down POST, with the URL re-validated immediately before
    /// the request (defense in depth, every hop).
    private func post(to url: URL) async throws -> HTTPURLResponse {
        guard ListUnsubscribeParser.safeHTTPSURL(url.absoluteString) != nil else {
            throw UnsubscribeError.unsafeDestination
        }
        do {
            let response = try await transport.perform(Self.oneClickRequest(for: url))
            Self.log.info("one-click response status \(response.statusCode, privacy: .public)")
            return response
        } catch let error as UnsubscribeError {
            throw error
        } catch {
            Self.log.error("one-click transport failure")
            throw UnsubscribeError.networkFailure
        }
    }

    /// The Location header resolved against the URL that produced it.
    static func redirectTarget(of response: HTTPURLResponse, from url: URL) -> URL? {
        guard let location = response.value(forHTTPHeaderField: "Location"),
              !location.isEmpty else { return nil }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }

    /// 307/308 only (method-preserving), target passes every URL safety
    /// rule, and its host is the approved host or a subdomain of it.
    static func isFollowableRedirect(status: Int, to target: URL, approved: URL) -> Bool {
        guard status == 307 || status == 308,
              ListUnsubscribeParser.safeHTTPSURL(target.absoluteString) != nil
        else { return false }
        return isSameSite(target, approved: approved)
    }

    static func isSameSite(_ target: URL, approved: URL) -> Bool {
        func normalizedHost(_ url: URL) -> String? {
            guard var host = url.host(percentEncoded: true)?.lowercased(), !host.isEmpty else { return nil }
            if host.hasSuffix(".") { host.removeLast() }
            return host
        }
        guard let t = normalizedHost(target), let a = normalizedHost(approved) else { return false }
        return t == a || t.hasSuffix("." + a)
    }

    // MARK: Pure builders (unit-tested)

    static let oneClickBody = "List-Unsubscribe=One-Click"
    static let requestTimeout: TimeInterval = 15
    static let genericUserAgent = "List-Unsubscribe-Client"

    /// The one-click POST, exactly per RFC 8058 and nothing more.
    static func oneClickRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = Data(oneClickBody.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(genericUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    /// Characters left unescaped in mailto components: RFC 3986 unreserved
    /// only. Everything else — including & = + # ? % and CR/LF — is encoded,
    /// so a subject/body can never inject another query parameter.
    private static let strictAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Rebuild a mailto: URL from the sanitized target only.
    static func mailtoURL(for target: MailtoUnsubscribe) -> URL? {
        guard ListUnsubscribeParser.isSafeAddress(target.recipient) else { return nil }
        var query: [String] = []
        if let subject = target.subject,
           let encoded = subject.addingPercentEncoding(withAllowedCharacters: strictAllowed) {
            query.append("subject=\(encoded)")
        }
        if let body = target.body,
           let encoded = body.addingPercentEncoding(withAllowedCharacters: strictAllowed) {
            query.append("body=\(encoded)")
        }
        let string = "mailto:\(target.recipient)" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        return URL(string: string)
    }
}

// MARK: - Real transport

/// URLSession locked down for sender-chosen destinations. Apple framework
/// only (ARCHITECTURE.md Dependencies: no third-party networking).
struct EphemeralUnsubscribeTransport: UnsubscribeHTTPTransport {

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = UnsubscribeExecutor.requestTimeout
        config.timeoutIntervalForResource = UnsubscribeExecutor.requestTimeout + 5
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    func perform(_ request: URLRequest) async throws -> HTTPURLResponse {
        // Demo mode / preview canvas: no unsubscribe request leaves the Mac.
        if RealIOGuard.isBlocked { throw UnsubscribeError.networkFailure }
        let session = URLSession(configuration: Self.makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request, delegate: RedirectRefusingDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw UnsubscribeError.networkFailure
        }
        return http
    }
}

/// Per-task delegate: never follow a redirect (the 3xx is returned to the
/// caller and treated as failure), and never answer an auth challenge
/// other than standard TLS server-trust evaluation. Methods are nonisolated
/// because URLSession calls delegates off the main actor (the target's
/// default isolation is MainActor). Completion-handler forms, deliberately.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Real draft opener

/// Hands a mailto: URL to Apple Mail specifically (not whatever the default
/// mail handler is), so the settled "Apple Mail draft" posture holds.
struct AppleMailDraftOpener: MailDraftOpening {
    static let mailBundleID = "com.apple.mail"

    func openDraft(_ mailtoURL: URL) async throws {
        if RealIOGuard.isBlocked { throw UnsubscribeError.mailAppUnavailable }
        guard mailtoURL.scheme?.lowercased() == "mailto" else {
            throw UnsubscribeError.unsafeDestination
        }
        guard let mailApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.mailBundleID) else {
            throw UnsubscribeError.mailAppUnavailable
        }
        do {
            _ = try await NSWorkspace.shared.open([mailtoURL], withApplicationAt: mailApp,
                                                 configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw UnsubscribeError.draftFailed
        }
    }
}
