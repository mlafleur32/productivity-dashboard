// Settings/ClaudeAPISettingsView.swift
//
// Claude API pane (Stage 5, Step B): the API key's only entry point, the
// analysis-model picker, and the usage counters (CloudUsageLedger, added
// 2026-07-05). Sits next to the Cloud Allowlist pane — the two Settings
// tabs are, together, the whole control surface of the privacy boundary:
// WHO may reach the cloud (allowlist) and HOW (this pane).
//
// The stored key is never displayed back — the pane reports presence only.
// Removing is one click (narrows capability); saving requires typing the
// key (the deliberate act). No key stored is a fully valid state: the
// Stage 5 cloud path simply does not run.

import SwiftUI

struct ClaudeAPISettingsView: View {
    private let keyStore: APIKeyStoring
    private let usageLedger = CloudUsageLedger()

    @AppStorage(CloudModel.storageKey)
    private var storedModelID: String = CloudModel.defaultModel.rawValue

    @State private var keyInput = ""
    @State private var hasStoredKey = false
    @State private var errorMessage: String?
    @State private var usage = CloudUsageTotals()

    init(keyStore: APIKeyStoring = KeychainAPIKeyStore()) {
        self.keyStore = keyStore
    }

    private var selectedModel: CloudModel {
        CloudModel.resolve(storedValue: storedModelID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude API").font(.title3).bold()
            Text("Used only to analyze mail from senders on your Cloud Allowlist. The key is stored in this Mac's Keychain and never synced. Without a key, everything stays local.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            keySection

            Divider().padding(.vertical, 4)

            Text("Analysis model").font(.headline)
            Picker("Analysis model", selection: $storedModelID) {
                ForEach(CloudModel.allCases) { model in
                    Text(model.displayName).tag(model.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            Text(selectedModel.costHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Each email is analyzed once, on first arrival; switching models affects future analyses only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            usageSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        // minHeight sized for the fullest state (stored key + usage rows +
        // an error line). Keep in step when the pane gains sections — a min
        // that's too small clips content at the window's default size.
        .frame(minWidth: 480, minHeight: 460, alignment: .topLeading)
        .onAppear {
            refreshKeyPresence()
            usage = usageLedger.totals()
        }
    }

    @ViewBuilder
    private var keySection: some View {
        if hasStoredKey {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.green)
                Text("An API key is stored in the Keychain.")
                Spacer()
                Button("Remove Key") {
                    do {
                        try keyStore.delete()
                        hasStoredKey = false
                        errorMessage = nil
                    } catch {
                        errorMessage = "Couldn't remove the key: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    // Best-effort clearing on save, same limitation as
                    // InboxSetupSheet: Swift strings can't be guaranteed
                    // zeroed; the value is in memory only until saved.
                    SecureField("sk-ant-…", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Button("Save to Keychain") { saveKey() }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                // Advisory, not blocking: key formats can evolve, so an
                // unexpected prefix warns instead of refusing.
                if !keyInput.isEmpty, !keyInput.hasPrefix("sk-ant-") {
                    Text("This doesn't look like an Anthropic API key (expected to start with “sk-ant-”). You can still save it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Create a key at console.anthropic.com → API Keys. Make plain API calls only — no feedback/training programs (see ARCHITECTURE.md).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        Text("Usage").font(.headline)
        if usage.analysisCount == 0 {
            Text("No API calls recorded yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(usage.analysisCount) API \(usage.analysisCount == 1 ? "call" : "calls")\(sinceText)")
                    Spacer()
                    Button("Reset Counters") {
                        usageLedger.reset()
                        usage = usageLedger.totals()
                    }
                }
                Text("Email analyses and Assistant turns, one call each.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(usage.inputTokens.formatted()) tokens sent · \(usage.outputTokens.formatted()) received")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Estimated cost: \(costText) (list prices; an upper bound)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sinceText: String {
        guard let since = usage.since else { return "" }
        return " since \(since.formatted(date: .abbreviated, time: .omitted))"
    }

    private var costText: String {
        let dollars = usage.estimatedDollars
        if dollars > 0, dollars < 0.01 { return "under $0.01" }
        return String(format: "$%.2f", dollars)
    }

    private func saveKey() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keyStore.save(trimmed)
            keyInput = ""
            hasStoredKey = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save the key to the Keychain: \(error.localizedDescription)"
        }
    }

    private func refreshKeyPresence() {
        do {
            hasStoredKey = try keyStore.load() != nil
            errorMessage = nil
        } catch {
            // A read failure reports as "no key" (fail-safe: cloud path
            // stays off) but must not be silent.
            hasStoredKey = false
            errorMessage = "Couldn't read the Keychain: \(error.localizedDescription)"
        }
    }
}

// Canvas-safe fake. The hard no-Keychain guarantee does NOT live here — it
// lives in KeychainAPIKeyStore's preview guard — but injecting a fake keeps
// the preview interactive (save/remove work in-memory).
private final class PreviewAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private var key: String?
    func save(_ key: String) throws { self.key = key }
    func load() throws -> String? { key }
    func delete() throws { key = nil }
}

#Preview {
    ClaudeAPISettingsView(keyStore: PreviewAPIKeyStore())
}
