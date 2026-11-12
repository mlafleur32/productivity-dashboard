// Settings/VIPSettingsView.swift
//
// The VIP list (Matt, 2026-10-07): mail from these senders always lands in
// Important Email, decided on this Mac. Unlike the allowlist screen, this
// one DOES take a typed address — being a VIP sends nothing anywhere, so a
// typo costs a missing highlight rather than an unintended cloud send. The
// message-row context menu can add a sender too, which avoids typing for
// anyone whose mail is already on screen.

import SwiftUI
import SwiftData

struct VIPSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VIPSender.addedAt, order: .reverse)
    private var vips: [VIPSender]

    @State private var address = ""
    @State private var label = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VIPs").font(.title3).bold()
            Text("Mail from these senders always appears in Important Email, judged on this Mac with no API call. Being a VIP does not make a sender cloud-eligible — that stays with the Cloud Allowlist. A spoofed message still shows up as a scam, whoever it claims to be from.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("name@example.com", text: $address)
                    .textFieldStyle(.roundedBorder)
                TextField("Label (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button("Add") { add() }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if vips.isEmpty {
                Spacer()
                Text("No VIPs yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(vips) { vip in
                    row(vip)
                }
            }

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

    private func row(_ vip: VIPSender) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                if let name = vip.displayName, !name.isEmpty {
                    Text(name).font(.callout)
                    Text(vip.senderIdentifier).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(vip.senderIdentifier).font(.callout)
                }
            }
            Spacer()
            Button {
                mutate("Couldn't remove the VIP") {
                    try VIPEditor(context: modelContext).remove(vip)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from VIPs")
        }
        .padding(.vertical, 2)
    }

    private func add() {
        mutate("Couldn't add the VIP") {
            try VIPEditor(context: modelContext).add(address: address, displayName: label)
            address = ""
            label = ""
        }
    }

    // Mutation failures must render, not vanish — same rule as the
    // allowlist screen.
    private func mutate(_ context: String, _ work: () throws -> Void) {
        do {
            try work()
            errorMessage = nil
        } catch let error as VIPListError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = context + "."
        }
    }
}
