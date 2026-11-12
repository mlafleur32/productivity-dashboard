//
//  ContentView.swift
//  ProductivityDashboard
//
//  Created by Matt Lafleur on 5/28/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var calendar: CalendarViewModel
    @State private var inbox: InboxViewModel
    @State private var showSetup: Bool = false
    // Triage agent (portfolio step 2). It only produces a plan; the rows of
    // that plan are acted on below, through the same flows the message rows
    // use. Calendar titles are shared with it only if this is switched on.
    @State private var agent = TriageAgent()
    @AppStorage("agentSharesCalendarTitles") private var agentSharesCalendarTitles = false

    // Live view of the cloud allowlist, driving the ☁ badges and the
    // state-aware context menus. @Query keeps it current when Settings or a
    // context-menu action mutates the store.
    @Query(filter: #Predicate<AllowedSender> { $0.cloudEligible })
    private var eligibleSenders: [AllowedSender]
    @State private var promotionFlow = PromotionFlow()
    @State private var allowlistError: String?
    // Stage 6: the archive confirmation gate's UI half. The dialog below is
    // the only caller of archiveFlow.confirm() — the app's single mint site
    // for ConfirmedArchiveAction.
    @State private var archiveFlow = ArchiveConfirmationFlow()
    // Stage 7: the unsubscribe gate's UI half. The dialog below is the only
    // caller of unsubscribeFlow.confirm() — the single mint site for
    // ConfirmedUnsubscribeAction.
    @State private var unsubscribeFlow = UnsubscribeConfirmationFlow()
    // Stage 8: calendar writes. The New Event sheet edits values; its
    // Review… hands a validated draft to createEventFlow; the dialog below is
    // the only caller of createEventFlow.confirm().
    @State private var calendarActions: CalendarActionService
    @State private var createEventFlow = CreateEventConfirmationFlow()
    @State private var eventFormRequest: EventFormRequest?
    @State private var eventFormCalendars: [WritableCalendar] = []
    // The privacy-minimal unsubscribe log (no URLs), driving row state.
    @Query(sort: \UnsubscribeLogEntry.timestamp, order: .reverse)
    private var unsubscribeEntries: [UnsubscribeLogEntry]
    // Step D6: events this app created and hasn't undone. The log itself
    // stores no times, so the times come back LIVE from EventKit by
    // identifier — an event moved or deleted elsewhere stops matching on
    // its own, which is the behavior we want.
    @Query(filter: #Predicate<CalendarActionLogEntry> { $0.undoneAt == nil })
    private var openCalendarEntries: [CalendarActionLogEntry]

    private var createdEventTimes: CreatedEventTimes {
        var times = CreatedEventTimes()
        for entry in openCalendarEntries {
            guard let summary = calendarActions.summary(eventIdentifier: entry.eventIdentifier) else { continue }
            times.insert(start: summary.start, isAllDay: summary.isAllDay)
        }
        return times
    }

    // senderIdentifier is normalized at write time; rows normalize their
    // fromAddress before membership checks so casing can't desync the badge
    // from the gate.
    private var cloudEligibleSet: Set<String> {
        Set(eligibleSenders.map(\.senderIdentifier))
    }

    // Injection points exist for previews and future tests; the app's
    // entry point uses the real defaults.
    init(
        calendar: CalendarViewModel = CalendarViewModel(),
        inbox: InboxViewModel = InboxViewModel(),
        calendarActions: CalendarActionService? = nil
    ) {
        _calendar = State(initialValue: calendar)
        _inbox = State(initialValue: inbox)
        // Optional default, same reason as CalendarActionService's own init:
        // default-argument expressions are evaluated outside the main actor.
        _calendarActions = State(initialValue: calendarActions ?? CalendarActionService())
    }

    var body: some View {
        NavigationSplitView {
            List {
                Label("Important Email", systemImage: "envelope.badge")
                Label("Unsubscribe", systemImage: "minus.circle")
                Label("Scams & Phishing", systemImage: "exclamationmark.shield")
                Label("Calendar", systemImage: "calendar")
                Label("Tasks", systemImage: "checklist")
            }
            .navigationTitle("Dashboard")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    AgentSection(agent: agent, isDemo: DemoMode.isActive,
                                 sharesCalendarTitles: $agentSharesCalendarTitles,
                                 onRun: runAgent,
                                 status: agentStatus(for:),
                                 onAct: actOnAgentProposal)
                    InboxSection(viewModel: inbox, showSetup: $showSetup,
                                 cloudEligible: cloudEligibleSet,
                                 onPromote: promotionFlow.request,
                                 onDemote: demote,
                                 onArchive: archiveFlow.request,
                                 archivingIDs: inbox.archivingIDs,
                                 canMakeEvent: inbox.canSuggestEvent(for:),
                                 onMakeEvent: openSuggestedEventForm,
                                 eventHint: { inbox.eventHints[$0.id] },
                                 createdEventTimes: createdEventTimes,
                                 isVIP: inbox.isVIP(_:),
                                 onToggleVIP: toggleVIP,
                                 accountTag: inbox.accountTag(for:))
                    CategoryMailSection(
                        title: "Important Email",
                        messages: inbox.important,
                        emptyText: "Nothing important right now. Mail from your VIPs always lands here; other mail is judged by cloud analysis, for allowlisted senders only.",
                        cloudEligible: cloudEligibleSet,
                        onPromote: promotionFlow.request,
                        onDemote: demote,
                        onArchive: archiveFlow.request,
                        archivingIDs: inbox.archivingIDs,
                        canMakeEvent: inbox.canSuggestEvent(for:),
                        onMakeEvent: openSuggestedEventForm,
                        eventHint: { inbox.eventHints[$0.id] },
                        createdEventTimes: createdEventTimes,
                        isVIP: inbox.isVIP(_:),
                        onToggleVIP: toggleVIP,
                        accountTag: inbox.accountTag(for:))
                    CategoryMailSection(
                        title: "Unsubscribe Candidates",
                        messages: inbox.newsletters,
                        emptyText: "No newsletters detected in recent mail.",
                        cloudEligible: cloudEligibleSet,
                        onPromote: promotionFlow.request,
                        onDemote: demote,
                        onArchive: archiveFlow.request,
                        archivingIDs: inbox.archivingIDs,
                        unsubscribeState: unsubscribeState(for:),
                        onUnsubscribe: unsubscribeFlow.request,
                        unsubscribingIDs: inbox.unsubscribingIDs,
                        onOpenInGmail: inbox.openInGmail,
                        accountTag: inbox.accountTag(for:))
                    CategoryMailSection(
                        title: "Scams & Phishing",
                        messages: inbox.scams,
                        emptyText: "Nothing suspicious detected in recent mail.",
                        cloudEligible: cloudEligibleSet,
                        onPromote: promotionFlow.request,
                        onDemote: demote,
                        onArchive: archiveFlow.request,
                        archivingIDs: inbox.archivingIDs,
                        accountTag: inbox.accountTag(for:))
                    UpcomingCalendarSection(viewModel: calendar, onNewEvent: openBlankEventForm)
                    RecentlyCreatedEventsSection(
                        summary: calendarActions.summary(eventIdentifier:),
                        isWorking: calendarActions.isWorking,
                        onUndo: { id in
                            Task {
                                _ = await calendarActions.undoCreate(eventIdentifier: id)
                                await calendar.load()
                            }
                        })
                    TasksSection(tasks: inbox.extractedTasks)
                    RecentArchivesSection(
                        archivingIDs: inbox.archivingIDs,
                        onUndo: { entry in
                            Task {
                                await inbox.undoArchive(
                                    messageID: entry.messageID,
                                    newUID: entry.newUID.map(UInt32.init),
                                    archivedTo: entry.archivedTo,
                                    accountID: entry.accountID)
                            }
                        })
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(DemoMode.isActive ? "My Dashboard — Demo Data" : "My Dashboard")
            .task { await calendar.load() }
            // Inbox refresh loop — attached to ScrollView (not InboxSection)
            // because ScrollView's lifetime is the durable detail-pane
            // lifetime. SwiftUI's behavior for tasks on scrolled-off-screen
            // views inside a ScrollView is implementation-dependent; hosting
            // the loop here removes that uncertainty. The loop only calls
            // load() when setupState == .ready so no-op fetches don't fire
            // before credentials exist.
            .task {
                // Attach the SwiftData-backed classification cache now that
                // the environment's ModelContext is available (it isn't at
                // ContentView.init). Enables classify-once persistence; until
                // this runs the VM uses the NoOp cache (still correct, just
                // not cached).
                inbox.classificationCache = SwiftDataClassificationCache(context: modelContext)
                // Stage 5 cloud pipeline: analyze-once verdict cache and the
                // REAL allowlist reader. Until these attach, the VM's
                // fail-safe defaults hold (empty allowlist — gate blocks
                // everything; NoOp cache — nothing persists).
                inbox.cloudVerdictCache = SwiftDataCloudVerdictCache(context: modelContext)
                inbox.allowlistReader = SwiftDataAllowlistReader(context: modelContext)
                // The VIP list (local importance rule). Until attached, the
                // empty default means "no VIPs" — mail just follows the
                // ordinary rules.
                inbox.vipReader = SwiftDataVIPReader(context: modelContext)
                // Stage 6: the action log (undo trail). Until attached, the
                // NoOp default archives without a trail — fail-safe.
                inbox.archiveLog = SwiftDataArchiveLog(context: modelContext)
                // Stage 7: the unsubscribe log. NoOp until attached.
                inbox.unsubscribeLog = SwiftDataUnsubscribeLog(context: modelContext)
                // Stage 8: the calendar action log (undo trail).
                calendarActions.log = SwiftDataCalendarActionLog(context: modelContext)
                while !Task.isCancelled {
                    if inbox.setupState == .ready {
                        await inbox.load()
                    }
                    try? await Task.sleep(for: .seconds(300))
                }
            }
            // Stage 8 presentation lives in its own modifier: adding it inline
            // pushed this body past the compiler's type-check time limit.
            .modifier(CreateEventPresentation(
                eventFormRequest: $eventFormRequest,
                eventSuggestionRefusal: $eventSuggestionRefusal,
                eventFormCalendars: eventFormCalendars,
                createEventFlow: createEventFlow,
                calendarActions: calendarActions,
                calendar: calendar))
            .sheet(isPresented: $showSetup) {
                InboxSetupSheet(
                    onSave: { creds in
                        Task { await inbox.saveCredentials(creds) }
                        showSetup = false
                    },
                    onCancel: {
                        showSetup = false
                    }
                )
            }
            // Confirm-on-promote: the one click that WIDENS the privacy
            // boundary gets a ceremony; demote stays one-click. Dismissing
            // by any route (Cancel, Esc, click-away) flips isPresented false,
            // which routes to cancel() — writing nothing (see PromotionFlow
            // and its cancelled-dialog test).
            .confirmationDialog(
                "Allow cloud analysis?",
                isPresented: Binding(
                    get: { promotionFlow.pendingAddress != nil },
                    set: { if !$0 { promotionFlow.cancel() } }
                ),
                titleVisibility: .visible,
                presenting: promotionFlow.pendingAddress
            ) { address in
                Button("Allow \(address)") {
                    mutateAllowlist("Couldn't promote the sender") {
                        try promotionFlow.confirm(
                            address,
                            using: AllowlistEditor(context: modelContext))
                    }
                }
                Button("Cancel", role: .cancel) {
                    promotionFlow.cancel()
                }
            } message: { address in
                Text("Mail from \(address) may be sent to the Claude API for analysis. All other senders stay on this Mac. You can turn this off anytime in Settings or by right-clicking a message.")
            }
            .alert(
                "Allowlist error",
                isPresented: Binding(
                    get: { allowlistError != nil },
                    set: { if !$0 { allowlistError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(allowlistError ?? "")
            }
            // Stage 6 per-action confirmation (ARCHITECTURE.md Security item 6).
            // Same ceremony shape as promote: any dismissal that isn't the
            // Archive button routes to cancel(), which mints nothing. The
            // Archive button is the app's ONLY call to archiveFlow.confirm()
            // — the single place a ConfirmedArchiveAction can come to exist.
            .confirmationDialog(
                "Archive this message?",
                isPresented: Binding(
                    get: { archiveFlow.pending != nil },
                    set: { if !$0 { archiveFlow.cancel() } }
                ),
                titleVisibility: .visible,
                presenting: archiveFlow.pending
            ) { message in
                Button("Archive") {
                    if let action = archiveFlow.confirm() {
                        Task { await inbox.archive(action) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    archiveFlow.cancel()
                }
            } message: { message in
                // Names the exact message: the user confirms what they read.
                Text("From \(message.fromName ?? message.fromAddress)\n“\(message.subject)”\n\nIt will move out of your inbox. In Gmail you'll still find it under All Mail.")
            }
            .alert(
                "Archive failed",
                isPresented: Binding(
                    get: { inbox.archiveError != nil },
                    set: { if !$0 { inbox.dismissArchiveError() } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(inbox.archiveError ?? "")
            }
            // Stage 7 per-action confirmation. Presents only an
            // UnsubscribeOffer (mintable only by the eligibility rules); any
            // dismissal but the confirm button routes to cancel(), which
            // mints nothing. The confirm button is the app's ONLY call to
            // unsubscribeFlow.confirm().
            .confirmationDialog(
                "Unsubscribe from this sender?",
                isPresented: Binding(
                    get: { unsubscribeFlow.pending != nil },
                    set: { if !$0 { unsubscribeFlow.cancel() } }
                ),
                titleVisibility: .visible,
                presenting: unsubscribeFlow.pending
            ) { offer in
                Button(UnsubscribeDialogCopy.confirmTitle(offer.method)) {
                    if let action = unsubscribeFlow.confirm() {
                        Task { await inbox.unsubscribe(action) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    unsubscribeFlow.cancel()
                }
            } message: { offer in
                Text(UnsubscribeDialogCopy.message(offer))
            }
            // Second confirmation (settled 2026-09-16): the sender's server
            // handed the request to a different company. Nothing further is
            // sent unless the user approves the NEW host here. The confirm
            // button is the app's only call to redirectFlow.confirm().
            .confirmationDialog(
                "Send your unsubscribe to another company?",
                isPresented: Binding(
                    get: { inbox.redirectFlow.pending != nil },
                    set: { if !$0 { inbox.redirectFlow.cancel() } }
                ),
                titleVisibility: .visible,
                presenting: inbox.redirectFlow.pending
            ) { pending in
                Button("Send to \(pending.targetHost)") {
                    if let redirect = inbox.redirectFlow.confirm() {
                        Task { await inbox.followRedirect(redirect) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    inbox.redirectFlow.cancel()
                }
            } message: { pending in
                Text(UnsubscribeDialogCopy.redirectMessage(pending))
            }
            .alert(
                "Unsubscribe didn't complete",
                isPresented: Binding(
                    get: { inbox.unsubscribeError != nil },
                    set: { if !$0 { inbox.dismissUnsubscribeError() } }
                )
            ) {
                // Choices after a failed one-click (settled 2026-09-16).
                // Email goes back through the normal confirmation dialog.
                if let failed = inbox.failedUnsubscribe {
                    if inbox.gmailLink(for: failed) != nil {
                        Button("Open in Gmail") { inbox.openInGmail(failed) }
                    }
                    if let fallback = inbox.mailtoFallbackOffer(for: failed) {
                        Button("Unsubscribe by Email…") {
                            Task {
                                // Let the alert finish dismissing first.
                                try? await Task.sleep(for: .milliseconds(350))
                                unsubscribeFlow.request(fallback)
                            }
                        }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(inbox.unsubscribeError ?? "")
            }
        }
    }

    // Row state for the Unsubscribe Candidates section. A one-click
    // success for this sender wins ("Unsubscribed"); otherwise the
    // eligibility decision decides between a button, the "archive instead"
    // hint, or nothing. A previously opened mailto draft keeps the button
    // (the user may not have sent it) with a small note.
    private func unsubscribeState(for message: MailMessage) -> UnsubscribeRowState {
        let sender = AllowedSender.normalize(message.fromAddress)
        // unsubscribeEntries is newest-first, so this is the latest choice.
        let latest = unsubscribeEntries
            .first { $0.senderAddress == sender }
            .flatMap { UnsubscribeLogOutcome(rawValue: $0.outcome) }
        return UnsubscribeRowState.resolve(
            latestOutcome: latest,
            decision: inbox.unsubscribeDecision(for: message),
            canOpenInGmail: inbox.gmailLink(for: message) != nil)
    }

    @State private var eventSuggestionRefusal: String?

    private func openBlankEventForm() {
        eventFormCalendars = calendarActions.writableCalendars()
        eventFormRequest = EventFormRequest(
            values: NewEventFormValues(calendarID: calendarActions.defaultCalendarID()),
            dateFound: true)
    }

    private func openSuggestedEventForm(_ message: MailMessage) {
        Task {
            eventFormCalendars = calendarActions.writableCalendars()
            let result = await inbox.eventSuggestion(for: message,
                                                     defaultCalendarID: calendarActions.defaultCalendarID())
            switch result {
            case .suggestion(var values, let dateFound, let notice):
                values.emailReference = EmailReference(
                    messageID: message.id,
                    sender: message.fromName ?? message.fromAddress,
                    subject: message.subject,
                    gmailLink: inbox.gmailLink(for: message))
                eventFormRequest = EventFormRequest(values: values, dateFound: dateFound, notice: notice)
            case .refused:
                eventSuggestionRefusal = "Events aren't suggested from messages flagged as scams, suspicious, or failing sender checks."
            }
        }
    }

    // MARK: - Triage agent

    /// Start one agent run over a snapshot of what the dashboard shows now.
    /// The allowlist reader is the SAME one the cloud pipeline's gate uses.
    private func runAgent(_ request: String) {
        let context = AgentContext(
            messages: inbox.categorized,
            allowlist: inbox.allowlistReader,
            cloudVerdicts: inbox.cloudVerdicts,
            eventHintIDs: Set(inbox.eventHints.keys),
            unsubscribedSenders: Set(unsubscribeEntries.map(\.senderAddress)),
            events: calendar.events,
            sharesCalendarTitles: DemoMode.isActive || agentSharesCalendarTitles,
            fetchBody: { [inbox] eligible in await inbox.bodyForAgent(eligible) })
        Task { await agent.run(request: request, context: context) }
    }

    /// What a plan row offers, from the same state the message rows read.
    private func agentStatus(for proposal: AgentProposal) -> AgentProposalStatus {
        let message = proposal.message
        guard inbox.messages.contains(where: { $0.id == message.id }) else {
            return proposal.kind == .archive
                ? .done("Archived") : .unavailable("No longer in the inbox")
        }
        switch proposal.kind {
        case .archive:
            return .pending(actionTitle: "Archive…")
        case .unsubscribe:
            switch unsubscribeState(for: message) {
            case .offer:        return .pending(actionTitle: "Unsubscribe…")
            case .unsubscribed: return .done("Unsubscribed")
            case .noSafeMethod, .hidden:
                return .unavailable("No safe unsubscribe option")
            }
        case .makeEvent:
            if openCalendarEntries.contains(where: { $0.sourceMessageID == message.id }) {
                return .done("Event created")
            }
            return inbox.canSuggestEvent(for: message)
                ? .pending(actionTitle: "Make Event…") : .unavailable("Not offered for this message")
        case .reply:
            return .pending(actionTitle: nil)
        }
    }

    /// A plan row's button. Each branch only REQUESTS: it opens the dialog or
    /// form the message row's own button opens, and that dialog remains the
    /// single place a confirmed action can be minted.
    private func actOnAgentProposal(_ proposal: AgentProposal) {
        let message = proposal.message
        switch proposal.kind {
        case .archive:
            archiveFlow.request(message)
        case .unsubscribe:
            if case .offer(let offer) = inbox.unsubscribeDecision(for: message) {
                unsubscribeFlow.request(offer)
            }
        case .makeEvent:
            openSuggestedEventForm(message)
        case .reply:
            break
        }
    }

    private func demote(_ address: String) {
        mutateAllowlist("Couldn't demote the sender") {
            try AllowlistEditor(context: modelContext).demote(address)
        }
    }

    /// Add or remove a VIP from a message row. Sends nothing anywhere and
    /// touches no other list: VIP decides which dashboard section the mail
    /// shows up in, nothing more. The displayed name is NOT stored — the
    /// VIP list keeps addresses, and labels are the user's own typing in
    /// Settings (mail content never becomes stored data).
    private func toggleVIP(_ message: MailMessage, _ makeVIP: Bool) {
        mutateAllowlist(makeVIP ? "Couldn't add the VIP" : "Couldn't remove the VIP") {
            let editor = VIPEditor(context: modelContext)
            if makeVIP {
                try editor.add(address: message.fromAddress)
            } else {
                try editor.remove(address: message.fromAddress)
            }
            // Re-categorize in place so the star and the section move now,
            // without waiting for the next poll.
            inbox.refreshVIPs()
        }
    }

    private func mutateAllowlist(_ failureLabel: String, _ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            allowlistError = "\(failureLabel): \(error.localizedDescription)"
        }
    }
}

// Dashboard section backed by classified real mail (Unsubscribe / Scams).
// Shows the sender + subject rows for messages the local rules engine put in
// this category, or a neutral empty state. Reuses MessageRow from the Inbox.
struct CategoryMailSection: View {
    let title: String
    let messages: [MailMessage]
    let emptyText: String
    let cloudEligible: Set<String>
    let onPromote: (String) -> Void
    let onDemote: (String) -> Void
    var onArchive: ((MailMessage) -> Void)? = nil
    var archivingIDs: Set<String> = []
    // Stage 7 — only the Unsubscribe Candidates section passes these.
    var unsubscribeState: ((MailMessage) -> UnsubscribeRowState)? = nil
    var onUnsubscribe: ((UnsubscribeOffer) -> Void)? = nil
    var unsubscribingIDs: Set<String> = []
    var onOpenInGmail: ((MailMessage) -> Void)? = nil
    // Stage 8.
    var canMakeEvent: ((MailMessage) -> Bool)? = nil
    var onMakeEvent: ((MailMessage) -> Void)? = nil
    /// Step D5: the on-device date found in this email, if any.
    var eventHint: ((MailMessage) -> EventHint?)? = nil
    /// Step D6: start times of events the app created and hasn't undone.
    var createdEventTimes: CreatedEventTimes = CreatedEventTimes()
    /// VIP senders, as the view model sees them.
    var isVIP: ((MailMessage) -> Bool)? = nil
    var onToggleVIP: ((MailMessage, Bool) -> Void)? = nil
    /// Stage 9 account tag, nil when a single account is configured.
    var accountTag: ((MailMessage) -> String?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2).bold()
            if messages.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            } else {
                ForEach(messages) { msg in
                    MessageRow(
                        message: msg,
                        isCloudEligible: cloudEligible.contains(
                            AllowedSender.normalize(msg.fromAddress)),
                        isArchiving: archivingIDs.contains(msg.id),
                        onPromote: onPromote,
                        onDemote: onDemote,
                        onArchive: onArchive,
                        unsubscribeState: unsubscribeState?(msg) ?? .hidden,
                        isUnsubscribing: unsubscribingIDs.contains(msg.id),
                        onUnsubscribe: onUnsubscribe,
                        onOpenInGmail: onOpenInGmail,
                        onMakeEvent: (canMakeEvent?(msg) ?? false) ? onMakeEvent : nil,
                        eventHint: eventHint?(msg),
                        createdEventTimes: createdEventTimes,
                        isVIP: isVIP?(msg) ?? false,
                        onToggleVIP: onToggleVIP,
                        accountTag: accountTag?(msg))
                }
            }
            Divider()
        }
    }
}

// Tasks extracted by cloud analysis (allowlisted senders only — ARCHITECTURE.md
// documents this as accepted behavior, not a bug: non-allowlisted mail
// produces no tasks).
struct TasksSection: View {
    let tasks: [DashboardTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tasks (extracted from email)").font(.title2).bold()
            if tasks.isEmpty {
                Text("No tasks extracted yet. Tasks come from cloud analysis of allowlisted senders.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tasks) { task in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.caption)
                            .padding(.top, 2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).font(.callout)
                            Text(task.dueHint.map { "\($0) — from \(task.sender)" }
                                 ?? "from \(task.sender)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
        }
    }
}

struct DashboardSection: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2).bold()
            if items.isEmpty {
                Text("Nothing here yet").foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .padding(.top, 6)
                            .foregroundStyle(.secondary)
                        Text(item)
                    }
                }
            }
            Divider()
        }
    }
}

struct UpcomingCalendarSection: View {
    let viewModel: CalendarViewModel
    var onNewEvent: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Upcoming Calendar").font(.title2).bold()
                Spacer()
                if viewModel.authorization == .authorized, let onNewEvent {
                    Button {
                        onNewEvent()
                    } label: {
                        Label("New Event", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Event… (asks for confirmation before adding)")
                }
            }
            content
            Divider()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.authorization {
        case .notDetermined:
            Text("Requesting calendar access…").foregroundStyle(.secondary)
        case .denied:
            VStack(alignment: .leading, spacing: 4) {
                Text("Calendar access is off.").foregroundStyle(.secondary)
                Text("Grant access in System Settings → Privacy & Security → Calendars.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .restricted:
            Text("Calendar access is restricted on this Mac.").foregroundStyle(.secondary)
        case .authorized:
            if let error = viewModel.loadError {
                Text(error).foregroundStyle(.secondary)
            } else if viewModel.events.isEmpty {
                Text("Nothing scheduled in the next 7 days").foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.events) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .padding(.top, 6)
                            .foregroundStyle(.secondary)
                        Text(formatRow(event))
                    }
                }
            }
        }
    }

    private func formatRow(_ event: CalendarEvent) -> String {
        let when: String
        if event.isAllDay {
            when = "\(dayLabel(event.startDate)) (all day)"
        } else {
            when = "\(dayLabel(event.startDate)) \(timeFormatter.string(from: event.startDate))"
        }
        return "\(when) — \(event.title)"
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return weekdayFormatter.string(from: date)
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
}

struct InboxSection: View {
    let viewModel: InboxViewModel
    @Binding var showSetup: Bool
    let cloudEligible: Set<String>
    let onPromote: (String) -> Void
    let onDemote: (String) -> Void
    var onArchive: ((MailMessage) -> Void)? = nil
    var archivingIDs: Set<String> = []
    var canMakeEvent: ((MailMessage) -> Bool)? = nil
    var onMakeEvent: ((MailMessage) -> Void)? = nil
    /// Step D5: the on-device date found in this email, if any.
    var eventHint: ((MailMessage) -> EventHint?)? = nil
    /// Step D6: start times of events the app created and hasn't undone.
    var createdEventTimes: CreatedEventTimes = CreatedEventTimes()
    /// VIP senders, as the view model sees them.
    var isVIP: ((MailMessage) -> Bool)? = nil
    var onToggleVIP: ((MailMessage, Bool) -> Void)? = nil
    /// Stage 9 account tag, nil when a single account is configured.
    var accountTag: ((MailMessage) -> String?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            Divider()
        }
    }

    private var header: some View {
        HStack {
            Text("Inbox").font(.title2).bold()
            Spacer()
            if viewModel.setupState == .ready {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)
                .help("Refresh")
            }
            // Always present and never disabled — including mid-load and
            // mid-error — so a wedged or misbehaving fetch can never lock
            // the user out of re-entering credentials.
            Button {
                showSetup = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Configure email account")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.setupState {
        case .needsCredentials:
            VStack(alignment: .leading, spacing: 8) {
                // loadError can be set in this state (Keychain save failure)
                // — it must render here or the failure is silent.
                if let errorMessage = viewModel.loadErrorDisplay {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Email not set up.").foregroundStyle(.secondary)
                }
                Button("Configure") { showSetup = true }
            }
        case .ready:
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let errorMessage = viewModel.loadErrorDisplay {
            VStack(alignment: .leading, spacing: 8) {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reconfigure") { showSetup = true }
            }
        } else if viewModel.isLoading && viewModel.messages.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading inbox…").foregroundStyle(.secondary)
            }
        } else if viewModel.messages.isEmpty {
            Text("No recent mail in your inbox.").foregroundStyle(.secondary)
        } else {
            ForEach(viewModel.messages) { msg in
                MessageRow(
                    message: msg,
                    isCloudEligible: cloudEligible.contains(
                        AllowedSender.normalize(msg.fromAddress)),
                    isArchiving: archivingIDs.contains(msg.id),
                    onPromote: onPromote,
                    onDemote: onDemote,
                    onArchive: onArchive,
                    onMakeEvent: (canMakeEvent?(msg) ?? false) ? onMakeEvent : nil,
                    eventHint: eventHint?(msg),
                    createdEventTimes: createdEventTimes,
                    isVIP: isVIP?(msg) ?? false,
                    onToggleVIP: onToggleVIP,
                    accountTag: accountTag?(msg))
            }
        }
    }
}

private struct MessageRow: View {
    let message: MailMessage
    var isCloudEligible: Bool = false
    var isArchiving: Bool = false
    var onPromote: ((String) -> Void)? = nil
    var onDemote: ((String) -> Void)? = nil
    var onArchive: ((MailMessage) -> Void)? = nil
    var unsubscribeState: UnsubscribeRowState = .hidden
    var isUnsubscribing: Bool = false
    var onUnsubscribe: ((UnsubscribeOffer) -> Void)? = nil
    var onOpenInGmail: ((MailMessage) -> Void)? = nil
    /// Stage 8: nil when the row may not offer it (scam/suspicious/dmarc-fail).
    var onMakeEvent: ((MailMessage) -> Void)? = nil
    /// Step D5: the on-device date found in this email, if any.
    var eventHint: EventHint? = nil
    /// Step D6: start times of events the app created and hasn't undone.
    var createdEventTimes: CreatedEventTimes = CreatedEventTimes()
    /// VIP sender (Matt, 2026-10-07): always Important, decided on this Mac.
    var isVIP: Bool = false
    var onToggleVIP: ((MailMessage, Bool) -> Void)? = nil
    /// Stage 9: which account this message arrived in, shown only when
    /// more than one is configured (nothing to disambiguate otherwise).
    var accountTag: String? = nil

    // The button only STAGES a request (opens the confirmation dialog) —
    // nothing writes until the dialog's Archive button mints the confirmed
    // action. Disabled without an IMAP UID (preview fakes, stale rows):
    // the executor would refuse anyway; better not to offer.
    private var canArchive: Bool {
        onArchive != nil && message.imapUID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if isVIP {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .help("VIP sender — always shown in Important Email")
                }
                Text(message.fromName ?? message.fromAddress)
                    .font(.callout).bold()
                    .lineLimit(1)
                // Exception-only badge: local-only is the default and gets
                // no mark; only the widened boundary is called out.
                if isCloudEligible {
                    Image(systemName: "cloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Cloud-eligible: mail from this sender may be sent to the Claude API for analysis")
                }
                Spacer()
                if isArchiving {
                    ProgressView().controlSize(.mini)
                } else if canArchive, let onArchive {
                    Button {
                        onArchive(message)
                    } label: {
                        Image(systemName: "archivebox")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Archive… (asks for confirmation)")
                }
                if let accountTag {
                    Text(accountTag)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                        .lineLimit(1)
                        .help("This message arrived in \(accountTag)")
                }
                Text(Self.relativeDate(message.date))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(message.subject)
                .font(.callout)
                .lineLimit(1)
            senderChecksLine
            unsubscribeLine
            EventRowMark(messageID: message.id, hint: eventHint,
                         createdTimes: createdEventTimes,
                         onMakeEvent: onMakeEvent.map { handler in { handler(message) } })
        }
        .padding(.vertical, 2)
        // Without an explicit content shape, only the text glyphs are
        // right-clickable; this makes the whole row a target.
        .contentShape(Rectangle())
        .contextMenu { contextMenuItems }
    }

    /// Sender-identity checks, computed on this Mac (Matt, 2026-10-25).
    /// Shown only when NOTABLE — one mismatch alone is routine for
    /// legitimate bulk mail, and crying wolf is the failure this app is
    /// built to avoid. The full list is always in the tooltip.
    @ViewBuilder
    private var senderChecksLine: some View {
        if let forensics = message.forensics, forensics.isNotable {
            Label(forensics.findings.joined(separator: " · "),
                  systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help("Checks this app ran on the message's headers: "
                      + forensics.findings.joined(separator: "; "))
        }
    }
    // State-aware: shows current standing and offers only the transition
    // that makes sense. Promote ends in "…" because it opens a confirmation;
    // demote narrows the boundary, so it acts immediately.
    // Stage 7. Like Archive, the button only STAGES a request — nothing
    // happens until the dialog's confirm button mints the action.
    @ViewBuilder
    private var unsubscribeLine: some View {
        switch unsubscribeState {
        case .hidden:
            EmptyView()
        case .offer(let offer):
            HStack(spacing: 6) {
                if isUnsubscribing {
                    ProgressView().controlSize(.mini)
                    Text("Unsubscribing…").foregroundStyle(.secondary)
                } else if let onUnsubscribe {
                    Button {
                        onUnsubscribe(offer)
                    } label: {
                        Label(UnsubscribeDialogCopy.rowButtonTitle(offer.method),
                              systemImage: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Unsubscribe… (asks for confirmation)")
                }
            }
            .font(.caption)
        case .noSafeMethod(let canOpenInGmail):
            HStack(spacing: 6) {
                Text(canOpenInGmail ? "No safe in-app unsubscribe —" : "No safe unsubscribe option — archive instead")
                    .foregroundStyle(.tertiary)
                    .help("This sender only offers a web link, or its one-click request isn't verified by DKIM. The app doesn't open sender-chosen web pages.")
                if canOpenInGmail, let onOpenInGmail {
                    Button {
                        onOpenInGmail(message)
                    } label: {
                        Label("Open in Gmail", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Opens this message in Gmail in your browser, where you can use Gmail's Unsubscribe button.")
                }
            }
            .font(.caption)
        case .unsubscribed(let outcome, _, _):
            // A finished choice shows a status, never a button — so a
            // distracted click can't repeat it. Redoing it is deliberate:
            // right-click → Unsubscribe Again… / Open in Gmail.
            Label(UnsubscribeDialogCopy.statusLabel(outcome), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(UnsubscribeDialogCopy.statusHelp(outcome))
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if case .offer(let offer) = unsubscribeState, let onUnsubscribe, !isUnsubscribing {
            Button("Unsubscribe…") {
                onUnsubscribe(offer)
            }
        }
        if case .unsubscribed(_, let again?, _) = unsubscribeState, let onUnsubscribe, !isUnsubscribing {
            Button("Unsubscribe Again…") {
                onUnsubscribe(again)
            }
        }
        if unsubscribeState.canOpenInGmail, let onOpenInGmail {
            Button("Open in Gmail") {
                onOpenInGmail(message)
            }
        }
        if canArchive, let onArchive, !isArchiving {
            Button("Archive…") {
                onArchive(message)
            }
        }
        if let onMakeEvent {
            Button("Make Event from Email…") {
                onMakeEvent(message)
            }
        }
        if let onToggleVIP {
            Button(isVIP ? "Remove \(message.fromAddress) from VIPs"
                         : "Add \(message.fromAddress) to VIPs") {
                onToggleVIP(message, !isVIP)
            }
        }
        if isCloudEligible {
            if let onDemote {
                Button {
                    onDemote(message.fromAddress)
                } label: {
                    Label("Allowed for Cloud Analysis", systemImage: "checkmark")
                }
            }
        } else if let onPromote {
            Button("Allow Cloud Analysis for \(message.fromAddress)…") {
                onPromote(message.fromAddress)
            }
        }
    }

    private static func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return timeFormatter.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()), date > weekAgo {
            return weekdayFormatter.string(from: date)
        }
        return monthDayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
}

// MARK: - Stage 8 presentation (New Event sheet, confirmation, alerts)

private struct CreateEventPresentation: ViewModifier {
    @Binding var eventFormRequest: EventFormRequest?
    @Binding var eventSuggestionRefusal: String?
    let eventFormCalendars: [WritableCalendar]
    let createEventFlow: CreateEventConfirmationFlow
    let calendarActions: CalendarActionService
    let calendar: CalendarViewModel

    func body(content: Content) -> some View {
        content
            // Step D3: confirmation banner after a successful create.
            .overlay(alignment: .top) {
                if let notice = calendarActions.lastCreated {
                    EventCreatedBanner(
                        notice: notice,
                        onUndo: {
                            Task {
                                let outcome = await calendarActions.undoCreate(eventIdentifier: notice.eventIdentifier)
                                await calendar.load()
                                // Only .removed clears the banner in the
                                // service; on any other outcome leave it up
                                // so the alert has something to explain.
                                if outcome == .removed { calendarActions.dismissCreatedNotice() }
                            }
                        },
                        onDismiss: calendarActions.dismissCreatedNotice)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(8))
                        if calendarActions.lastCreated?.id == notice.id {
                            calendarActions.dismissCreatedNotice()
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: calendarActions.lastCreated)
            .sheet(item: $eventFormRequest) { request in
                NewEventSheet(
                    request: request,
                    writableCalendars: eventFormCalendars,
                    onReview: { draft in
                        eventFormRequest = nil
                        Task {
                            // Let the sheet finish dismissing first.
                            try? await Task.sleep(for: .milliseconds(350))
                            createEventFlow.request(draft)
                        }
                    },
                    onCancel: { eventFormRequest = nil })
            }
            // Stage 8 per-action confirmation. Presents only a validated
            // NewEventDraft; any dismissal but the confirm button routes to
            // cancel(), which mints nothing.
            .confirmationDialog(
                "Add this event to your calendar?",
                isPresented: Binding(
                    get: { createEventFlow.pending != nil },
                    set: { if !$0 { createEventFlow.cancel() } }
                ),
                titleVisibility: .visible,
                presenting: createEventFlow.pending
            ) { draft in
                Button("Add to Calendar") {
                    if let action = createEventFlow.confirm() {
                        Task {
                            await calendarActions.create(action)
                            await calendar.load()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    createEventFlow.cancel()
                }
            } message: { draft in
                Text(EventFormCopy.dialogMessage(draft))
            }
            .alert(
                "Calendar",
                isPresented: Binding(
                    get: { calendarActions.lastError != nil },
                    set: { if !$0 { calendarActions.dismissError() } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(calendarActions.lastError ?? "")
            }
            .alert(
                "Can't suggest an event",
                isPresented: Binding(
                    get: { eventSuggestionRefusal != nil },
                    set: { if !$0 { eventSuggestionRefusal = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(eventSuggestionRefusal ?? "")
            }
    }
}

// MARK: - Stage 8 Step D3: "event created" indications

private struct EventCreatedBanner: View {
    let notice: CalendarActionService.CreatedNotice
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
            Text("Added “\(notice.title)” to \(notice.calendarTitle)")
                .foregroundStyle(.white)
                .lineLimit(1)
            Button("Undo", action: onUndo)
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .bold()
            Button(action: onDismiss) {
                Image(systemName: "xmark").foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.green.opacity(0.9)))
        .shadow(radius: 4, y: 2)
    }
}

/// Step D5/D6. What a message row says about calendar events:
///   - an event was created FROM this email (log entry with its message ID)
///     → "Event created";
///   - no such entry, but this email's on-device hint resolves to the same
///     time as an event the app created and hasn't undone (Matt 2026-09-28:
///     the earlier mails in a thread that settled on that time)
///     → "Event created", with a note saying it came from another email;
///   - otherwise, a hint → the blue "make event…" line, which opens the SAME
///     reviewed form the context menu opens and creates nothing by itself;
///   - no hint → nothing.
private struct EventRowMark: View {
    @Query private var entries: [CalendarActionLogEntry]
    let hint: EventHint?
    let createdTimes: CreatedEventTimes
    let onMakeEvent: (() -> Void)?

    init(messageID: String, hint: EventHint?, createdTimes: CreatedEventTimes,
         onMakeEvent: (() -> Void)?) {
        self.hint = hint
        self.createdTimes = createdTimes
        self.onMakeEvent = onMakeEvent
        let target: String? = messageID
        _entries = Query(filter: #Predicate<CalendarActionLogEntry> {
            $0.sourceMessageID == target && $0.undoneAt == nil
        })
    }

    private var matchesAnotherEmailsEvent: Bool {
        guard entries.isEmpty, let hint else { return false }
        return createdTimes.contains(hint)
    }

    var body: some View {
        if !entries.isEmpty {
            created(note: nil)
        } else if matchesAnotherEmailsEvent {
            created(note: "An event at this time is already in your calendar — created from another email.")
        } else if let hint, let onMakeEvent {
            Button(action: onMakeEvent) {
                Label("\(hint.label) — make event…", systemImage: "calendar.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .help("A date was found in this email, on this Mac. Opens the New Event form; nothing is saved until you confirm.")
        }
    }

    private func created(note: String?) -> some View {
        Label("Event created", systemImage: "calendar.badge.checkmark")
            .font(.caption)
            .foregroundStyle(.green)
            .help(note ?? "An event was created from this email.")
    }
}

// Stage 7: what an Unsubscribe Candidates row shows.
enum UnsubscribeRowState {
    case hidden
    case offer(UnsubscribeOffer)
    case noSafeMethod(canOpenInGmail: Bool)
    /// A choice was already made for this sender (latest log outcome).
    /// `again` is the offer for a deliberate repeat (right-click only).
    case unsubscribed(UnsubscribeLogOutcome, again: UnsubscribeOffer?, canOpenInGmail: Bool)

    var canOpenInGmail: Bool {
        switch self {
        case .noSafeMethod(let can), .unsubscribed(_, _, let can): return can
        case .hidden, .offer: return false
        }
    }

    /// Pure resolution (unit-tested). Any recorded choice for the sender —
    /// one-click success, email draft, or Gmail hand-off — wins over the
    /// button, so nothing invites a repeat.
    static func resolve(latestOutcome: UnsubscribeLogOutcome?,
                        decision: UnsubscribeEligibility.Decision,
                        canOpenInGmail: Bool) -> UnsubscribeRowState {
        let offer: UnsubscribeOffer? = {
            if case .offer(let o) = decision { return o }
            return nil
        }()
        if let latestOutcome {
            return .unsubscribed(latestOutcome, again: offer, canOpenInGmail: canOpenInGmail)
        }
        switch decision {
        case .offer(let o):             return .offer(o)
        case .refused(.noSafeMethod):   return .noSafeMethod(canOpenInGmail: canOpenInGmail)
        case .refused:                  return .hidden
        }
    }
}

// Stage 7 dialog/row copy, kept pure so tests can check that the dialog
// names the destination HOST (or mailto recipient) and never the tokenized
// URL path/query.
enum UnsubscribeDialogCopy {
    static func rowButtonTitle(_ method: UnsubscribeMethod) -> String {
        switch method {
        case .oneClick: return "Unsubscribe"
        case .mailto:   return "Unsubscribe by email"
        }
    }

    static func statusLabel(_ outcome: UnsubscribeLogOutcome) -> String {
        switch outcome {
        case .accepted:      return "Unsubscribed"
        case .draftOpened:   return "Unsubscribe email drafted"
        case .handedToGmail: return "Unsubscribed in Gmail"
        }
    }

    static func statusHelp(_ outcome: UnsubscribeLogOutcome) -> String {
        switch outcome {
        case .accepted:
            return "The sender's server accepted the unsubscribe request."
        case .draftOpened:
            return "An unsubscribe email was opened in Apple Mail. If you didn't send it, right-click → Unsubscribe Again…"
        case .handedToGmail:
            return "Marked when you chose Open in Gmail. The app can't see Gmail's result; right-click → Open in Gmail to check."
        }
    }

    static func confirmTitle(_ method: UnsubscribeMethod) -> String {
        switch method {
        case .oneClick: return "Unsubscribe"
        case .mailto:   return "Open Draft in Mail"
        }
    }

    static func redirectMessage(_ pending: PendingUnsubscribeRedirect) -> String {
        "\(pending.approvedHost) handed your unsubscribe request to \(pending.targetHost).\n\nSend the same one-time unsubscribe request there? That company will see your IP address and the link's tracking token — nothing else. If you cancel, nothing more is sent and you may still be subscribed."
    }

    static func message(_ offer: UnsubscribeOffer) -> String {
        let header = "From \(offer.message.fromName ?? offer.message.fromAddress)\n“\(offer.message.subject)”\n\n"
        switch offer.method {
        case .oneClick:
            return header + "Sends a one-time unsubscribe request to \(offer.method.destinationLabel). This can't be undone from the app. The message stays in your inbox."
        case .mailto:
            return header + "Opens a pre-filled unsubscribe email to \(offer.method.destinationLabel) in Apple Mail. Nothing is sent until you press Send in Mail."
        }
    }
}

// Stage 6: the undo surface. Shows the most recent still-archived entries
// from the action log — sender + date only (the log persists no subjects,
// by design) — each with a one-click Undo. Hidden entirely when the log
// has nothing open, so the dashboard stays quiet until an archive happens.
struct RecentArchivesSection: View {
    @Query(filter: #Predicate<ArchiveLogEntry> { $0.undoneAt == nil },
           sort: \ArchiveLogEntry.timestamp, order: .reverse)
    private var openEntries: [ArchiveLogEntry]

    let archivingIDs: Set<String>
    let onUndo: (ArchiveLogEntry) -> Void

    private static let displayLimit = 5

    var body: some View {
        if !openEntries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recently Archived").font(.title2).bold()
                ForEach(openEntries.prefix(Self.displayLimit)) { entry in
                    HStack {
                        Text(entry.senderAddress)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if archivingIDs.contains(entry.messageID) {
                            ProgressView().controlSize(.mini)
                        } else if entry.newUID != nil {
                            Button("Undo") { onUndo(entry) }
                                .buttonStyle(.borderless)
                                .font(.callout)
                        } else {
                            // No COPYUID handle: one-click undo can't work.
                            // The message is still in the archive mailbox.
                            Text("in \(entry.archivedTo)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help("The server didn't report where this message went, so one-click undo isn't available. It's still in \(entry.archivedTo).")
                        }
                    }
                }
                Divider()
            }
        }
    }
}

// MARK: - Preview fakes
//
// Clearly-fake placeholder data (user@example.com) so the canvas renders a
// populated Inbox section without touching the Keychain or the network.
// The hard no-network guarantee does NOT live here — it lives in
// IMAPMailSource.fetchRecent (preview-environment guard), so even a
// #Preview that forgets these fakes cannot reach the network.

private struct PreviewMailSource: MailSource {
    func fetchRecent(limit: Int) async throws -> [MailMessage] {
        [
            MailMessage(
                id: "preview-1",
                fromName: "Preview Sender",
                fromAddress: "sender@example.com",
                subject: "Sample message — preview data only",
                date: Date().addingTimeInterval(-3_600)
            ),
            MailMessage(
                id: "preview-2",
                fromName: nil,
                fromAddress: "user@example.com",
                subject: "Second sample message",
                date: Date().addingTimeInterval(-90_000)
            ),
        ]
    }
}

private struct PreviewCredentialsStore: CredentialsStore {
    nonisolated func save(_ credentials: IMAPCredentials) throws {}
    nonisolated func loadAll() throws -> [IMAPCredentials] {
        [IMAPCredentials(
            server: "imap.example.com",
            port: 993,
            account: "user@example.com",
            password: "preview-placeholder"
        )]
    }
    nonisolated func delete(accountID: String) throws {}
}

#Preview {
    ContentView(
        inbox: InboxViewModel(
            credentialsStore: PreviewCredentialsStore(),
            mailSource: PreviewMailSource()
        )
    )
    // In-memory container so @Environment(\.modelContext) resolves in the
    // canvas without a real on-disk store.
    .modelContainer(for: [AllowedSender.self, ClassificationCacheEntry.self,
                          CloudVerdictEntry.self, ArchiveLogEntry.self,
                          UnsubscribeLogEntry.self, CalendarActionLogEntry.self],
                    inMemory: true)
}
