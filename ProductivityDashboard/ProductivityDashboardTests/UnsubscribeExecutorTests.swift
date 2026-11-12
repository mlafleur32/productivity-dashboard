//
//  UnsubscribeExecutorTests.swift
//  ProductivityDashboardTests
//
//  Stage 7, Step C. The executor carries out user-confirmed unsubscribes.
//  Every test uses fakes — no socket is ever opened and Apple Mail is never
//  launched. Confirmed actions are minted the only way the app can: through
//  UnsubscribeEligibility and UnsubscribeConfirmationFlow.
//
//  Synthetic hosts and addresses only (git hygiene rule).
//

import Testing
import Foundation
@testable import ProductivityDashboard

// @MainActor: the app target defaults to MainActor isolation, so its
// types (and their conformances) are main-actor-isolated; running the
// suite there too removes the cross-isolation warnings (cleanup pass).
@MainActor
struct UnsubscribeExecutorTests {

    // MARK: - Fakes

    final class FakeTransport: UnsubscribeHTTPTransport, @unchecked Sendable {
        struct Reply { let status: Int; let location: String? }
        private(set) var requests: [URLRequest] = []
        private var replies: [Reply]
        let error: Error?

        init(status: Int = 200, error: Error? = nil) {
            self.replies = [Reply(status: status, location: nil)]
            self.error = error
        }

        /// Scripted replies, in order; the last one repeats if exhausted.
        init(replies: [Reply]) {
            self.replies = replies
            self.error = nil
        }

        func perform(_ request: URLRequest) async throws -> HTTPURLResponse {
            requests.append(request)
            if let error { throw error }
            let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
            let headers = reply.location.map { ["Location": $0] }
            return HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                   httpVersion: "HTTP/1.1", headerFields: headers)!
        }
    }

    final class FakeDraftOpener: MailDraftOpening, @unchecked Sendable {
        private(set) var opened: [URL] = []
        let error: UnsubscribeError?

        init(error: UnsubscribeError? = nil) { self.error = error }

        func openDraft(_ mailtoURL: URL) async throws {
            if let error { throw error }
            opened.append(mailtoURL)
        }
    }

    // MARK: - Minting confirmed actions (the real way)

    static func confirmed(listUnsubscribe: String, post: String?, dkim: AuthVerdict?) throws -> ConfirmedUnsubscribeAction {
        let message = MailMessage(
            id: "synthetic-id", fromName: "Synthetic List", fromAddress: "news@list.example.com",
            subject: "Synthetic newsletter", date: .now,
            listUnsubscribe: listUnsubscribe, listUnsubscribePost: post,
            authentication: dkim.map { AuthenticationResults(spf: .pass, dkim: $0, dmarc: .pass) })
        let offer = try #require(UnsubscribeEligibility.offer(for: message, localCategory: .newsletter, cloudVerdict: nil))
        let flow = UnsubscribeConfirmationFlow()
        flow.request(offer)
        return try #require(flow.confirm())
    }

    static func oneClickAction() throws -> ConfirmedUnsubscribeAction {
        try confirmed(listUnsubscribe: "<https://unsub.example.com/u?t=tok-123>",
                      post: "List-Unsubscribe=One-Click", dkim: .pass)
    }

    static func mailtoAction(_ header: String = "<mailto:leave@list.example.com?subject=unsubscribe&body=remove%20me>") throws -> ConfirmedUnsubscribeAction {
        try confirmed(listUnsubscribe: header, post: nil, dkim: nil)
    }

    // MARK: - One-click

    @Test("One-click sends exactly one RFC 8058 POST and never opens a draft")
    func oneClickRequestShape() async throws {
        let transport = FakeTransport(status: 200)
        let opener = FakeDraftOpener()
        let outcome = try await UnsubscribeExecutor(transport: transport, draftOpener: opener)
            .unsubscribe(try Self.oneClickAction())

        #expect(outcome == .oneClickAccepted(status: 200))
        #expect(opener.opened.isEmpty)
        #expect(transport.requests.count == 1)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://unsub.example.com/u?t=tok-123")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("List-Unsubscribe=One-Click".utf8))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == UnsubscribeExecutor.genericUserAgent)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    struct StatusCase: Sendable, CustomTestStringConvertible {
        let status: Int
        let expected: Result
        enum Result: Equatable, Sendable {
            case accepted
            case needsApproval(host: String)
            case error(UnsubscribeError)
        }
        var testDescription: String { "HTTP \(status)" }
    }

    nonisolated static let statusCases: [StatusCase] = [
        .init(status: 200, expected: .accepted),
        .init(status: 202, expected: .accepted),
        .init(status: 204, expected: .accepted),
        .init(status: 301, expected: .error(.redirectRefused(toHost: nil))),
        .init(status: 302, expected: .error(.redirectRefused(toHost: nil))),
        .init(status: 307, expected: .error(.redirectRefused(toHost: nil))),
        .init(status: 400, expected: .error(.rejected(status: 400))),
        .init(status: 404, expected: .error(.rejected(status: 404))),
        .init(status: 500, expected: .error(.rejected(status: 500))),
    ]

    @Test("One-click status mapping — only 2xx counts as success", arguments: statusCases)
    func statusMapping(_ c: StatusCase) async throws {
        let executor = UnsubscribeExecutor(transport: FakeTransport(status: c.status),
                                           draftOpener: FakeDraftOpener())
        let actual: StatusCase.Result
        do {
            let outcome = try await executor.unsubscribe(try Self.oneClickAction())
            #expect(outcome == .oneClickAccepted(status: c.status))
            actual = .accepted
        } catch let error as UnsubscribeError {
            actual = .error(error)
        }
        #expect(actual == c.expected)
    }

    // MARK: - Redirects (settled 2026-09-16: one same-site 307/308 hop)

    typealias Reply = FakeTransport.Reply

    struct RedirectCase: Sendable, CustomTestStringConvertible {
        let name: String
        let first: Reply
        let second: Reply
        let expectedRequests: Int
        let expected: StatusCase.Result
        var testDescription: String { name }
    }

    nonisolated static let redirectCases: [RedirectCase] = [
        .init(name: "307 same host, then 200 → followed",
              first: Reply(status: 307, location: "https://unsub.example.com/confirm?t=tok-123"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 2, expected: .accepted),
        .init(name: "308 to a subdomain of the approved host → followed",
              first: Reply(status: 308, location: "https://eu.unsub.example.com/u"),
              second: Reply(status: 202, location: nil),
              expectedRequests: 2, expected: .accepted),
        .init(name: "relative Location resolves on the same host → followed",
              first: Reply(status: 307, location: "/v2/unsubscribe"),
              second: Reply(status: 204, location: nil),
              expectedRequests: 2, expected: .accepted),
        .init(name: "307 to a different company → stops and asks, nothing further sent",
              first: Reply(status: 307, location: "https://links.vendor.example.net/u?t=tok"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .needsApproval(host: "links.vendor.example.net")),
        .init(name: "308 to a different company → stops and asks",
              first: Reply(status: 308, location: "https://links.vendor.example.net/u"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .needsApproval(host: "links.vendor.example.net")),
        .init(name: "307 to the parent domain → treated as cross-site, asks",
              first: Reply(status: 307, location: "https://example.com/u"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .needsApproval(host: "example.com")),
        .init(name: "307 to a look-alike suffix host → treated as cross-site, asks",
              first: Reply(status: 307, location: "https://evilunsub.example.com/u"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .needsApproval(host: "evilunsub.example.com")),
        .init(name: "cross-site 307 to an IP literal → refused, never asked",
              first: Reply(status: 307, location: "https://10.0.0.1/u"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .error(.redirectRefused(toHost: "10.0.0.1"))),
        .init(name: "cross-site 307 to localhost → refused, never asked",
              first: Reply(status: 307, location: "https://localhost/u"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .error(.redirectRefused(toHost: "localhost"))),
        .init(name: "cross-site 302 → refused, never asked (would become a GET)",
              first: Reply(status: 302, location: "https://links.vendor.example.net/u"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .error(.redirectRefused(toHost: "links.vendor.example.net"))),
        .init(name: "same-site hop then cross-site hop → refused (one hop max)",
              first: Reply(status: 307, location: "https://unsub.example.com/hop1"),
              second: Reply(status: 307, location: "https://links.vendor.example.net/u"),
              expectedRequests: 2, expected: .error(.redirectRefused(toHost: "links.vendor.example.net"))),
        .init(name: "302 same host → refused (would become a GET)",
              first: Reply(status: 302, location: "https://unsub.example.com/confirm"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .error(.redirectRefused(toHost: "unsub.example.com"))),
        .init(name: "303 same host → refused",
              first: Reply(status: 303, location: "https://unsub.example.com/confirm"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .error(.redirectRefused(toHost: "unsub.example.com"))),
        .init(name: "307 same host over http → refused",
              first: Reply(status: 307, location: "http://unsub.example.com/u"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .error(.redirectRefused(toHost: "unsub.example.com"))),
        .init(name: "307 same host, non-default port → refused",
              first: Reply(status: 307, location: "https://unsub.example.com:8443/u"),
              second: Reply(status: 200, location: nil),
              expectedRequests: 1, expected: .error(.redirectRefused(toHost: "unsub.example.com"))),
        .init(name: "second 307 hop → refused (one hop max)",
              first: Reply(status: 307, location: "https://unsub.example.com/hop1"),
              second: Reply(status: 307, location: "https://unsub.example.com/hop2"),
              expectedRequests: 2, expected: .error(.redirectRefused(toHost: "unsub.example.com"))),
        .init(name: "followed hop that the server rejects → rejected",
              first: Reply(status: 307, location: "https://unsub.example.com/confirm"),
              second: Reply(status: 410, location: nil),
              expectedRequests: 2, expected: .error(.rejected(status: 410))),
    ]

    @Test("Redirect policy", arguments: redirectCases)
    func redirectPolicy(_ c: RedirectCase) async throws {
        let transport = FakeTransport(replies: [c.first, c.second])
        let executor = UnsubscribeExecutor(transport: transport, draftOpener: FakeDraftOpener())
        let actual: StatusCase.Result
        do {
            let outcome = try await executor.unsubscribe(try Self.oneClickAction())
            if case .redirectNeedsApproval(let pending) = outcome {
                actual = .needsApproval(host: pending.targetHost)
            } else {
                actual = .accepted
            }
        } catch let error as UnsubscribeError {
            actual = .error(error)
        }
        #expect(actual == c.expected)
        #expect(transport.requests.count == c.expectedRequests)
        // Every request — including a followed hop — is the same RFC 8058 POST.
        for request in transport.requests {
            #expect(request.httpMethod == "POST")
            #expect(request.httpBody == Data("List-Unsubscribe=One-Click".utf8))
            #expect(request.url?.scheme == "https")
        }
    }

    // MARK: - Following an approved cross-site redirect

    /// Mint an approved redirect the only way the app can: policy → flow.
    static func approvedRedirect(to target: String) throws -> ConfirmedUnsubscribeRedirect {
        let pending = try #require(UnsubscribeRedirectPolicy.pendingApproval(
            for: try oneClickAction(), status: 307, target: URL(string: target)!))
        let flow = UnsubscribeRedirectFlow()
        flow.request(pending)
        return try #require(flow.confirm())
    }

    @Test("An approved redirect sends exactly one RFC 8058 POST to the approved target")
    func followApprovedRedirect() async throws {
        let transport = FakeTransport(status: 202)
        let redirect = try Self.approvedRedirect(to: "https://links.vendor.example.net/u?t=tok")
        let outcome = try await UnsubscribeExecutor(transport: transport, draftOpener: FakeDraftOpener())
            .followRedirect(redirect)

        #expect(outcome == .oneClickAccepted(status: 202))
        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://links.vendor.example.net/u?t=tok")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("List-Unsubscribe=One-Click".utf8))
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test("An approved redirect that redirects again is refused — no second hop")
    func followedRedirectDoesNotChain() async throws {
        let transport = FakeTransport(replies: [Reply(status: 307, location: "https://elsewhere.example.org/u")])
        let redirect = try Self.approvedRedirect(to: "https://links.vendor.example.net/u")
        let executor = UnsubscribeExecutor(transport: transport, draftOpener: FakeDraftOpener())
        await #expect(throws: UnsubscribeError.redirectRefused(toHost: "elsewhere.example.org")) {
            _ = try await executor.followRedirect(redirect)
        }
        #expect(transport.requests.count == 1)
    }

    @Test("An approved redirect the server rejects surfaces the status")
    func followedRedirectRejected() async throws {
        let redirect = try Self.approvedRedirect(to: "https://links.vendor.example.net/u")
        let executor = UnsubscribeExecutor(transport: FakeTransport(status: 404), draftOpener: FakeDraftOpener())
        await #expect(throws: UnsubscribeError.rejected(status: 404)) {
            _ = try await executor.followRedirect(redirect)
        }
    }

    @Test("Refused-redirect alert names the host it tried to go to")
    func redirectMessageNamesHost() {
        #expect(UnsubscribeError.redirectRefused(toHost: "tracker.example.net").userMessage
            .contains("to tracker.example.net"))
        #expect(!UnsubscribeError.redirectRefused(toHost: nil).userMessage.contains(" to ,"))
    }

    @Test("Transport failure surfaces as networkFailure")
    func transportFailure() async throws {
        let executor = UnsubscribeExecutor(transport: FakeTransport(error: URLError(.notConnectedToInternet)),
                                           draftOpener: FakeDraftOpener())
        let action = try Self.oneClickAction()
        await #expect(throws: UnsubscribeError.networkFailure) {
            _ = try await executor.unsubscribe(action)
        }
    }

    // MARK: - mailto

    @Test("mailto opens exactly one draft and never touches the network")
    func mailtoHandoff() async throws {
        let transport = FakeTransport()
        let opener = FakeDraftOpener()
        let action = try Self.mailtoAction()
        let outcome = try await UnsubscribeExecutor(transport: transport, draftOpener: opener).unsubscribe(action)

        #expect(outcome == .draftHandedOff)
        #expect(transport.requests.isEmpty)
        #expect(opener.opened.count == 1)

        // What Mail receives parses back to exactly the sanitized target.
        let url = try #require(opener.opened.first)
        guard case .mailto(let target) = action.method else {
            Issue.record("expected a mailto method")
            return
        }
        #expect(ListUnsubscribeParser.mailto(url.absoluteString) == target)
    }

    @Test("Draft opener failure propagates")
    func draftOpenerFailure() async throws {
        let executor = UnsubscribeExecutor(transport: FakeTransport(),
                                           draftOpener: FakeDraftOpener(error: .mailAppUnavailable))
        let action = try Self.mailtoAction()
        await #expect(throws: UnsubscribeError.mailAppUnavailable) {
            _ = try await executor.unsubscribe(action)
        }
    }

    @Test("mailto builder encodes & = + # and newlines so nothing can inject a parameter")
    func mailtoBuilderEncodesStrictly() throws {
        let target = MailtoUnsubscribe(recipient: "leave@list.example.com",
                                       subject: "a&cc=spy@other.example.com#x+y",
                                       body: "line1\r\nBcc: spy@other.example.com")
        let url = try #require(UnsubscribeExecutor.mailtoURL(for: target))
        let string = url.absoluteString
        #expect(!string.contains("&cc="))
        #expect(!string.contains("#"))
        #expect(!string.contains("\n"))
        #expect(string.hasPrefix("mailto:leave@list.example.com?subject="))
        // Round-trip: subject survives intact; the body with CR/LF is still
        // a valid body (newlines allowed), and no cc/bcc exists anywhere.
        let parsed = try #require(ListUnsubscribeParser.mailto(string))
        #expect(parsed.recipient == "leave@list.example.com")
        #expect(parsed.subject == "a&cc=spy@other.example.com#x+y")
        let components = try #require(URLComponents(string: string))
        #expect(Set((components.queryItems ?? []).map(\.name)) == ["subject", "body"])
    }

    @Test("mailto builder with no subject or body yields a bare mailto")
    func mailtoBuilderBare() throws {
        let url = try #require(UnsubscribeExecutor.mailtoURL(
            for: MailtoUnsubscribe(recipient: "leave@list.example.com", subject: nil, body: nil)))
        #expect(url.absoluteString == "mailto:leave@list.example.com")
    }

    @Test("mailto builder refuses an unsafe recipient",
          arguments: ["leave@127.0.0.1", "leave@localhost", "a@b@list.example.com", "leave@list.example.com,x@other.example.com"])
    func mailtoBuilderRefusesUnsafe(_ recipient: String) {
        #expect(UnsubscribeExecutor.mailtoURL(
            for: MailtoUnsubscribe(recipient: recipient, subject: nil, body: nil)) == nil)
    }

    // MARK: - Real transport + opener lockdown (no network, no Mail launch)

    @Test("Transport configuration: no cookies, no cache, no stored credentials")
    func transportConfigurationIsLockedDown() {
        let config = EphemeralUnsubscribeTransport.makeConfiguration()
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.urlCache == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(config.timeoutIntervalForRequest <= 15)
        #expect(config.waitsForConnectivity == false)
    }

    @Test("Apple Mail opener refuses anything but mailto: before touching NSWorkspace")
    func openerRefusesNonMailto() async {
        await #expect(throws: UnsubscribeError.unsafeDestination) {
            try await AppleMailDraftOpener().openDraft(URL(string: "https://unsub.example.com/u")!)
        }
    }
}
