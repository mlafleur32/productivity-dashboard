// Mail/InboxSetupSheet.swift
//
// First-time credential entry sheet. Three fields: email, app-specific
// password (SecureField), and IMAP server (host or host:port — port
// defaults to 993). The Save & Connect button stays disabled until all
// three validate cleanly. Per-field inline errors appear under any field
// that is non-empty but invalid — empty fields stay quiet until typed,
// so first-open is clean.
//
// On Save: build IMAPCredentials, hand off to onSave, best-effort clear
// the @State password to "", dismiss. The credential value lives on the
// stack of the onSave closure (which is expected to forward it to the
// view model's saveCredentials immediately). After dismiss, the view's
// @State storage is released by SwiftUI.
//
// Limitations (acceptable for Stage 3):
//   - We cannot guarantee Swift String memory is zeroed after dismiss.
//     Setting the @State to "" is best-effort; copy-on-write semantics
//     mean prior copies may persist until ARC releases them. The
//     credentials path more broadly is documented in MailTypes.swift.

import SwiftUI

struct InboxSetupSheet: View {
    let onSave: (IMAPCredentials) -> Void
    let onCancel: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var server = ""
    // Once the user types in the server field, stop suggesting over them.
    @State private var serverEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add an email account")
                .font(.title2).bold()
            Text("Any IMAP account works. The password is stored only in your Mac's Keychain and is never sent anywhere except your mail server.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            field(label: "Email") {
                TextField("you@example.com", text: $email)
                    .textContentType(.username)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: email) { _, newValue in
                        guard !serverEdited,
                              let suggestion = Self.suggestedServer(forEmail: newValue) else { return }
                        server = suggestion
                    }
            }
            inlineError(emailError)

            field(label: "Password") {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Gmail needs an app-specific password (Google Account ▸ Security). EarthLink and Mindspring use your normal one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            field(label: "Server") {
                TextField("imap.example.com", text: Binding(
                    get: { server },
                    set: { server = $0; serverEdited = true }))
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
            }
            inlineError(serverError)
            Text("Filled in for Gmail, EarthLink and Mindspring addresses. Port is optional and defaults to 993 (IMAPS).")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    password = ""
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save & Connect") {
                    guard case .success(let parsedEmail) = parseEmail(email),
                          case .success(let parsedServer) = parseServerInput(server) else {
                        return
                    }
                    let creds = IMAPCredentials(
                        server: parsedServer.host,
                        port: parsedServer.port,
                        account: parsedEmail,
                        password: password
                    )
                    password = ""
                    onSave(creds)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 440)
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).bold()
            content()
        }
    }

    @ViewBuilder
    private func inlineError(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Per-field validation displayed to the user

    private var emailError: String? {
        if email.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if case .failure(let err) = parseEmail(email) { return err.message }
        return nil
    }

    private var serverError: String? {
        if server.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if case .failure(let err) = parseServerInput(server) { return err.message }
        return nil
    }

    /// The IMAP server for providers this app has been validated against.
    /// Deliberately short: a wrong suggestion for an unknown provider is
    /// worse than an empty field, so anything else stays blank.
    nonisolated static func suggestedServer(forEmail email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...]
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch domain {
        case "gmail.com", "googlemail.com": return "imap.gmail.com"
        case "mindspring.com": return "imap.mindspring.com"
        case "earthlink.net": return "imap.earthlink.net"
        default: return nil
        }
    }

    private var isValid: Bool {
        guard case .success = parseEmail(email),
              case .success = parseServerInput(server) else {
            return false
        }
        return !password.isEmpty
    }
}

// MARK: - Validation types

struct ServerInput: Equatable {
    let host: String
    let port: Int
}

enum ServerInputError: Error, Equatable {
    case empty
    case emptyHost
    case nonNumericPort
    case portOutOfRange
    case tooManyColons
    case whitespaceInHost

    var message: String {
        switch self {
        case .empty:            return "Server is required."
        case .emptyHost:        return "Hostname is missing before the colon."
        case .nonNumericPort:   return "Port must be a number."
        case .portOutOfRange:   return "Port must be between 1 and 65535."
        case .tooManyColons:    return "Server should be host or host:port."
        case .whitespaceInHost: return "Hostname must not contain spaces."
        }
    }
}

enum EmailInputError: Error, Equatable {
    case empty
    case noAtSign
    case missingLocal
    case missingDomain

    var message: String {
        switch self {
        case .empty:         return "Email is required."
        case .noAtSign:      return "Email must contain '@'."
        case .missingLocal:  return "Missing the part before '@'."
        case .missingDomain: return "Email must have a domain with a '.' after '@'."
        }
    }
}

// Parses the server-input field. Accepts:
//   "imap.gmail.com"        → host=imap.gmail.com, port=993
//   "imap.gmail.com:993"    → host=imap.gmail.com, port=993
//   "  host:993  "          → trimmed, accepted
// Rejects: empty input, empty host, non-numeric port, out-of-range port
// (must be 1..65535), more than one colon, whitespace inside host.
func parseServerInput(_ raw: String) -> Result<ServerInput, ServerInputError> {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return .failure(.empty) }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count > 2 { return .failure(.tooManyColons) }

    let host = String(parts[0])
    if host.isEmpty { return .failure(.emptyHost) }
    if host.contains(where: { $0.isWhitespace }) { return .failure(.whitespaceInHost) }

    let port: Int
    if parts.count == 2 {
        let portStr = String(parts[1])
        guard let parsed = Int(portStr) else { return .failure(.nonNumericPort) }
        if parsed < 1 || parsed > 65535 { return .failure(.portOutOfRange) }
        port = parsed
    } else {
        port = 993
    }

    return .success(ServerInput(host: host, port: port))
}

// Parses the email field. Light validation — requires '@', a non-empty
// local part, and a domain containing '.'. Not RFC 5322 compliant; just
// enough to catch obvious typos before sending the value to LOGIN.
func parseEmail(_ raw: String) -> Result<String, EmailInputError> {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return .failure(.empty) }
    guard let atIdx = trimmed.firstIndex(of: "@") else { return .failure(.noAtSign) }
    let local = trimmed[..<atIdx]
    let domain = trimmed[trimmed.index(after: atIdx)...]
    if local.isEmpty { return .failure(.missingLocal) }
    if domain.isEmpty || !domain.contains(".") { return .failure(.missingDomain) }
    return .success(trimmed)
}
