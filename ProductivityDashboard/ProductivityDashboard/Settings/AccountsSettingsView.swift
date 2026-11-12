// Settings/AccountsSettingsView.swift
//
// Stage 9. Every IMAP account the app reads, in one place: add, remove,
// and see what's configured. Passwords are never shown or read back here —
// the Keychain holds them, and this screen only ever sees addresses and
// servers (the list comes from loadAll(), whose credentials are not
// displayed).
//
// Adding reuses InboxSetupSheet, the same validated three-field form as
// first-run setup, so there is exactly one place that builds credentials.
//
// Removing deletes the Keychain item for that account only. It does not
// touch mail, the allowlist, the VIP list or any log: those are keyed by
// sender address, not by account.

import SwiftUI

struct AccountsSettingsView: View {
    private let store: CredentialsStore

    init(store: CredentialsStore? = nil) {
        self.store = store ?? KeychainCredentialsStore()
    }

    @State private var accounts: [IMAPCredentials] = []
    @State private var showAdd = false
    @State private var errorMessage: String?
    @State private var confirmingRemoval: IMAPCredentials?
    // Archive folder picker (Stage 9): mailbox names per account, fetched
    // from the server on demand. Empty until the user asks, because it
    // costs an IMAP round trip.
    @State private var mailboxes: [String: [String]] = [:]
    @State private var loadingMailboxesFor: String?
    @State private var archiveChoice: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mail Accounts").font(.title3).bold()
            Text("Every account here is fetched over IMAP and merged into one dashboard, newest first. Each message keeps track of the account it came from, so archiving and undo act on the right mailbox.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if accounts.isEmpty {
                Spacer()
                Text("No accounts yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(accounts, id: \.accountID) { account in
                    row(account)
                }
            }

            HStack {
                Button("Add Account…") { showAdd = true }
                Spacer()
                Text("Changes take effect on the next refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear(perform: reload)
        .sheet(isPresented: $showAdd) {
            InboxSetupSheet(
                onSave: { credentials in
                    showAdd = false
                    add(credentials)
                },
                onCancel: { showAdd = false })
        }
        // Removing a credential is irreversible from in here (the password
        // is gone and must be re-entered), so it asks first — same rule as
        // every other destructive action in the app.
        .confirmationDialog(
            "Remove this account?",
            isPresented: Binding(
                get: { confirmingRemoval != nil },
                set: { if !$0 { confirmingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingRemoval
        ) { account in
            Button("Remove \(account.account)", role: .destructive) {
                remove(account)
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: { account in
            Text("Its mail stops appearing on the dashboard and its password is removed from the Keychain. Nothing on the mail server changes, and you can add it back by entering the password again.")
        }
    }

    private func row(_ account: IMAPCredentials) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "envelope").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.account).font(.callout)
                    Text("\(account.server):\(account.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    confirmingRemoval = account
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this account")
            }
            archiveFolderRow(account)
        }
        .padding(.vertical, 2)
    }

    /// Which folder Archive moves mail to. "Automatic" asks the server for
    /// its own Archive/All Mail flags, which is right for Gmail and for any
    /// server that implements RFC 6154. Servers that publish nothing (some
    /// older ones) need the folder named here — by choosing from the
    /// server's OWN list, never by the app guessing.
    @ViewBuilder
    private func archiveFolderRow(_ account: IMAPCredentials) -> some View {
        let id = account.accountID
        HStack(spacing: 8) {
            Text("Archive folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let names = mailboxes[id] {
                Picker("", selection: Binding(
                    get: { archiveChoice[id] ?? "" },
                    set: { choice in
                        archiveChoice[id] = choice
                        ArchiveMailboxPreference.set(choice.isEmpty ? nil : choice, for: id)
                    }
                )) {
                    Text("Automatic (ask the server)").tag("")
                    ForEach(names, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            } else if loadingMailboxesFor == id {
                ProgressView().controlSize(.mini)
            } else {
                Text(archiveChoice[id].map { $0.isEmpty ? "Automatic" : $0 } ?? "Automatic")
                    .font(.caption)
                Button("Choose…") { loadMailboxes(for: account) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func loadMailboxes(for account: IMAPCredentials) {
        let id = account.accountID
        loadingMailboxesFor = id
        Task {
            defer { loadingMailboxesFor = nil }
            do {
                let source = IMAPMailSource(credentialsStore: store, accountID: id)
                let names = try await source.listMailboxes()
                mailboxes[id] = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't read that account's folder list."
            }
        }
    }

    // MARK: - Mutations

    private func reload() {
        do {
            accounts = try store.loadAll()
            for account in accounts {
                archiveChoice[account.accountID] =
                    ArchiveMailboxPreference.mailbox(for: account.accountID) ?? ""
            }
            errorMessage = nil
        } catch {
            accounts = []
            errorMessage = "Couldn't read the accounts from your Keychain."
        }
    }

    private func add(_ credentials: IMAPCredentials) {
        do {
            try store.save(credentials)
            reload()
        } catch {
            errorMessage = "Couldn't save that account to your Keychain."
        }
    }

    private func remove(_ account: IMAPCredentials) {
        do {
            try store.delete(accountID: account.accountID)
            reload()
        } catch {
            errorMessage = "Couldn't remove that account from your Keychain."
        }
    }
}
