// Actions/UnsubscribeConfirmation.swift
//
// THE UNSUBSCRIBE GATE — Stage 7, Step B. The app's third compile-time
// gate, same idiom as ArchiveConfirmation.swift and CloudAllowlist. Two
// fileprivate inits make two guarantees structural:
//
//   1. UnsubscribeOffer can be constructed ONLY by UnsubscribeEligibility
//      (below). So the confirmation dialog can never be shown for mail
//      the eligibility rules refused — including scam, phishing, suspicious
//      and dmarc=fail mail — and the unsubscribe destination can only come
//      from the message's own headers, never from a cloud verdict or an
//      extracted task (THREAT_PATTERNS.md injection firewall).
//
//   2. ConfirmedUnsubscribeAction can be constructed ONLY by
//      UnsubscribeConfirmationFlow.confirm(). The executors (Step C) accept
//      nothing else, so "an unsubscribe request fires without the user
//      confirming it" is a COMPILE error.
//
// Eligibility rules (ARCHITECTURE.md Stage 7; THREAT_PATTERNS.md "Unsubscribe
// safety"), all fail-safe — any doubt means no offer:
//   - local category is .newsletter (nothing else is ever offered)
//   - no trusted dmarc=fail
//   - no cloud verdict of phishing OR suspicious (cloud can only BLOCK)
//   - a usable method, in priority order:
//       one-click: safe https URI + List-Unsubscribe-Post one-click +
//                  trusted dkim=pass
//       mailto:    a sanitized mailto target (Apple Mail draft; the app
//                  never sends)
//       otherwise: no offer (plain https links are never offered)
//
// Residual (accepted, documented): trusted dkim=pass proves SOME valid DKIM
// signature, not that it covers the List-Unsubscribe headers — the header
// set isn't visible to us, only the receiving server's verdict. The worst
// case is a user-confirmed POST to a host the dialog displayed.
//
// Keep this file small and obvious. Anything that constructs either gated
// type lives here and nowhere else.

import Foundation
import Observation

// MARK: - Method

/// How a confirmed unsubscribe will be carried out. Derived from headers only.
enum UnsubscribeMethod: Equatable, Sendable {
    /// RFC 8058 one-click POST to this https URL.
    case oneClick(URL)
    /// Pre-filled Apple Mail draft to this sanitized target.
    case mailto(MailtoUnsubscribe)

    /// What the confirmation dialog names as the destination: the host a
    /// one-click request goes to, or the mailto recipient. Never the full
    /// URL — its path/query carry per-recipient tokens.
    var destinationLabel: String {
        switch self {
        case .oneClick(let url):   return url.host(percentEncoded: true) ?? "(unknown host)"
        case .mailto(let target):  return target.recipient
        }
    }
}

// MARK: - Offer (gate 1)

/// An unsubscribe the rules allow the UI to offer for one message.
/// Cannot be constructed outside this file (fileprivate init).
struct UnsubscribeOffer: Identifiable, Sendable {
    let message: MailMessage
    let method: UnsubscribeMethod
    var id: String { message.id }

    fileprivate init(message: MailMessage, method: UnsubscribeMethod) {
        self.message = message
        self.method = method
    }
}

enum UnsubscribeEligibility {

    /// Why no offer exists. `noSafeMethod` is the only reason the UI
    /// surfaces ("archive instead"); the others simply show no button.
    nonisolated enum Refusal: Equatable, Sendable {
        case notNewsletter
        case dmarcFailed
        case cloudFlagged
        case noSafeMethod
    }

    enum Decision: Sendable {
        case offer(UnsubscribeOffer)
        case refused(Refusal)
    }

    /// The single mint site for UnsubscribeOffer. Checks run cheapest and
    /// most-safety-critical first; the first failure wins.
    static func evaluate(
        _ message: MailMessage,
        localCategory: MailCategory?,
        cloudVerdict: CloudVerdict?
    ) -> Decision {
        if let refusal = safetyRefusal(message, localCategory: localCategory,
                                       cloudVerdict: cloudVerdict) {
            return .refused(refusal)
        }

        let options = ListUnsubscribeParser.parse(
            listUnsubscribe: message.listUnsubscribe,
            listUnsubscribePost: message.listUnsubscribePost)
        guard let method = selectMethod(
            options, dkimPassed: message.authentication?.dkim == .pass)
        else { return .refused(.noSafeMethod) }

        return .offer(UnsubscribeOffer(message: message, method: method))
    }

    /// The safety half of eligibility, shared by every mint path.
    private static func safetyRefusal(
        _ message: MailMessage,
        localCategory: MailCategory?,
        cloudVerdict: CloudVerdict?
    ) -> Refusal? {
        guard localCategory == .newsletter else { return .notNewsletter }
        if message.authentication?.dmarc == .fail { return .dmarcFailed }
        if let scam = cloudVerdict?.scam, scam != .clean { return .cloudFlagged }
        return nil
    }

    /// Fallback after a one-click attempt failed (settled 2026-09-16): an
    /// offer to unsubscribe by EMAIL instead, if the sender's header lists
    /// a safe mailto target. Same safety checks as evaluate(); the
    /// resulting offer still goes through the normal confirmation dialog.
    static func mailtoFallbackOffer(
        for message: MailMessage,
        localCategory: MailCategory?,
        cloudVerdict: CloudVerdict?
    ) -> UnsubscribeOffer? {
        guard safetyRefusal(message, localCategory: localCategory, cloudVerdict: cloudVerdict) == nil
        else { return nil }
        let options = ListUnsubscribeParser.parse(
            listUnsubscribe: message.listUnsubscribe,
            listUnsubscribePost: message.listUnsubscribePost)
        guard let target = options.mailtos.first else { return nil }
        return UnsubscribeOffer(message: message, method: .mailto(target))
    }

    /// Convenience for the UI: the offer, or nil.
    static func offer(
        for message: MailMessage,
        localCategory: MailCategory?,
        cloudVerdict: CloudVerdict?
    ) -> UnsubscribeOffer? {
        if case .offer(let offer) = evaluate(message, localCategory: localCategory,
                                              cloudVerdict: cloudVerdict) {
            return offer
        }
        return nil
    }

    /// Method priority, from already-sanitized options. Pure.
    static func selectMethod(_ options: ListUnsubscribeOptions, dkimPassed: Bool) -> UnsubscribeMethod? {
        if options.oneClickDeclared, dkimPassed, let url = options.httpsURLs.first {
            return .oneClick(url)
        }
        if let target = options.mailtos.first {
            return .mailto(target)
        }
        return nil
    }
}

// MARK: - Confirmed action (gate 2)

/// An unsubscribe the user explicitly confirmed in the dialog.
/// Cannot be constructed any other way (fileprivate init).
struct ConfirmedUnsubscribeAction: Identifiable, Sendable {
    let offer: UnsubscribeOffer
    let confirmedAt: Date
    var id: String { offer.id }
    var message: MailMessage { offer.message }
    var method: UnsubscribeMethod { offer.method }

    fileprivate init(_ offer: UnsubscribeOffer, confirmedAt: Date) {
        self.offer = offer
        self.confirmedAt = confirmedAt
    }
}

/// What a completed unsubscribe reports back for the action log (Step D).
enum UnsubscribeOutcome: Equatable, Sendable {
    /// One-click POST accepted with this 2xx status.
    case oneClickAccepted(status: Int)
    /// Draft handed to Apple Mail; the user sends (or doesn't) from there.
    case draftHandedOff
    /// The sender's server answered with a 307/308 to a DIFFERENT site.
    /// Nothing further was sent; the user must approve the new host
    /// (settled 2026-09-16: ask before following a cross-site hand-off).
    case redirectNeedsApproval(PendingUnsubscribeRedirect)
}

/// The boundary the gates guard. Both entry points accept only a
/// dialog-minted type, so there is no way around either dialog.
protocol MailUnsubscribing: Sendable {
    func unsubscribe(_ action: ConfirmedUnsubscribeAction) async throws -> UnsubscribeOutcome
    /// Send the same one-click POST to a cross-site redirect target the
    /// user approved. Exactly one request; no further redirects followed.
    func followRedirect(_ redirect: ConfirmedUnsubscribeRedirect) async throws -> UnsubscribeOutcome
}

// MARK: - Cross-site redirect (gate 3, settled 2026-09-16)

/// A cross-site 307/308 hand-off waiting for the user's approval. Mintable
/// only by UnsubscribeRedirectPolicy (fileprivate init), which admits only
/// method-preserving redirects to URLs passing every safety rule — so the
/// second dialog can never be shown for an unsafe or page-visit redirect.
struct PendingUnsubscribeRedirect: Identifiable, Sendable, Equatable {
    let action: ConfirmedUnsubscribeAction
    let status: Int
    let target: URL
    var id: String { action.id }
    var message: MailMessage { action.message }

    /// Host the user originally approved (shown for context).
    var approvedHost: String { action.method.destinationLabel }
    /// Host the request would now go to. Never the path/query (tokens).
    var targetHost: String { target.host(percentEncoded: true) ?? "(unknown host)" }

    fileprivate init(action: ConfirmedUnsubscribeAction, status: Int, target: URL) {
        self.action = action
        self.status = status
        self.target = target
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.action.id == rhs.action.id && lhs.status == rhs.status && lhs.target == rhs.target
    }
}

enum UnsubscribeRedirectPolicy {
    /// The single mint site for PendingUnsubscribeRedirect: a 307/308, to a
    /// URL passing every ListUnsubscribeParser safety rule, whose host is
    /// NOT the approved host or a subdomain of it (same-site hops are
    /// followed automatically by the executor and never reach here).
    static func pendingApproval(for action: ConfirmedUnsubscribeAction,
                                status: Int, target: URL) -> PendingUnsubscribeRedirect? {
        guard status == 307 || status == 308,
              case .oneClick(let approved) = action.method,
              ListUnsubscribeParser.safeHTTPSURL(target.absoluteString) != nil,
              !UnsubscribeExecutor.isSameSite(target, approved: approved)
        else { return nil }
        return PendingUnsubscribeRedirect(action: action, status: status, target: target)
    }
}

/// A cross-site redirect the user approved in the second dialog.
/// Cannot be constructed any other way (fileprivate init).
struct ConfirmedUnsubscribeRedirect: Identifiable, Sendable {
    let pending: PendingUnsubscribeRedirect
    let confirmedAt: Date
    var id: String { pending.id }
    var message: MailMessage { pending.message }
    var target: URL { pending.target }

    fileprivate init(_ pending: PendingUnsubscribeRedirect, confirmedAt: Date) {
        self.pending = pending
        self.confirmedAt = confirmedAt
    }
}

/// Drives the "send your unsubscribe to another company?" dialog. Same
/// state machine as the other flows: cancel mints nothing, one confirm
/// mints one follow, a newer request replaces the pending one.
@Observable
final class UnsubscribeRedirectFlow {
    private(set) var pending: PendingUnsubscribeRedirect?

    func request(_ redirect: PendingUnsubscribeRedirect) {
        pending = redirect
    }

    func cancel() {
        pending = nil
    }

    /// The single mint site for ConfirmedUnsubscribeRedirect.
    func confirm(now: Date = .now) -> ConfirmedUnsubscribeRedirect? {
        guard let redirect = pending else { return nil }
        pending = nil
        return ConfirmedUnsubscribeRedirect(redirect, confirmedAt: now)
    }
}

// MARK: - Flow

/// Drives Unsubscribe button → confirmation dialog → confirmed action.
/// Same state machine as ArchiveConfirmationFlow: cancel mints nothing,
/// confirm-with-nothing-pending mints nothing, one confirmation mints one
/// action, and a newer request replaces the pending one.
@Observable
final class UnsubscribeConfirmationFlow {

    /// The offer the dialog is currently naming (sender, subject, and
    /// method.destinationLabel), nil when no confirmation is in flight.
    private(set) var pending: UnsubscribeOffer?

    /// Unsubscribe button tapped. Takes an OFFER, not a message — mail the
    /// eligibility rules refused cannot even reach the dialog.
    func request(_ offer: UnsubscribeOffer) {
        pending = offer
    }

    /// Dialog dismissed without confirming. Mints nothing, by design.
    func cancel() {
        pending = nil
    }

    /// The single mint site for ConfirmedUnsubscribeAction.
    func confirm(now: Date = .now) -> ConfirmedUnsubscribeAction? {
        guard let offer = pending else { return nil }
        pending = nil
        return ConfirmedUnsubscribeAction(offer, confirmedAt: now)
    }
}
