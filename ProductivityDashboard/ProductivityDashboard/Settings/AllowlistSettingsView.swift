// Settings/AllowlistSettingsView.swift
//
// The audit surface for the cloud allowlist (Stage 4, Step E): one screen
// that answers "who can currently reach the cloud?" — review, demote
// (toggle off, row kept), and remove. Lives in the native Settings scene
// (app menu ▸ Settings…, ⌘,), the future home of the Stage 5 API-key field.
//
// Deliberately NO free-text add field. The only way onto the allowlist is
// right-clicking real mail on the dashboard, so every row's address was
// observed on an actual message — a typed typo can't create a row the user
// believes is promoted but that never matches real mail.

import SwiftUI
import SwiftData

struct AllowlistSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AllowedSender.addedAt, order: .reverse)
    private var senders: [AllowedSender]
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud Allowlist").font(.title3).bold()
            Text("Mail from senders with the switch on may be sent to the Claude API for analysis. Everything else never leaves this Mac. To add a sender, right-click one of their messages on the dashboard — addresses can't be typed in here by design.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if senders.isEmpty {
                Spacer()
                Text("No senders promoted yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(senders) { sender in
                    row(sender)
                }
            }

            // Mutation failures must render, not vanish — same rule as the
            // Keychain-save error in the Inbox section.
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 340)
    }

    private func row(_ sender: AllowedSender) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sender.senderIdentifier).font(.callout)
                Text("Added \(sender.addedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Cloud analysis", isOn: eligibilityBinding(sender))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(sender.cloudEligible
                      ? "On: mail from this sender may be sent to the Claude API"
                      : "Off: this sender is local-only (row kept so you can turn it back on)")
            Button {
                mutate("Couldn't remove the sender") {
                    try AllowlistEditor(context: modelContext).remove(sender)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from the allowlist entirely")
        }
        .padding(.vertical, 2)
    }

    private func eligibilityBinding(_ sender: AllowedSender) -> Binding<Bool> {
        Binding(
            get: { sender.cloudEligible },
            set: { newValue in
                mutate("Couldn't update the sender") {
                    try AllowlistEditor(context: modelContext)
                        .setCloudEligible(sender, to: newValue)
                }
            }
        )
    }

    private func mutate(_ failureLabel: String, _ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
        } catch {
            errorMessage = "\(failureLabel): \(error.localizedDescription)"
        }
    }
}

#Preview {
    AllowlistSettingsView()
        .modelContainer(for: [AllowedSender.self], inMemory: true)
}
