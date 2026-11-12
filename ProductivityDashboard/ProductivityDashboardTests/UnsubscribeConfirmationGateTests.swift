//
//  UnsubscribeConfirmationGateTests.swift
//  ProductivityDashboardTests
//
//  RELEASE GATE (Stage 7, Step B — peer to AllowlistGateTests and
//  ArchiveConfirmationGateTests). Proves, at runtime, the two things the
//  compile-time gates in Actions/UnsubscribeConfirmation.swift rely on:
//
//    1. Eligibility: scam / phishing / suspicious / dmarc=fail mail, and
//       anything not classified as a newsletter, NEVER yields an offer —
//       and the destination comes only from headers, never a cloud verdict.
//    2. Confirmation: every non-confirming path through the flow mints
//       nothing, and a confirmation applies to exactly the offer named.
//
//  Note that these tests can only obtain an UnsubscribeOffer through
//  UnsubscribeEligibility — the fileprivate init makes that the only way,
//  which is itself the point.
//
//  Synthetic messages only (git hygiene rule).
//

import Testing
import Foundation
@testable import ProductivityDashboard

// @MainActor: the app target defaults to MainActor isolation, so its
// types (and their conformances) are main-actor-isolated; running the
// suite there too removes the cross-isolation warnings (cleanup pass).
@MainActor
struct UnsubscribeConfirmationGateTests {

    // MARK: - Synthetic fixtures

    nonisolated static let oneClickPost = "List-Unsubscribe=One-Click"
    nonisolated static let httpsOnly = "<https://unsub.example.com/u?t=secret-token>"
    nonisolated static let mailtoOnly = "<mailto:leave@list.example.com?subject=unsubscribe>"
    nonisolated static let both = "<mailto:leave@list.example.com?subject=unsubscribe>, <https://unsub.example.com/u?t=secret-token>"

    static func msg(
        id: String = "synthetic-id",
        listUnsubscribe: String? = UnsubscribeConfirmationGateTests.both,
        post: String? = UnsubscribeConfirmationGateTests.oneClickPost,
        dkim: AuthVerdict? = .pass,        // nil = no trusted A-R at all
        dmarc: AuthVerdict = .pass
    ) -> MailMessage {
        MailMessage(
            id: id,
            fromName: "Synthetic List",
            fromAddress: "news@list.example.com",
            subject: "Synthetic newsletter",
            date: .now,
            listUnsubscribe: listUnsubscribe,
            listUnsubscribePost: post,
            listId: "<list.example.com>",
            authentication: dkim.map { AuthenticationResults(spf: .pass, dkim: $0, dmarc: dmarc) })
    }

    static func verdict(_ scam: CloudVerdict.ScamJudgment,
                        tasks: [CloudVerdict.ExtractedTask] = []) -> CloudVerdict {
        CloudVerdict(importance: .routine, scam: scam, tasks: tasks)
    }

    // MARK: - Eligibility table

    enum Expect: Equatable, Sendable {
        case oneClick(host: String)
        case mailto(recipient: String)
        case refused(UnsubscribeEligibility.Refusal)
    }

    struct EligibilityCase: Sendable, CustomTestStringConvertible {
        let name: String
        let message: @MainActor @Sendable () -> MailMessage
        let category: MailCategory?
        let cloud: CloudVerdict.ScamJudgment?
        let expected: Expect
        var testDescription: String { name }
    }

    // nonisolated tables: Swift Testing evaluates `arguments:` outside the
    // main actor. Messages are built lazily on the main actor.
    nonisolated static let eligibilityCases: [EligibilityCase] = [
        // Method selection
        .init(name: "one-click: https + Post header + dkim=pass",
              message: { msg(listUnsubscribe: httpsOnly) }, category: .newsletter, cloud: nil,
              expected: .oneClick(host: "unsub.example.com")),
        .init(name: "one-click preferred over mailto when both qualify",
              message: { msg() }, category: .newsletter, cloud: nil,
              expected: .oneClick(host: "unsub.example.com")),
        .init(name: "dkim=fail → mailto fallback",
              message: { msg(dkim: .fail) }, category: .newsletter, cloud: nil,
              expected: .mailto(recipient: "leave@list.example.com")),
        .init(name: "dkim=none → mailto fallback",
              message: { msg(dkim: .notPerformed) }, category: .newsletter, cloud: nil,
              expected: .mailto(recipient: "leave@list.example.com")),
        .init(name: "no trusted Authentication-Results → mailto fallback",
              message: { msg(dkim: nil) }, category: .newsletter, cloud: nil,
              expected: .mailto(recipient: "leave@list.example.com")),
        .init(name: "no Post header → mailto fallback",
              message: { msg(post: nil) }, category: .newsletter, cloud: nil,
              expected: .mailto(recipient: "leave@list.example.com")),
        .init(name: "unsafe https (IP literal) skipped → mailto",
              message: { msg(listUnsubscribe: "<https://10.0.0.1/u>, <mailto:leave@list.example.com>") },
              category: .newsletter, cloud: nil,
              expected: .mailto(recipient: "leave@list.example.com")),
        .init(name: "mailto-only sender",
              message: { msg(listUnsubscribe: mailtoOnly, post: nil) }, category: .newsletter, cloud: nil,
              expected: .mailto(recipient: "leave@list.example.com")),
        .init(name: "Post declared but dkim=fail and no mailto → no offer",
              message: { msg(listUnsubscribe: httpsOnly, dkim: .fail) }, category: .newsletter, cloud: nil,
              expected: .refused(.noSafeMethod)),
        .init(name: "plain https link only (no Post) → never offered",
              message: { msg(listUnsubscribe: httpsOnly, post: nil) }, category: .newsletter, cloud: nil,
              expected: .refused(.noSafeMethod)),
        .init(name: "newsletter by List-Id only, no List-Unsubscribe → no offer",
              message: { msg(listUnsubscribe: nil) }, category: .newsletter, cloud: nil,
              expected: .refused(.noSafeMethod)),
        .init(name: "only unsafe schemes → no offer",
              message: { msg(listUnsubscribe: "<http://unsub.example.com/u>, <javascript:alert(1)>") },
              category: .newsletter, cloud: nil,
              expected: .refused(.noSafeMethod)),
        // Safety blocks
        .init(name: "dmarc=fail blocks even a perfect one-click",
              message: { msg(dmarc: .fail) }, category: .newsletter, cloud: nil,
              expected: .refused(.dmarcFailed)),
        .init(name: "cloud phishing blocks",
              message: { msg() }, category: .newsletter, cloud: .phishing,
              expected: .refused(.cloudFlagged)),
        .init(name: "cloud suspicious blocks",
              message: { msg() }, category: .newsletter, cloud: .suspicious,
              expected: .refused(.cloudFlagged)),
        .init(name: "cloud clean does not block",
              message: { msg() }, category: .newsletter, cloud: .clean,
              expected: .oneClick(host: "unsub.example.com")),
        .init(name: "local scam → not offered",
              message: { msg() }, category: .scam, cloud: nil,
              expected: .refused(.notNewsletter)),
        .init(name: "important → not offered",
              message: { msg() }, category: .important, cloud: nil,
              expected: .refused(.notNewsletter)),
        .init(name: "other → not offered",
              message: { msg() }, category: .other, cloud: nil,
              expected: .refused(.notNewsletter)),
        .init(name: "unclassified (nil category) → not offered",
              message: { msg() }, category: nil, cloud: nil,
              expected: .refused(.notNewsletter)),
    ]

    @Test("Unsubscribe eligibility", arguments: eligibilityCases)
    func eligibility(_ c: EligibilityCase) {
        let actual: Expect
        switch UnsubscribeEligibility.evaluate(c.message(), localCategory: c.category,
                                               cloudVerdict: c.cloud.map { Self.verdict($0) }) {
        case .refused(let reason):
            actual = .refused(reason)
        case .offer(let offer):
            switch offer.method {
            case .oneClick(let url): actual = .oneClick(host: url.host() ?? "")
            case .mailto(let target): actual = .mailto(recipient: target.recipient)
            }
        }
        #expect(actual == c.expected)
    }

    // MARK: - The release-gate invariants, stated directly

    @Test("No category but .newsletter can ever get an offer — even with perfect headers",
          arguments: MailCategory.allCases.filter { $0 != .newsletter })
    func onlyNewslettersAreOffered(_ category: MailCategory) {
        #expect(UnsubscribeEligibility.offer(for: Self.msg(), localCategory: category, cloudVerdict: nil) == nil)
    }

    @Test("Cloud phishing/suspicious can never get an offer — even with perfect headers",
          arguments: [CloudVerdict.ScamJudgment.phishing, .suspicious])
    func cloudFlaggedNeverOffered(_ scam: CloudVerdict.ScamJudgment) {
        #expect(UnsubscribeEligibility.offer(for: Self.msg(), localCategory: .newsletter,
                                             cloudVerdict: Self.verdict(scam)) == nil)
    }

    @Test("A cloud verdict can never SUPPLY a destination (injection firewall)")
    func cloudVerdictCannotSupplyDestination() {
        let injected = Self.verdict(.clean, tasks: [
            .init(title: "Unsubscribe at https://unsub.example.com/u or mailto:leave@list.example.com",
                  dueHint: nil),
        ])
        let decision = UnsubscribeEligibility.evaluate(
            Self.msg(listUnsubscribe: nil, post: nil),
            localCategory: .newsletter, cloudVerdict: injected)
        guard case .refused(.noSafeMethod) = decision else {
            Issue.record("A cloud task string produced an unsubscribe offer")
            return
        }
    }

    @Test("Dialog destination shows the host only — never the tokenized path or query")
    func destinationLabelIsHostOnly() throws {
        let offer = try #require(UnsubscribeEligibility.offer(
            for: Self.msg(), localCategory: .newsletter, cloudVerdict: nil))
        #expect(offer.method.destinationLabel == "unsub.example.com")
        #expect(!offer.method.destinationLabel.contains("secret-token"))
    }

    // MARK: - Confirmation flow: non-confirming paths mint nothing

    private func offer(id: String = UUID().uuidString) throws -> UnsubscribeOffer {
        try #require(UnsubscribeEligibility.offer(
            for: Self.msg(id: id), localCategory: .newsletter, cloudVerdict: nil))
    }

    @Test("Confirm with nothing pending mints nothing")
    func confirmWithoutRequest() {
        #expect(UnsubscribeConfirmationFlow().confirm() == nil)
    }

    @Test("Cancel mints nothing and clears the pending request")
    func cancelMintsNothing() throws {
        let flow = UnsubscribeConfirmationFlow()
        flow.request(try offer())
        flow.cancel()
        #expect(flow.pending == nil)
        #expect(flow.confirm() == nil)
    }

    @Test("A confirmation is single-use: the second confirm mints nothing")
    func confirmIsSingleUse() throws {
        let flow = UnsubscribeConfirmationFlow()
        flow.request(try offer())
        #expect(flow.confirm() != nil)
        #expect(flow.confirm() == nil)
    }

    @Test("Request after cancel needs its own confirmation")
    func cancelDoesNotBleedForward() throws {
        let flow = UnsubscribeConfirmationFlow()
        flow.request(try offer(id: "cancelled"))
        flow.cancel()
        flow.request(try offer(id: "fresh"))
        #expect(flow.confirm()?.message.id == "fresh")
    }

    // MARK: - Confirmation applies to exactly the named offer

    @Test("Confirm mints exactly the pending offer, method included")
    func confirmMintsThePendingOffer() throws {
        let flow = UnsubscribeConfirmationFlow()
        let pending = try offer(id: "the-one")
        flow.request(pending)

        let action = try #require(flow.confirm())
        #expect(action.message.id == "the-one")
        #expect(action.method == pending.method)
        #expect(flow.pending == nil)
    }

    @Test("A newer request replaces the pending one — confirm never applies to a stale offer")
    func newerRequestReplacesPending() throws {
        let flow = UnsubscribeConfirmationFlow()
        flow.request(try offer(id: "stale"))
        flow.request(try offer(id: "current"))

        #expect(flow.confirm()?.message.id == "current")
        #expect(flow.confirm() == nil)
    }

    @Test("The minted action records when it was confirmed")
    func confirmedAtIsStamped() throws {
        let flow = UnsubscribeConfirmationFlow()
        flow.request(try offer())
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try #require(flow.confirm(now: stamp)).confirmedAt == stamp)
    }

    // MARK: - Cross-site redirect gate (settled 2026-09-16)

    private func confirmedOneClick() throws -> ConfirmedUnsubscribeAction {
        let flow = UnsubscribeConfirmationFlow()
        flow.request(try offer())
        return try #require(flow.confirm())
    }

    struct RedirectPolicyCase: Sendable, CustomTestStringConvertible {
        let name: String
        let status: Int
        let target: String
        let asks: Bool
        var testDescription: String { name }
    }

    nonisolated static let redirectPolicyCases: [RedirectPolicyCase] = [
        .init(name: "307 to another company asks", status: 307, target: "https://links.vendor.example.net/u", asks: true),
        .init(name: "308 to another company asks", status: 308, target: "https://links.vendor.example.net/u", asks: true),
        .init(name: "same host never asks (followed automatically)", status: 307, target: "https://unsub.example.com/x", asks: false),
        .init(name: "subdomain never asks (followed automatically)", status: 307, target: "https://eu.unsub.example.com/x", asks: false),
        .init(name: "301 never asks", status: 301, target: "https://links.vendor.example.net/u", asks: false),
        .init(name: "302 never asks", status: 302, target: "https://links.vendor.example.net/u", asks: false),
        .init(name: "303 never asks", status: 303, target: "https://links.vendor.example.net/u", asks: false),
        .init(name: "http target never asks", status: 307, target: "http://links.vendor.example.net/u", asks: false),
        .init(name: "IP-literal target never asks", status: 307, target: "https://192.168.1.10/u", asks: false),
        .init(name: "localhost target never asks", status: 307, target: "https://localhost/u", asks: false),
        .init(name: ".local target never asks", status: 307, target: "https://printer.local/u", asks: false),
        .init(name: "userinfo target never asks", status: 307, target: "https://user@links.vendor.example.net/u", asks: false),
    ]

    @Test("Only safe, method-preserving, cross-site redirects can reach the second dialog",
          arguments: redirectPolicyCases)
    func redirectPolicy(_ c: RedirectPolicyCase) throws {
        let pending = UnsubscribeRedirectPolicy.pendingApproval(
            for: try confirmedOneClick(), status: c.status, target: URL(string: c.target)!)
        #expect((pending != nil) == c.asks)
    }

    @Test("A mailto action can never produce a redirect approval")
    func mailtoNeverRedirects() throws {
        let message = Self.msg(listUnsubscribe: Self.mailtoOnly, post: nil, dkim: nil)
        let offer = try #require(UnsubscribeEligibility.offer(for: message, localCategory: .newsletter, cloudVerdict: nil))
        let flow = UnsubscribeConfirmationFlow()
        flow.request(offer)
        let action = try #require(flow.confirm())
        #expect(UnsubscribeRedirectPolicy.pendingApproval(
            for: action, status: 307, target: URL(string: "https://links.vendor.example.net/u")!) == nil)
    }

    private func pendingRedirect(_ host: String = "links.vendor.example.net") throws -> PendingUnsubscribeRedirect {
        try #require(UnsubscribeRedirectPolicy.pendingApproval(
            for: try confirmedOneClick(), status: 307, target: URL(string: "https://\(host)/u?t=tok")!))
    }

    @Test("Redirect flow: confirm with nothing pending mints nothing")
    func redirectConfirmWithoutRequest() {
        #expect(UnsubscribeRedirectFlow().confirm() == nil)
    }

    @Test("Redirect flow: cancel mints nothing")
    func redirectCancelMintsNothing() throws {
        let flow = UnsubscribeRedirectFlow()
        flow.request(try pendingRedirect())
        flow.cancel()
        #expect(flow.pending == nil)
        #expect(flow.confirm() == nil)
    }

    @Test("Redirect flow: single-use, and applies to exactly the named target")
    func redirectConfirmExact() throws {
        let flow = UnsubscribeRedirectFlow()
        flow.request(try pendingRedirect("stale.vendor.example.net"))
        flow.request(try pendingRedirect("current.vendor.example.net"))
        let confirmed = try #require(flow.confirm())
        #expect(confirmed.target.host() == "current.vendor.example.net")
        #expect(flow.confirm() == nil)
    }

    @Test("Pending redirect exposes hosts only — never the tokenized path")
    func pendingRedirectHostsOnly() throws {
        let pending = try pendingRedirect()
        #expect(pending.approvedHost == "unsub.example.com")
        #expect(pending.targetHost == "links.vendor.example.net")
        #expect(!pending.targetHost.contains("tok"))
    }

    // MARK: - Email fallback after a failed one-click (settled 2026-09-16)

    @Test("Fallback offers the mailto target even when one-click was the primary method")
    func mailtoFallbackOffered() throws {
        let offer = try #require(UnsubscribeEligibility.mailtoFallbackOffer(
            for: Self.msg(), localCategory: .newsletter, cloudVerdict: nil))
        #expect(offer.method.destinationLabel == "leave@list.example.com")
    }

    @Test("Fallback obeys every safety block")
    func mailtoFallbackSafety() {
        #expect(UnsubscribeEligibility.mailtoFallbackOffer(for: Self.msg(), localCategory: .scam, cloudVerdict: nil) == nil)
        #expect(UnsubscribeEligibility.mailtoFallbackOffer(for: Self.msg(), localCategory: .newsletter,
                                                           cloudVerdict: Self.verdict(.suspicious)) == nil)
        #expect(UnsubscribeEligibility.mailtoFallbackOffer(for: Self.msg(dmarc: .fail), localCategory: .newsletter,
                                                           cloudVerdict: nil) == nil)
    }

    @Test("No mailto in the header → no fallback")
    func mailtoFallbackNeedsMailto() {
        #expect(UnsubscribeEligibility.mailtoFallbackOffer(
            for: Self.msg(listUnsubscribe: Self.httpsOnly), localCategory: .newsletter, cloudVerdict: nil) == nil)
    }
}
