// Agent/AgentSection.swift
//
// The triage agent's place on the dashboard: a request field, the plan it
// comes back with, and a plain list of what it did.
//
// This view performs nothing. A plan row's button calls `onAct`, and
// ContentView answers by opening the SAME confirmation dialog the message
// row's own button opens. Sender and subject shown in a plan row are read
// from the message on this Mac; for a local-only sender the row says the
// assistant never saw them.

import SwiftUI

/// What a plan row offers right now. Resolved by ContentView from the same
/// state the message rows use (inbox, unsubscribe log, calendar log).
enum AgentProposalStatus: Equatable {
    /// Still to do. `actionTitle` is the button; nil means nothing to click.
    case pending(actionTitle: String?)
    /// Already done through the normal confirmation flow.
    case done(String)
    /// The app's rules no longer offer this.
    case unavailable(String)
}

struct AgentSection: View {
    let agent: TriageAgent
    let isDemo: Bool
    @Binding var sharesCalendarTitles: Bool
    let onRun: (String) -> Void
    let status: (AgentProposal) -> AgentProposalStatus
    let onAct: (AgentProposal) -> Void

    @State private var requestText = ""
    @State private var showsActivity = false

    private static let suggestions = ["Plan my morning", "Clean up my inbox"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            requestRow
            privacyNote
            if agent.phase != .idle {
                results
            }
            Divider()
        }
    }

    // MARK: Header and request

    private var header: some View {
        HStack(spacing: 8) {
            Text("Assistant").font(.title2).bold()
            Text("Prototype")
                .font(.caption2).bold()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var requestRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Ask about your inbox and calendar", text: $requestText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .disabled(agent.isRunning)
                if agent.isRunning {
                    Button("Cancel") { agent.cancel() }
                } else {
                    Button("Ask", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedRequest.isEmpty)
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        requestText = suggestion
                        submit()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(agent.isRunning)
                }
            }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("It sees sender and subject only for senders on your Cloud Allowlist. All other mail reaches it as an unnamed row. It can only propose: every action still asks you first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: isDemo ? .constant(true) : $sharesCalendarTitles) {
                Text(isDemo
                     ? "Share calendar event titles (on for demo data)"
                     : "Share calendar event titles (otherwise it sees busy times only)")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .disabled(isDemo || agent.isRunning)
        }
    }

    private var trimmedRequest: String {
        requestText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let request = trimmedRequest
        guard !request.isEmpty, !agent.isRunning else { return }
        onRun(request)
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if agent.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(latestActivity ?? "Starting…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        if case .finished(let stop) = agent.phase, let message = stop.userMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !agent.summary.isEmpty {
            Text(AgentSummaryText.plain(agent.summary))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if agent.phase == .finished(.completed), agent.proposals.isEmpty {
            // Stated by the app, so a summary can't imply a plan that isn't there.
            Text("No plan this time: the assistant proposed no actions.")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
        }
        if !agent.visibleProposals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan — nothing happens until you confirm each one")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                ForEach(agent.visibleProposals) { proposal in
                    AgentProposalRow(proposal: proposal,
                                     status: status(proposal),
                                     onAct: { onAct(proposal) },
                                     onDismiss: { agent.dismiss(proposal) })
                }
            }
        }
        if !agent.log.isEmpty {
            // A plain toggle rather than DisclosureGroup: the AppKit-backed
            // disclosure re-laid itself out while the log grew mid-run and
            // logged "-layoutSubtreeIfNeeded on a view which is already being
            // laid out" once per launch.
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    showsActivity.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsActivity ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 10)
                        Text("What the assistant did · \(agent.tokensUsed.formatted()) tokens")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsActivity {
                    ForEach(agent.log) { entry in
                        Text(entry.text(name: agent.displayName(forHandle:)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The newest log line that isn't bookkeeping, for the running state.
    private var latestActivity: String? {
        agent.log.last { entry in
            if case .modelTurn = entry.event { return false }
            return true
        }?.text(name: agent.displayName(forHandle:))
    }
}

private struct AgentProposalRow: View {
    let proposal: AgentProposal
    let status: AgentProposalStatus
    let onAct: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(verb) — \(proposal.message.fromName ?? proposal.message.fromAddress)")
                    .font(.callout).bold()
                Text(proposal.message.subject)
                    .font(.callout)
                    .lineLimit(1)
                if !proposal.reason.isEmpty {
                    Text(proposal.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !proposal.contentWasShared {
                    // The demo's key idea, so it reads as a badge, not a
                    // footnote (Matt, 2026-11-12). Display only.
                    Label("Kept on this Mac: the assistant never saw this sender or subject",
                          systemImage: "lock.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .padding(.top, 4)
                }
                if proposal.reportedAddressedToAI {
                    // The model's report, verified only as far as the app can:
                    // it read this body this run (AgentWorkspace). Display only.
                    Label("The assistant found instructions aimed at an AI in this email",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .pending(let actionTitle):
            HStack(spacing: 6) {
                if let actionTitle {
                    Button(actionTitle, action: onAct)
                        .controlSize(.small)
                }
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove from the plan")
            }
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .unavailable(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var verb: String {
        switch proposal.kind {
        case .archive:     return "Archive"
        case .unsubscribe: return "Unsubscribe"
        case .makeEvent:   return "Make an event"
        case .reply:       return "Needs a reply"
        }
    }

    private var icon: String {
        switch proposal.kind {
        case .archive:     return "archivebox"
        case .unsubscribe: return "minus.circle"
        case .makeEvent:   return "calendar.badge.plus"
        case .reply:       return "arrowshape.turn.up.left"
        }
    }
}
