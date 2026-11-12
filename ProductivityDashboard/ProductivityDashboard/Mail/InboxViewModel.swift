// Mail/InboxViewModel.swift
//
// SwiftUI-facing state for the Inbox section. @Observable, owned by
// ContentView as @State (same pattern as CalendarViewModel). Holds:
//   - setupState: have we got credentials in Keychain?
//   - messages: last fetched batch
//   - loadError + loadErrorContext: most recent error + whether it was
//     the first load after a fresh save (drives a more specific message)
//   - isLoading: drives spinner in the section view
//
// The VM does NOT cache credentials. Keychain queries happen in two
// places: once at init (just to know if any credential exists), and
// inside IMAPMailSource.fetchRecent (which loads, uses, and drops them
// per call). saveCredentials writes to Keychain via the store and never
// holds the IMAPCredentials value past the method return.

import Foundation
import Observation
import os

struct CategorizedMessage: Identifiable, Sendable {
    let message: MailMessage
    let category: MailCategory
    var id: String { message.id }
}

/// One extracted action item, ready for the Tasks dashboard section.
struct DashboardTask: Identifiable, Equatable, Sendable {
    let id: String        // messageID + index — stable per verdict
    let title: String
    let dueHint: String?
    let sender: String    // display name or address of the asking sender
}

@Observable
final class InboxViewModel {
    enum SetupState {
        case needsCredentials
        case ready
    }

    enum LoadErrorContext {
        case freshSaveAttempt
        case steady
    }

    private let credentialsStore: CredentialsStore
    private let mailSource: MailSource
    private let fetchLimit: Int

    // Settable (not injected via init) because the SwiftData-backed cache
    // needs a ModelContext from the SwiftUI environment, which isn't
    // available at ContentView.init time. ContentView attaches the real
    // cache in its .task; until then this NoOp default just means classify
    // runs without the once-only cache (safe — local rules are deterministic).
    var classificationCache: ClassificationCaching = NoOpClassificationCache()

    // MARK: Step D5 — on-device event hints
    //
    // "This email mentions a time" marks on inbox rows, so an email that
    // proposes a meeting doesn't have to be spotted by eye. Detection is
    // Apple's NSDataDetector on this Mac over the subject and the stripped
    // body; the body is fetched, read and dropped inside the scan. Only the
    // detected start and all-day flag are kept, in memory, for this session.
    // Nothing is created, persisted or sent anywhere.
    private(set) var eventHints: [String: EventHint] = [:]
    private var eventHintScanned: Set<String> = []
    /// Bounded per pass: each fetch is its own IMAP round trip.
    static let eventHintScanLimit = 12
    /// Off in tests that isolate the cloud gate. The scan is LOCAL-only, so
    /// it is not gated by the cloud allowlist — but it does read bodies, so
    /// it must never be confused with the cloud path.
    var scansForEventHints = true

    /// Bodies fetched during the CURRENT load pass, so the cloud pass and
    /// the hint scan don't fetch the same message twice. In memory only,
    /// emptied at the end of every pass — never written to disk.
    private var passBodies: [String: String] = [:]

    // Stage 5 cloud pipeline collaborators. Same settable-var pattern and
    // same reason as classificationCache: the SwiftData-backed cache and
    // allowlist reader need the environment's ModelContext, which doesn't
    // exist at init. Every default is the fail-safe: NoOp cache (never
    // persists), EMPTY allowlist (gate blocks everything), real analyzer
    // (which itself refuses to run without a key).
    var cloudVerdictCache: CloudVerdictCaching = NoOpCloudVerdictCache()
    var allowlistReader: AllowlistReading = EmptyAllowlistReader()
    // The VIP list (Matt, 2026-10-07). Empty until ContentView attaches the
    // SwiftData reader — empty means "no VIPs", so mail just follows the
    // ordinary rules. Not a privacy boundary: VIP sends nothing anywhere.
    var vipReader: VIPReading = EmptyVIPReader()
    var cloudAnalyzer: CloudAnalyzing = ClaudeAnalyzer()

    // Stage 6 write boundary. Settable for tests (spy archiver); defaults
    // to the mail source when it can archive (IMAPMailSource does). nil —
    // e.g. a preview fake source — means the archive UI is inert: fail-safe
    // is "nothing happens", never "something happens without confirmation".
    var archiver: MailArchiving?

    // Stage 6 action log. Same settable-var pattern as the caches: the
    // SwiftData store needs the environment's ModelContext, attached by
    // ContentView's .task. The NoOp default archives without an undo trail
    // — the fail-safe direction (nothing extra persisted).
    var archiveLog: ArchiveLogRecording = NoOpArchiveLog()

    // Stage 7 unsubscribe boundary + log. Same settable-var pattern. The
    // executor accepts only ConfirmedUnsubscribeAction, so holding a real
    // one here grants nothing by itself — the dialog is still the only way
    // to mint an action. NoOp log default: nothing persists until attached.
    var unsubscriber: MailUnsubscribing = UnsubscribeExecutor()
    var unsubscribeLog: UnsubscribeLogRecording = NoOpUnsubscribeLog()

    // Status-only console markers for live verification (never content,
    // senders, or subjects — ARCHITECTURE.md Security & Privacy).
    private static let cloudLog = Logger(
        subsystem: "LuminalMachines.ProductivityDashboard",
        category: "cloud"
    )

    /// messageID → cloud verdict, for the currently displayed batch.
    private(set) var cloudVerdicts: [String: CloudVerdict] = [:]

    private(set) var setupState: SetupState
    private(set) var messages: [MailMessage] = []
    private(set) var categorized: [CategorizedMessage] = []
    private(set) var loadError: InboxError?
    private(set) var loadErrorContext: LoadErrorContext = .steady
    private(set) var isLoading: Bool = false

    // Category-filtered views for the dashboard sections. Newsletter =
    // "Unsubscribe Candidates". Scams merges the local rules verdict with
    // cloud phishing judgments. Important merges the local VIP rule with
    // the cloud's judgment; Tasks stay cloud-only.
    var newsletters: [MailMessage] {
        categorized.filter { $0.category == .newsletter }.map(\.message)
    }
    var scams: [MailMessage] {
        let local = categorized.filter { $0.category == .scam }.map(\.message)
        let localIDs = Set(local.map(\.id))
        // Cloud .phishing joins the section; .suspicious deliberately does
        // not (cry-wolf risk — THREAT_PATTERNS.md) though it still carries
        // importance/tasks like any verdict.
        let cloudPhishing = messages.filter {
            cloudVerdicts[$0.id]?.scam == .phishing && !localIDs.contains($0.id)
        }
        return local + cloudPhishing
    }
    /// VIP mail first (decided on this Mac, newest first within the group),
    /// then whatever the cloud judged important. A VIP message never needs
    /// an API call to get here.
    var important: [MailMessage] {
        let vip = categorized.filter { $0.category == .important }.map(\.message)
        let vipIDs = Set(vip.map(\.id))
        let cloudImportant = messages.filter {
            cloudVerdicts[$0.id]?.importance == .important && !vipIDs.contains($0.id)
        }
        return vip + cloudImportant
    }

    /// Re-apply the VIP list to the batch already on screen, after the user
    /// edits it. Local and instant — no fetch, no API call.
    func refreshVIPs() {
        categorized = categorize(messages)
    }

    /// Whether this message is in Important Email because its sender is a VIP.
    func isVIP(_ message: MailMessage) -> Bool {
        categorized.first { $0.id == message.id }?.category == .important
    }
    var extractedTasks: [DashboardTask] {
        messages.flatMap { message -> [DashboardTask] in
            guard let verdict = cloudVerdicts[message.id] else { return [] }
            return verdict.tasks.enumerated().map { index, task in
                DashboardTask(
                    id: "\(message.id)#\(index)",
                    title: task.title,
                    dueHint: task.dueHint,
                    sender: message.fromName ?? message.fromAddress
                )
            }
        }
    }

    // Stage 6 archive state. archivingIDs drives per-row progress;
    // archiveError is transient UI copy (an alert), cleared on dismiss.
    private(set) var archivingIDs: Set<String> = []
    private(set) var archiveError: String?

    // Stage 7 unsubscribe state, same shape as archive's.
    private(set) var unsubscribingIDs: Set<String> = []
    private(set) var unsubscribeError: String?
    /// Second dialog: a cross-site redirect awaiting approval. The VM only
    /// REQUESTS here; ContentView's dialog is the only caller of confirm().
    let redirectFlow = UnsubscribeRedirectFlow()
    /// The message whose one-click unsubscribe just failed — drives the
    /// alert's "Open in Gmail" / "Unsubscribe by Email…" choices. Cleared
    /// with the alert.
    private(set) var failedUnsubscribe: MailMessage?
    /// The Gmail account address, when the configured IMAP server is
    /// Gmail; nil otherwise (no "Open in Gmail" offered). Not a secret —
    /// the password is never read into the view model.
    // Stage 9: Gmail addresses BY accountID (empty when no Gmail account is
    // configured), and every account's display name for the row tag.
    private(set) var gmailAccounts: [String: String] = [:]
    private(set) var accountNames: [String: String] = [:]
    var webLinkOpener: WebLinkOpening = GmailLinkOpener()

    // Set true when saveCredentials lands fresh credentials in Keychain;
    // consumed by the very next load() to flavor the error message if the
    // server rejects them. Not persisted — fresh false after first load.
    private var awaitingFirstFetchAfterSave: Bool = false

    init(
        credentialsStore: CredentialsStore = KeychainCredentialsStore(),
        mailSource: MailSource? = nil,
        fetchLimit: Int = 10
    ) {
        self.credentialsStore = credentialsStore
        // Default mailSource shares the same store so credential reads at
        // fetch time hit the same Keychain entry the VM just initialized
        // against.
        // Stage 9: the default source speaks for EVERY stored account and
        // dispatches UID work by the account a message came from.
        self.mailSource = mailSource ?? MultiAccountMailSource(credentialsStore: credentialsStore)
        self.fetchLimit = fetchLimit
        self.archiver = self.mailSource as? MailArchiving

        let hasCredentials: Bool
        var gmail: [String: String] = [:]
        var names: [String: String] = [:]
        do {
            let stored = try credentialsStore.loadAll()
            hasCredentials = !stored.isEmpty
            for credentials in stored {
                names[credentials.accountID] = credentials.displayName
                // Gmail-only features (the "Open in Gmail" link) are keyed
                // per account: a Gmail link for an EarthLink message would
                // point at a mailbox that doesn't hold it.
                if GmailWebLink.isGmailServer(credentials.server) {
                    gmail[credentials.accountID] = credentials.account
                }
            }
        } catch {
            // Treat a Keychain read failure as "not configured" — better
            // to make the user re-enter than to claim ready and fail at
            // every fetch. Surface via loadError on first interaction.
            hasCredentials = false
        }
        self.setupState = hasCredentials ? .ready : .needsCredentials
        self.gmailAccounts = gmail
        self.accountNames = names
    }

    /// Re-read the account list after Settings adds or removes one.
    func refreshAccounts() {
        var gmail: [String: String] = [:]
        var names: [String: String] = [:]
        let stored = (try? credentialsStore.loadAll()) ?? []
        for credentials in stored {
            names[credentials.accountID] = credentials.displayName
            if GmailWebLink.isGmailServer(credentials.server) {
                gmail[credentials.accountID] = credentials.account
            }
        }
        gmailAccounts = gmail
        accountNames = names
        setupState = stored.isEmpty ? .needsCredentials : .ready
    }

    /// What a row's account tag shows; nil when there is nothing to
    /// disambiguate (one account) or the message carries no stamp.
    ///
    /// Short form on purpose: the full address crowds the row, and the
    /// local part plus provider ("pat · mindspring") is already
    /// unambiguous for any realistic set of accounts. The full address is
    /// one hover away, and lives in Settings ▸ Accounts.
    func accountTag(for message: MailMessage) -> String? {
        guard accountNames.count > 1, let id = message.accountID,
              let address = accountNames[id] else { return nil }
        return Self.shortTag(for: address)
    }

    nonisolated static func shortTag(for address: String) -> String {
        let parts = address.split(separator: "@")
        guard parts.count == 2 else { return address }
        let local = String(parts[0])
        let host = parts[1].split(separator: ".").first.map(String.init) ?? String(parts[1])
        return "\(local) · \(host)"
    }

    // Message the InboxSection should display. Default to InboxError's
    // user-facing copy, but special-case .loginFailed on the very first
    // load after a save: in that context the user just typed credentials,
    // so "double-check your app-specific password" is more useful than
    // the generic steady-state message.
    var loadErrorDisplay: String? {
        guard let err = loadError else { return nil }
        if err == .loginFailed && loadErrorContext == .freshSaveAttempt {
            return "These credentials were rejected by the server. " +
                "Double-check your app-specific password, then try again via Reconfigure."
        }
        return err.userMessage
    }

    // MARK: - Stage 6 archive

    /// Execute one user-confirmed archive. The parameter type IS the
    /// security property: only ArchiveConfirmationFlow.confirm() can mint
    /// a ConfirmedArchiveAction, so there is no path into this method —
    /// and none into the IMAP write below it — that skips the dialog.
    /// On success the message leaves the local batch immediately (it is no
    /// longer in INBOX); on failure it stays and the user sees why. The
    /// receipt's undo handle is consumed by the Step D action log.
    func archive(_ action: ConfirmedArchiveAction) async {
        guard let archiver else {
            archiveError = InboxError.archiveFailed.userMessage
            return
        }
        let id = action.message.id
        guard !archivingIDs.contains(id) else { return }
        archivingIDs.insert(id)
        defer { archivingIDs.remove(id) }

        do {
            let receipt = try await archiver.archive(action)
            // Log BEFORE mutating local state: the receipt is the undo
            // handle, and a lost row costs the one-click undo.
            archiveLog.record(
                messageID: receipt.messageID,
                senderAddress: action.message.fromAddress,
                archivedTo: receipt.archivedTo,
                newUID: receipt.newUID,
                accountID: action.message.accountID,
                at: action.confirmedAt)
            messages.removeAll { $0.id == id }
            categorized.removeAll { $0.id == id }
        } catch let err as InboxError {
            archiveError = err.userMessage
        } catch {
            archiveError = InboxError.archiveFailed.userMessage
        }
    }

    /// Undo one logged archive: reverse the move, close the log entry, and
    /// reload so the message reappears in the inbox. On failure the entry
    /// stays open (undo can be retried) and the user sees why. A nil handle
    /// can't be undone in one click — the message is still in the archive
    /// mailbox; say so instead of guessing.
    func undoArchive(messageID: String, newUID: UInt32?, archivedTo: String,
                     accountID: String? = nil) async {
        guard let archiver else {
            archiveError = InboxError.archiveFailed.userMessage
            return
        }
        guard let newUID else {
            archiveError = "This one can't be undone in one click — the mail server didn't report where the message went. It's still in \(archivedTo)."
            return
        }
        guard !archivingIDs.contains(messageID) else { return }
        archivingIDs.insert(messageID)
        defer { archivingIDs.remove(messageID) }

        do {
            try await archiver.unarchive(accountID: accountID, newUID: newUID, from: archivedTo)
            archiveLog.markUndone(messageID: messageID, at: .now)
            await load()
        } catch InboxError.archiveFailed {
            // archiveFailed's stock copy says "still in your inbox" — wrong
            // direction for a failed UNDO. The truthful statement:
            archiveError = "Couldn't undo — the message may have been moved by another mail client. It's still in \(archivedTo)."
        } catch let err as InboxError {
            archiveError = err.userMessage
        } catch {
            archiveError = "Couldn't undo the archive. The message is still in \(archivedTo)."
        }
    }

    func dismissArchiveError() {
        archiveError = nil
    }

    // MARK: - Stage 7 unsubscribe

    /// The eligibility decision for a message in the current batch, using
    /// its LOCAL category and (if any) cloud verdict — the cloud can only
    /// block. The UnsubscribeOffer inside an .offer can only come from
    /// UnsubscribeEligibility; this just supplies its inputs.
    func unsubscribeDecision(for message: MailMessage) -> UnsubscribeEligibility.Decision {
        let category = categorized.first { $0.id == message.id }?.category
        return UnsubscribeEligibility.evaluate(
            message, localCategory: category, cloudVerdict: cloudVerdicts[message.id])
    }

    /// Execute one user-confirmed unsubscribe. The parameter type is the
    /// security property (only the dialog's confirm() mints one). The
    /// message stays in the inbox either way — archiving is a separate,
    /// separately confirmed action.
    func unsubscribe(_ action: ConfirmedUnsubscribeAction) async {
        let id = action.message.id
        guard !unsubscribingIDs.contains(id) else { return }
        unsubscribingIDs.insert(id)
        defer { unsubscribingIDs.remove(id) }

        do {
            let outcome = try await unsubscriber.unsubscribe(action)
            if case .redirectNeedsApproval(let pending) = outcome {
                redirectFlow.request(pending)   // ask; nothing logged yet
                return
            }
            unsubscribeLog.record(messageID: id,
                                  senderAddress: action.message.fromAddress,
                                  outcome: outcome,
                                  at: action.confirmedAt)
        } catch let error as UnsubscribeError {
            unsubscribeError = error.userMessage
            if case .oneClick = action.method { failedUnsubscribe = action.message }
        } catch {
            unsubscribeError = UnsubscribeError.networkFailure.userMessage
            if case .oneClick = action.method { failedUnsubscribe = action.message }
        }
    }

    /// Execute one user-approved cross-site redirect (second dialog).
    func followRedirect(_ redirect: ConfirmedUnsubscribeRedirect) async {
        let id = redirect.message.id
        guard !unsubscribingIDs.contains(id) else { return }
        unsubscribingIDs.insert(id)
        defer { unsubscribingIDs.remove(id) }

        do {
            let outcome = try await unsubscriber.followRedirect(redirect)
            unsubscribeLog.record(messageID: id,
                                  senderAddress: redirect.message.fromAddress,
                                  outcome: outcome,
                                  at: redirect.confirmedAt)
        } catch let error as UnsubscribeError {
            unsubscribeError = error.userMessage
            failedUnsubscribe = redirect.message
        } catch {
            unsubscribeError = UnsubscribeError.networkFailure.userMessage
            failedUnsubscribe = redirect.message
        }
    }

    // MARK: - Step D5 event hints

    /// Scan the newest eligible messages for a date/time, on this Mac.
    /// Skips anything "Make Event from Email…" would refuse (scam, cloud
    /// phishing/suspicious, trusted dmarc=fail), anything already scanned
    /// this session, and messages with no IMAP UID (those retry on a later
    /// poll). A failed body fetch still scans the subject.
    func scanForEventHints() async {
        guard scansForEventHints else { return }
        let meals = MealPreferences.load()
        var scanned = 0
        for item in categorized {
            if scanned >= Self.eventHintScanLimit { break }
            // Newsletters and scam mail are not where meetings get proposed,
            // and scanning them would mean reading marketing bodies for no
            // reason. Personal and important mail only.
            guard item.category == .other || item.category == .important else { continue }
            let message = item.message
            if eventHintScanned.contains(message.id) { continue }
            let verdict = cloudVerdicts[message.id]
            guard EventSuggester.refusal(localCategory: item.category, cloudVerdict: verdict,
                                         authentication: message.authentication) == nil else {
                eventHintScanned.insert(message.id)
                continue
            }
            guard let uid = message.imapUID else { continue }
            eventHintScanned.insert(message.id)
            scanned += 1

            var body = passBodies[message.id]
            if body == nil {
                body = (try? await mailSource.fetchBody(accountID: message.accountID, imapUID: uid)) ?? nil
                if let body { passBodies[message.id] = body }
            }
            let result = EventSuggester.suggest(for: message, body: body, localCategory: item.category,
                                                cloudVerdict: verdict, defaultCalendarID: nil, meals: meals)
            guard case .suggestion(let values, let dateFound, _) = result,
                  dateFound, let start = values.start else { continue }
            eventHints[message.id] = EventHint(start: start, isAllDay: values.isAllDay)
        }
    }

    // MARK: - Stage 8 "Make Event from Email…"

    /// Whether the row may offer "Make Event from Email…" (never for local
    /// scam, cloud phishing/suspicious or trusted dmarc=fail mail).
    func canSuggestEvent(for message: MailMessage) -> Bool {
        let category = categorized.first { $0.id == message.id }?.category
        return EventSuggester.refusal(localCategory: category, cloudVerdict: cloudVerdicts[message.id],
                                      authentication: message.authentication) == nil
    }

    /// On-device suggestion for the New Event form. The body is fetched
    /// over the existing local IMAP connection ONLY when the message isn't
    /// refused; nothing is sent to the Claude API.
    func eventSuggestion(for message: MailMessage, defaultCalendarID: String?) async -> EventSuggestionResult {
        let category = categorized.first { $0.id == message.id }?.category
        let verdict = cloudVerdicts[message.id]
        if let reason = EventSuggester.refusal(localCategory: category, cloudVerdict: verdict,
                                               authentication: message.authentication) {
            return .refused(reason)
        }
        var body: String?
        if let uid = message.imapUID {
            body = (try? await mailSource.fetchBody(accountID: message.accountID, imapUID: uid)) ?? nil
        }
        return EventSuggester.suggest(for: message, body: body, localCategory: category,
                                      cloudVerdict: verdict, defaultCalendarID: defaultCalendarID,
                                      meals: MealPreferences.load())
    }

    // MARK: - Triage agent body read

    /// The triage agent's only way to a message body (Agent/AgentWorkspace).
    /// The parameter type is the gate, exactly as for ClaudeAnalyzer: a
    /// CloudEligibleMessage exists only by surviving CloudAllowlist.filter,
    /// so a non-allowlisted body cannot be requested through here. The raw
    /// body is returned to the workspace, which strips and caps it before
    /// anything is sent; nothing is kept.
    func bodyForAgent(_ eligible: CloudEligibleMessage) async -> String? {
        guard let uid = eligible.message.imapUID else { return nil }
        return (try? await mailSource.fetchBody(accountID: eligible.message.accountID,
                                                imapUID: uid)) ?? nil
    }

    func dismissUnsubscribeError() {
        unsubscribeError = nil
        failedUnsubscribe = nil
    }

    /// Email fallback after a failed one-click, via the eligibility gate.
    func mailtoFallbackOffer(for message: MailMessage) -> UnsubscribeOffer? {
        let category = categorized.first { $0.id == message.id }?.category
        return UnsubscribeEligibility.mailtoFallbackOffer(
            for: message, localCategory: category, cloudVerdict: cloudVerdicts[message.id])
    }

    /// Link to this message in Gmail (Gmail accounts only).
    func gmailLink(for message: MailMessage) -> URL? {
        // Only for a message that came FROM a Gmail account: a Gmail search
        // link for EarthLink mail would open a mailbox that never had it.
        // With exactly one account and no stamp (previews, old rows), fall
        // back to that account.
        let id = message.accountID ?? (gmailAccounts.count == 1 ? gmailAccounts.keys.first : nil)
        guard let id, let address = gmailAccounts[id] else { return nil }
        return GmailWebLink.url(forMessageID: message.id, account: address)
    }

    /// Open the message in Gmail and record the choice, so the row shows
    /// "Unsubscribed in Gmail" and doesn't invite a repeat.
    func openInGmail(_ message: MailMessage) {
        guard let url = gmailLink(for: message) else { return }
        webLinkOpener.open(url)
        unsubscribeLog.recordGmailHandoff(messageID: message.id,
                                          senderAddress: message.fromAddress,
                                          at: .now)
    }

    func load() async {
        // Accounts can be added or removed in Settings, which is a separate
        // scene with its own environment; re-reading the list here is what
        // makes those changes show up — on the next refresh or poll.
        refreshAccounts()
        guard setupState == .ready else { return }
        // Re-entrancy guard: the manual refresh button, the 5-minute loop,
        // and the post-save load can all fire; without this, two fetches
        // race and the last writer wins on `messages`. If a load is skipped
        // here, awaitingFirstFetchAfterSave stays set and flavors the next
        // load that actually runs.
        if isLoading { return }

        // Capture the fresh-save context BEFORE the await so the flag is
        // consumed exactly once even if multiple loads race.
        let context: LoadErrorContext = awaitingFirstFetchAfterSave ? .freshSaveAttempt : .steady
        awaitingFirstFetchAfterSave = false

        isLoading = true
        loadError = nil
        loadErrorContext = .steady

        do {
            let fetched = try await mailSource.fetchRecent(limit: fetchLimit)
            messages = fetched
            categorized = categorize(fetched)
        } catch let err as InboxError {
            loadError = err
            loadErrorContext = context
        } catch {
            loadError = .unexpectedResponse
            loadErrorContext = context
        }

        // Inbox is usable now; cloud analysis trails behind without holding
        // the spinner (it can involve per-message body fetches + API calls).
        isLoading = false
        await runCloudAnalysis()
        await scanForEventHints()
        passBodies.removeAll()
    }

    // The Stage 5 funnel, in privacy order: local verdict .other (cloud is a
    // second opinion on the residue only) → THE GATE (CloudAllowlist.filter;
    // after this line every message is CloudEligibleMessage, the only type
    // the analyzer accepts) → analyze-once cache → lazy body fetch → API.
    // Every failure mode keeps the local verdict: terminal ones (no text
    // part, refused, undecodable) are cached as .skipped so they never
    // re-spend; transient ones (network, rate limit, no key) stay uncached
    // and may retry on a future poll. Nothing here ever retries in a loop.
    private func runCloudAnalysis() async {
        guard cloudAnalyzer.isConfigured() else { return }

        // .important here means "VIP" (the local rule). VIP mail stays in
        // the candidate set so an allowlisted VIP still gets tasks and the
        // scam second opinion — but it reaches the API only by passing the
        // SAME allowlist gate as everything else. Being a VIP grants no
        // cloud eligibility (Matt, 2026-10-07).
        let ambiguous = categorized
            .filter { $0.category == .other || $0.category == .important }
            .map(\.message)
        let eligible = CloudAllowlist.filter(ambiguous, using: allowlistReader)
        Self.cloudLog.info("cloud pass: \(ambiguous.count, privacy: .public) ambiguous, \(eligible.count, privacy: .public) allowlisted")

        analysisLoop: for item in eligible {
            let id = item.message.id
            guard cloudVerdictCache.outcome(forMessageID: id) == nil else { continue }
            guard let uid = item.message.imapUID else { continue } // non-IMAP source; retry later

            do {
                let fetched: String?
                if let cached = passBodies[id] {
                    fetched = cached
                } else {
                    fetched = try await mailSource.fetchBody(accountID: item.message.accountID, imapUID: uid)
                }
                guard let body = fetched else {
                    Self.cloudLog.info("no text part — skipped permanently")
                    cloudVerdictCache.store(.skipped, forMessageID: id)
                    continue
                }
                passBodies[id] = body
                let verdict = try await cloudAnalyzer.analyze(item, rawBody: body)
                Self.cloudLog.info("verdict: \(verdict.importance.rawValue, privacy: .public)/\(verdict.scam.rawValue, privacy: .public), \(verdict.tasks.count, privacy: .public) task(s)")
                cloudVerdictCache.store(.verdict(verdict), forMessageID: id)
            } catch let error as CloudAnalysisError {
                switch error {
                case .refused, .invalidResponse, .invalidRequest:
                    // Terminal for this message — cache so we never re-spend.
                    Self.cloudLog.error("analysis terminal failure (\(String(describing: error), privacy: .public)) — skipped permanently")
                    cloudVerdictCache.store(.skipped, forMessageID: id)
                case .notConfigured, .authenticationFailed, .rateLimited,
                     .serverError, .networkFailure:
                    // Transient or account-level: leave uncached for a
                    // future poll, and stop this pass — the same condition
                    // would fail every remaining message too.
                    Self.cloudLog.error("analysis transient failure (\(String(describing: error), privacy: .public)) — will retry on a later poll")
                    break analysisLoop
                }
            } catch {
                // IMAP body-fetch failure: transient, retry on a later poll.
                Self.cloudLog.error("body fetch failed — will retry on a later poll")
                continue
            }
        }

        // Publish verdicts for the displayed batch (cache hits included, so
        // verdicts survive restarts without re-analysis).
        var verdicts: [String: CloudVerdict] = [:]
        for message in messages {
            if case .verdict(let verdict) = cloudVerdictCache.outcome(forMessageID: message.id) {
                verdicts[message.id] = verdict
            }
        }
        cloudVerdicts = verdicts
    }

    // Classify each message, using the cache to classify-once: a cache hit
    // reuses the first-arrival verdict, a miss runs the local rules engine
    // and stores the result. Pure/local — no network, no allowlist. Runs on
    // MainActor after the fetch returns; ~10 messages is trivial.
    private func categorize(_ messages: [MailMessage]) -> [CategorizedMessage] {
        let vips = vipReader.vipSenders()
        return messages.map { message in
            let category: MailCategory
            if let cached = classificationCache.category(forMessageID: message.id) {
                category = cached
            } else {
                category = LocalRulesEngine.classify(message)
                classificationCache.store(category: category, forMessageID: message.id)
            }
            // The VIP overlay is applied AFTER the cache, never into it:
            // the cache holds what the rules say about the message, while
            // VIP is a fact about the sender that the user can change at
            // any time. Overlaying keeps edits to the VIP list immediate
            // and leaves no stale .important rows behind in storage.
            // Scam wins over VIP — see LocalRulesEngine.classify(_:vipSenders:).
            let final: MailCategory = (category != .scam
                                       && LocalRulesEngine.isVIP(message, vipSenders: vips))
                ? .important : category
            return CategorizedMessage(message: message, category: final)
        }
    }

    func saveCredentials(_ credentials: IMAPCredentials) async {
        do {
            try credentialsStore.save(credentials)
            refreshAccounts()
            messages = []
            categorized = []
            loadError = nil
            loadErrorContext = .steady
            awaitingFirstFetchAfterSave = true
            setupState = .ready
        } catch {
            // Keychain write failed. setupState stays .needsCredentials,
            // so this error must render in the section's not-configured
            // branch (see InboxSection) — otherwise the sheet dismisses
            // and the failure is invisible.
            loadError = .credentialsSaveFailed
            loadErrorContext = .steady
            return
        }
        // Drive the post-save refresh from here rather than from a
        // .onChange(setupState) observer. Reconfigure-with-save is a
        // .ready → .ready transition, which onChange does not fire on,
        // so we'd silently skip the follow-up fetch.
        await load()
    }
}
