// Mail/IMAPMailSource.swift
//
// The only file in the project that imports NIO / NIOSSL / NIOIMAP. Wraps
// the swift-nio-imap channel handler behind the MailSource protocol so the
// rest of the app stays NIO-free.
//
// See ARCHITECTURE.md "Dependencies" section for the rationale on swift-nio-imap's
// "not production-ready" disclaimer and our accepted-risk assessment. Do
// not add other NIO-family imports here without recording justification
// in that section.
//
// Connection lifecycle (per-fetch, never cached on the instance):
//   1. fetchRecent() calls credentialsStore.load() for a fresh Keychain read.
//   2. openConnectionAndLogin() builds an SSL+IMAP NIO channel and sends
//      LOGIN. The IMAPCredentials value is local to that helper and goes
//      out of Swift scope as soon as it returns.
//   3. fetchRecent() then runs SELECT INBOX → FETCH (UID ENVELOPE
//      INTERNALDATE) → LOGOUT and closes the channel.
// IMAPMailSource holds no credential state. Between fetches the password
// is in the macOS Keychain alone — nowhere in this process.

import Foundation
import NIO
import NIOPosix
import NIOSSL
import NIOIMAP
import NIOIMAPCore
import os

final class IMAPMailSource: MailSource {
    // Stage-marker diagnostics. Status only, per ARCHITECTURE.md Security &
    // Privacy: never the account, password, subjects, or senders.
    // nonisolated: Logger is Sendable/thread-safe, and the fetch runs in
    // nonisolated task-group children under this project's MainActor-by-
    // default isolation — without this, every log call would hop actors
    // (a Swift 6 error).
    private nonisolated static let log = Logger(
        subsystem: "LuminalMachines.ProductivityDashboard",
        category: "imap"
    )

    private let credentialsStore: CredentialsStore
    /// Which stored account this source speaks for (Stage 9). nil means
    /// "whichever account is first", the single-account behavior that
    /// previews, tests and a fresh install still rely on.
    private let accountID: String?

    nonisolated init(credentialsStore: CredentialsStore, accountID: String? = nil) {
        self.credentialsStore = credentialsStore
        self.accountID = accountID
    }

    /// One Keychain read, for THIS account. Kept in one place so every
    /// entry point (fetch, body, archive) resolves the same credential.
    private nonisolated func loadCredentials() throws -> IMAPCredentials {
        do {
            let loaded = accountID.map { try? credentialsStore.load(accountID: $0) } ?? (try? credentialsStore.load())
            guard let credentials = loaded ?? nil else {
                throw InboxError.notConfigured
            }
            return credentials
        } catch InboxError.notConfigured {
            throw InboxError.notConfigured
        }
    }

    func fetchRecent(limit: Int) async throws -> [MailMessage] {
        // Hard guard: never open a network connection from an Xcode preview
        // canvas. #Preview instantiates the real view tree — real
        // InboxViewModel, real Keychain read — and without this check the
        // canvas silently fetches the user's real inbox. Placed here, at
        // the app's single network choke point, rather than in preview
        // code, so no future #Preview can bypass it.
        if RealIOGuard.isBlocked {
            throw InboxError.notConfigured
        }

        let credentials = try loadCredentials()
        return try await runFetch(credentials: credentials, limit: limit)
    }

    private func runFetch(credentials: IMAPCredentials, limit: Int) async throws -> [MailMessage] {
        // Use the process-wide singleton event loop group. For a desktop app
        // doing per-fetch IMAP connections, the singleton avoids the
        // shutdownGracefully-from-async dance (defer can't await) and the
        // overhead of starting/stopping a thread per fetch.
        let group = MultiThreadedEventLoopGroup.singleton

        Self.log.info("connecting")
        let asyncChannel = try await Self.connect(
            group: group,
            host: credentials.server,
            port: credentials.port
        )
        Self.log.info("connected")

        // The group returns raw envelopes; mapping to MailMessage happens
        // after the session exits, back on the caller's isolation — passing
        // the MainActor-isolated toMailMessage into a nonisolated child
        // would cross an actor boundary (a Swift 6 error).
        let envelopes: [RawEnvelope] = try await Self.withSession(asyncChannel: asyncChannel) { iter, outbound in
            try await Self.awaitGreeting(iter: &iter)
            Self.log.info("greeting ok")
            try await Self.login(
                account: credentials.account,
                password: credentials.password,
                iter: &iter,
                outbound: outbound
            )
            Self.log.info("login ok")
            // credentials no longer used past this point
            let total = try await Self.openMailbox(.inbox, readOnly: true, iter: &iter, outbound: outbound)
            Self.log.info("examine ok, \(total, privacy: .public) messages exist")
            guard total > 0 else {
                try await Self.logout(iter: &iter, outbound: outbound)
                return []
            }
            let envelopes = try await Self.fetchEnvelopes(
                total: total,
                limit: limit,
                iter: &iter,
                outbound: outbound
            )
            Self.log.info("fetched \(envelopes.count, privacy: .public) envelopes")
            try await Self.logout(iter: &iter, outbound: outbound)
            Self.log.info("logout ok")
            return envelopes
        }
        // Derive the receiving server's authserv-id from the IMAP host so the
        // A-R parser trusts only that server's stamp. Unknown provider ⇒ nil
        // ⇒ no trusted verdict (fail-safe, never a guess).
        let authservID = AuthservIDMap.expectedAuthservID(forServer: credentials.server)
        return envelopes.map {
            Self.toMailMessage($0, expectedAuthservID: authservID,
                               accountID: credentials.accountID)
        }
    }

    // MARK: - Stage 5 lazy body fetch

    /// Fetch the plain-text body of one message by UID. Same per-call
    /// connection lifecycle as fetchRecent — nothing cached, credentials
    /// resident only for login. Two sequential UID FETCHes (content headers,
    /// then BODY.PEEK[TEXT]) so the single-body-section streaming assumption
    /// holds for each command; MIME decoding happens locally afterwards.
    func fetchBody(accountID: String?, imapUID: UInt32) async throws -> String? {
        // This source speaks for exactly one account. A UID addressed to a
        // different one must never be fetched here — UIDs are mailbox-local,
        // so the same number means a different message on another server.
        if let accountID, let mine = self.accountID, accountID != mine {
            Self.log.error("body fetch: UID addressed to another account — refused")
            throw InboxError.notConfigured
        }
        if RealIOGuard.isBlocked {
            throw InboxError.notConfigured
        }
        let credentials = try loadCredentials()

        Self.log.info("body fetch: connecting")
        let asyncChannel = try await Self.connect(
            group: MultiThreadedEventLoopGroup.singleton,
            host: credentials.server,
            port: credentials.port
        )

        let (headerBytes, bodyBytes) = try await Self.withSession(asyncChannel: asyncChannel) { iter, outbound in
            try await Self.awaitGreeting(iter: &iter)
            try await Self.login(
                account: credentials.account,
                password: credentials.password,
                iter: &iter,
                outbound: outbound
            )
            _ = try await Self.openMailbox(.inbox, readOnly: true, iter: &iter, outbound: outbound)
            let headers = try await Self.fetchUIDSection(
                uid: imapUID, tag: "b001", section: .contentHeaders,
                iter: &iter, outbound: outbound)
            let text = try await Self.fetchUIDSection(
                uid: imapUID, tag: "b002", section: .text,
                iter: &iter, outbound: outbound)
            try await Self.logout(iter: &iter, outbound: outbound)
            Self.log.info("body fetch: done (\(text.count, privacy: .public) bytes)")
            return (headers, text)
        }

        // Zero section bytes is TRANSIENT, never a permanent skip: it means
        // the UID vanished mid-cycle, interleaved traffic confused the
        // exchange, or (rarely) a genuinely body-less message. Throwing puts
        // the message on the retry-next-poll path — an extra IMAP fetch per
        // poll at worst, no API spend — instead of permanently writing off
        // mail we simply failed to read. nil (permanent skip) is reserved
        // for the extractor's verdict on real content: "no text/plain here".
        guard !bodyBytes.isEmpty else {
            Self.log.error("body fetch: empty section — transient, will retry")
            throw InboxError.unexpectedResponse
        }

        let parsed = MailHeaderParser.parse(String(decoding: headerBytes, as: UTF8.self))
        return MIMETextExtractor.plainText(
            contentType: parsed.first("content-type"),
            transferEncoding: parsed.first("content-transfer-encoding"),
            body: Data(bodyBytes)
        )
    }

    // MARK: - Channel setup

    private static func connect(
        group: EventLoopGroup,
        host: String,
        port: Int
    ) async throws -> NIOAsyncChannel<Response, IMAPClientHandler.Message> {
        do {
            let sslContext = try NIOSSLContext(configuration: .clientDefault)
            // NIOAsyncChannel(wrappingChannelSynchronously:) preconditions
            // that it runs on the channel's own event loop — constructing it
            // after an awaited connect (on a Swift-concurrency executor
            // thread) crashes every time. The connect(channelInitializer:)
            // overload runs this closure ON the loop, so both the pipeline
            // setup and the wrapping happen there.
            return try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(10))
                .connect(host: host, port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers([
                            try NIOSSLClientHandler(context: sslContext, serverHostname: host),
                            IMAPClientHandler()
                        ])
                        return try NIOAsyncChannel<Response, IMAPClientHandler.Message>(
                            wrappingChannelSynchronously: channel
                        )
                    }
                }
        } catch _ as NIOSSLError {
            log.error("connect failed: TLS")
            throw InboxError.tlsFailure
        } catch {
            log.error("connect failed: network")
            throw InboxError.networkUnreachable
        }
    }

    // MARK: - Command/response choreography

    private typealias Inbound = NIOAsyncChannelInboundStream<Response>
    private typealias Outbound = NIOAsyncChannelOutboundWriter<IMAPClientHandler.Message>

    // Deadline design (shared by fetchRecent and fetchBody). This replaces
    // an earlier task-group timeout that relied on cancellation and could
    // itself hang: a throwing task group does not return until EVERY child
    // finishes — cancelAll() is a request, not a guarantee — so a fetch
    // child blocked in a read that ignores cancellation blocked the group
    // (and the UI spinner) forever. The deadline child therefore
    // force-closes the channel instead: a closed channel terminates the
    // inbound stream, which unblocks every pending read in the exchange
    // child regardless of its cancellation behavior. Connect is bounded
    // separately by the bootstrap's explicit 10s connectTimeout.
    private static func withSession<T: Sendable>(
        asyncChannel: NIOAsyncChannel<Response, IMAPClientHandler.Message>,
        exchange: @escaping @Sendable (inout Inbound.AsyncIterator, Outbound) async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { taskGroup in
            taskGroup.addTask {
                try await asyncChannel.executeThenClose { inbound, outbound in
                    var iter = inbound.makeAsyncIterator()
                    return try await exchange(&iter, outbound)
                }
            }
            taskGroup.addTask {
                // Plain `try` (not `try?`): when the exchange finishes first
                // and the group cancels us, sleep must throw and skip the
                // close — otherwise we'd kill the next fetch's healthy
                // channel state and report a phantom timeout.
                try await Task.sleep(for: .seconds(10))
                Self.log.error("deadline (10s) hit — force-closing channel")
                asyncChannel.channel.close(promise: nil)
                throw InboxError.timedOut
            }
            guard let result = try await taskGroup.next() else {
                throw InboxError.timedOut
            }
            taskGroup.cancelAll()
            return result
        }
    }

    private static func awaitGreeting(iter: inout Inbound.AsyncIterator) async throws {
        guard let first = try await iter.next() else {
            throw InboxError.connectionDropped
        }
        // Server greeting is an untagged OK. Anything else (BYE, NO) means
        // refusal; surface as networkUnreachable since the connection is
        // up but the server didn't welcome us.
        switch first {
        case .untagged(.conditionalState(.ok)):
            return
        case .untagged(.conditionalState(.bye)):
            throw InboxError.rateLimited
        default:
            throw InboxError.unexpectedResponse
        }
    }

    private static func login(
        account: String,
        password: String,
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws {
        let tag = "a001"
        try await outbound.write(.part(.tagged(
            TaggedCommand(tag: tag, command: .login(username: account, password: password))
        )))
        switch try await awaitTagged(tag: tag, iter: &iter) {
        case .ok: return
        case .no, .bad:
            log.error("login rejected by server")
            throw InboxError.loginFailed
        }
    }

    /// Open a mailbox. The fetch paths pass readOnly: true (EXAMINE) so the
    /// read pipeline is physically incapable of mailbox writes — Stage 6
    /// hardening; before archive existed, this used SELECT everywhere.
    /// Only the archive/unarchive executors open read-write (SELECT), and
    /// both sit behind the confirmation gate (unarchive transitively: it is
    /// only reachable from an Undo click on an entry a confirmed archive
    /// logged).
    private static func openMailbox(
        _ mailbox: MailboxName,
        readOnly: Bool,
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws -> Int {
        let tag = "a002"
        let command: Command = readOnly ? .examine(mailbox, []) : .select(mailbox, [])
        try await outbound.write(.part(.tagged(
            TaggedCommand(tag: tag, command: command)
        )))
        var existsCount = 0
        while let response = try await iter.next() {
            switch response {
            case .untagged(.mailboxData(.exists(let n))):
                existsCount = Int(n)
            case .tagged(let tagged) where tagged.tag == tag:
                switch tagged.state {
                case .ok: return existsCount
                case .no, .bad: throw InboxError.unexpectedResponse
                }
            default:
                continue
            }
        }
        throw InboxError.connectionDropped
    }

    private static func fetchEnvelopes(
        total: Int,
        limit: Int,
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws -> [RawEnvelope] {
        let lo = max(1, total - limit + 1)
        let hi = total
        let range = SequenceNumber(rawValue: UInt32(lo)) ... SequenceNumber(rawValue: UInt32(hi))
        // The set is provably non-empty (caller guards total > 0, so
        // lo <= hi), but guard rather than force-unwrap: if a refactor ever
        // breaks that invariant, fail as a reported error, not a crash.
        guard let fetchSet = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(range)) else {
            throw InboxError.unexpectedResponse
        }
        let tag = "a003"
        try await outbound.write(.part(.tagged(
            TaggedCommand(
                tag: tag,
                command: .fetch(
                    .set(fetchSet),
                    [
                        .uid, .envelope, .internalDate,
                        // BODY.PEEK[HEADER.FIELDS (...)] — peek so we don't set
                        // the \Seen flag (read-only dashboard). Arrives as a
                        // streaming body section, accumulated below.
                        .bodySection(peek: true, .headerFields(Self.fetchedHeaderFields), nil),
                    ],
                    []
                )
            )
        )))

        var envelopes: [RawEnvelope] = []
        var current = RawEnvelope()
        while let response = try await iter.next() {
            switch response {
            case .fetch(.start(_)):
                current = RawEnvelope()
            case .fetch(.simpleAttribute(let attr)):
                current.absorb(attr)
            case .fetch(.streamingBytes(var buffer)):
                // Header-section bytes. We request exactly one body section
                // (the header fields), so all streamed bytes in a message
                // belong to it; accumulate them.
                if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    current.headerBytes.append(contentsOf: bytes)
                }
            case .fetch(.finish):
                if let _ = current.uid {
                    envelopes.append(current)
                }
            case .tagged(let tagged) where tagged.tag == tag:
                switch tagged.state {
                case .ok: return envelopes
                case .no, .bad: throw InboxError.unexpectedResponse
                }
            default:
                continue
            }
        }
        throw InboxError.connectionDropped
    }

    // Which body section a UID fetch pulls. A tiny closed enum (rather than
    // parameterizing over NIOIMAP's section types) keeps the pre-1.0
    // library's type surface contained to the switch below.
    private enum BodySectionRequest {
        case contentHeaders  // Content-Type + Content-Transfer-Encoding
        case text            // BODY[TEXT] — the raw MIME body
    }

    private static func fetchUIDSection(
        uid: UInt32,
        tag: String,
        section: BodySectionRequest,
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws -> [UInt8] {
        let uidValue = UID(rawValue: uid)
        guard let uidSet = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(uidValue ... uidValue)) else {
            throw InboxError.unexpectedResponse
        }
        // BODY.PEEK throughout — the dashboard is read-only and must never
        // set \Seen (same rule as the envelope fetch).
        let command: Command
        switch section {
        case .contentHeaders:
            command = .uidFetch(
                .set(uidSet),
                [.bodySection(peek: true, .headerFields(["Content-Type", "Content-Transfer-Encoding"]), nil)],
                [])
        case .text:
            command = .uidFetch(
                .set(uidSet),
                [.bodySection(peek: true, .text, nil)],
                [])
        }
        try await outbound.write(.part(.tagged(TaggedCommand(tag: tag, command: command))))

        // Accumulation is wipe-proof: `current` collects one FETCH response's
        // streamed bytes; `collected` keeps the response that actually
        // carried section data. Gmail pushes UNSOLICITED `* N FETCH (FLAGS …)`
        // responses into a session when another session (webmail, a phone)
        // changes a flag on a message in the selected mailbox — such a
        // response arriving after ours must not zero out data we already
        // received. (Field bug: a read-in-Gmail test message analyzed as
        // "0 bytes" because the naive reset on every .fetch(.start) wiped
        // the body when a flag-update FETCH trailed it.)
        var collected: [UInt8] = []
        var current: [UInt8] = []
        var fetchResponseCount = 0
        // Shape diagnostics only — response CASE names and byte counts, never
        // content (privacy rules). Tells apart "no data arrived" from "data
        // arrived in a shape this loop drops".
        var shape: [String] = []
        while let response = try await iter.next() {
            switch response {
            case .fetch(.start):
                fetchResponseCount += 1
                shape.append("start")
                current = []
            case .fetch(.streamingBegin(_, let byteCount)):
                shape.append("begin(\(byteCount))")
            case .fetch(.streamingEnd):
                shape.append("end")
            case .fetch(.simpleAttribute):
                shape.append("attr")
            case .fetch(.streamingBytes(var buffer)):
                // One body section per command by construction, so all
                // streamed bytes within a response belong to it (do not add
                // a second section to either command above without reworking
                // this accumulation).
                if let b = buffer.readBytes(length: buffer.readableBytes) {
                    current.append(contentsOf: b)
                }
            case .fetch(.finish):
                shape.append("finish")
                if !current.isEmpty { collected = current }
                current = []
            case .tagged(let tagged) where tagged.tag == tag:
                switch tagged.state {
                case .ok:
                    // Belt and braces: if the tagged OK arrives before a
                    // .finish (or the server ends the response after
                    // .streamingEnd), keep what this response streamed
                    // instead of returning nothing.
                    if collected.isEmpty && !current.isEmpty { collected = current }
                    // Status-only diagnostics; distinguishes "server sent no
                    // FETCH at all" (UID gone) from "FETCH carried no bytes"
                    // if the empty-body path ever recurs.
                    if fetchResponseCount == 0 {
                        Self.log.error("uid fetch \(tag, privacy: .public): no FETCH response — uid likely gone")
                    } else if collected.isEmpty {
                        Self.log.error("uid fetch \(tag, privacy: .public): \(fetchResponseCount, privacy: .public) FETCH response(s), zero section bytes [\(shape.joined(separator: ","), privacy: .public)]")
                    } else if fetchResponseCount > 1 {
                        Self.log.info("uid fetch \(tag, privacy: .public): \(fetchResponseCount, privacy: .public) FETCH responses (unsolicited traffic interleaved)")
                    }
                    return collected
                case .no, .bad:
                    throw InboxError.unexpectedResponse
                }
            default:
                continue
            }
        }
        throw InboxError.connectionDropped
    }

    // MARK: - Stage 6 archive (the app's ONLY mailbox write)

    /// Every mailbox this account has, for the Settings picker. Read-only
    /// and nothing else: no SELECT, no writes.
    func listMailboxes() async throws -> [String] {
        if RealIOGuard.isBlocked {
            throw InboxError.notConfigured
        }
        let credentials = try loadCredentials()
        let asyncChannel = try await Self.connect(
            group: MultiThreadedEventLoopGroup.singleton,
            host: credentials.server,
            port: credentials.port
        )
        return try await Self.withSession(asyncChannel: asyncChannel) { iter, outbound in
            try await Self.awaitGreeting(iter: &iter)
            try await Self.login(account: credentials.account,
                                 password: credentials.password,
                                 iter: &iter, outbound: outbound)
            let names = try await Self.listAllMailboxes(iter: &iter, outbound: outbound)
            try await Self.logout(iter: &iter, outbound: outbound)
            return names
        }
    }

    /// One LIST, in either dialect. `specialUse` adds RETURN (SPECIAL-USE)
    /// — RFC 6154 — which is how Gmail is asked to name its All Mail
    /// folder. Older servers (EarthLink, field-tested 2026-10-25) do not
    /// implement it and REJECT the command outright, which is why every
    /// caller must be ready to fall back to the plain form.
    private static func listMailboxes(
        specialUse: Bool,
        tag: String,
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws -> (names: [String], all: MailboxName?, archive: MailboxName?) {
        // Two wire forms, and the difference is the bug this fixes. A
        // pattern LIST — .pattern([...]) — goes out as `LIST "" ("*")`,
        // the parenthesised multi-pattern syntax of LIST-EXTENDED (RFC
        // 5258). Gmail speaks it; EarthLink rejects it outright, which made
        // even the "plain" listing fail there (field bug, 2026-11-12). The
        // classic RFC 3501 form is a single bare pattern: `LIST "" "*"`.
        // RETURN (SPECIAL-USE) is itself an extended form, so only that
        // path uses the pattern list.
        let patterns: MailboxPatterns = specialUse
            ? .pattern([ByteBuffer(string: "*")])
            : .mailbox(ByteBuffer(string: "*"))
        try await outbound.write(.part(.tagged(TaggedCommand(
            tag: tag,
            command: .list(nil, reference: MailboxName([]), patterns,
                           specialUse ? [.specialUse] : [])
        ))))
        var names: [String] = []
        var all: MailboxName?
        var archive: MailboxName?
        while let response = try await iter.next() {
            switch response {
            case .untagged(.mailboxData(.list(let info))):
                names.append(String(decoding: info.path.name.bytes, as: UTF8.self))
                if info.attributes.contains(.init(#"\All"#)) { all = info.path.name }
                if info.attributes.contains(.init(#"\Archive"#)) { archive = info.path.name }
            case .tagged(let tagged) where tagged.tag == tag:
                switch tagged.state {
                case .ok: return (names, all, archive)
                case .no, .bad: throw InboxError.unexpectedResponse
                }
            default:
                continue
            }
        }
        throw InboxError.connectionDropped
    }

    /// Mailbox names for the Settings picker, in the classic RFC 3501 form
    /// every IMAP server understands. No fallback: a server that refuses
    /// the basic form will not accept an extended one, and retrying on a
    /// stream that just failed mid-response is not safe anyway.
    private static func listAllMailboxes(
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws -> [String] {
        do {
            return try await listMailboxes(specialUse: false, tag: "a009",
                                           iter: &iter, outbound: outbound).names
        } catch {
            // The error's TYPE only — a parser error can quote raw bytes,
            // which here would be the user's folder names.
            log.error("mailbox list failed: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }

    /// Discover where "archive" puts a message, via RFC 6154 SPECIAL-USE:
    /// prefer the \All mailbox (Gmail — archive means "remove from INBOX",
    /// the message lives on in All Mail), else \Archive (generic servers
    /// with a dedicated archive folder). Discovery by ATTRIBUTE, never by
    /// name — "[Gmail]/All Mail" is localized per account language. No
    /// match ⇒ archiveFailed: refusing beats guessing at a mailbox name.
    private static func discoverArchiveDestination(
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws -> MailboxName {
        let result: (names: [String], all: MailboxName?, archive: MailboxName?)
        do {
            result = try await listMailboxes(specialUse: true, tag: "a005",
                                             iter: &iter, outbound: outbound)
        } catch {
            // The server doesn't implement RFC 6154 and refused the
            // command. It cannot tell us which folder archives mail, and
            // guessing a name is exactly what this app does not do — so
            // ask the user to name it once, in Settings.
            log.error("archive: the server refused RETURN (SPECIAL-USE) — no destination it can name")
            throw InboxError.archiveNoDestination
        }
        guard let destination = result.all ?? result.archive else {
            log.error("archive: \(result.names.count, privacy: .public) mailbox(es) listed, none flagged \\All or \\Archive")
            throw InboxError.archiveNoDestination
        }
        return destination
    }

    /// UID MOVE one message out of INBOX. Returns the message's new UID in
    /// the destination when the server reports UIDPLUS COPYUID — per RFC
    /// 6851 that arrives on an UNTAGGED OK before the move completes, but
    /// some servers put it on the tagged OK, so both are checked. The move
    /// also triggers untagged EXPUNGE traffic; anything unrecognized is
    /// skipped, same discipline as the fetch loops.
    private static func moveUID(
        _ uid: UInt32,
        to destination: MailboxName,
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws -> UInt32? {
        let tag = "a006"
        let uidValue = UID(rawValue: uid)
        guard let uidSet = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(uidValue ... uidValue)) else {
            throw InboxError.archiveFailed
        }
        try await outbound.write(.part(.tagged(
            TaggedCommand(tag: tag, command: .uidMove(.set(uidSet), destination))
        )))
        var newUID: UInt32?
        while let response = try await iter.next() {
            switch response {
            case .untagged(.conditionalState(.ok(let text))):
                if case .uidCopy(let copy) = text.code {
                    newUID = copy.destinationUIDs.first?.range.lowerBound.rawValue
                }
            case .tagged(let tagged) where tagged.tag == tag:
                switch tagged.state {
                case .ok(let text):
                    if case .uidCopy(let copy) = text.code {
                        newUID = copy.destinationUIDs.first?.range.lowerBound.rawValue
                    }
                    return newUID
                case .no, .bad:
                    log.error("archive: UID MOVE rejected")
                    throw InboxError.archiveFailed
                }
            default:
                continue
            }
        }
        throw InboxError.connectionDropped
    }

    private static func logout(
        iter: inout Inbound.AsyncIterator,
        outbound: Outbound
    ) async throws {
        let tag = "a004"
        try await outbound.write(.part(.tagged(
            TaggedCommand(tag: tag, command: .logout)
        )))
        // Spec says server sends * BYE then tagged OK. We tolerate either order.
        while let response = try await iter.next() {
            switch response {
            case .tagged(let tagged) where tagged.tag == tag:
                return
            default:
                continue
            }
        }
    }

    private enum TaggedStatus {
        case ok
        case no
        case bad
    }

    private static func awaitTagged(
        tag: String,
        iter: inout Inbound.AsyncIterator
    ) async throws -> TaggedStatus {
        while let response = try await iter.next() {
            if case .tagged(let tagged) = response, tagged.tag == tag {
                switch tagged.state {
                case .ok:  return .ok
                case .no:  return .no
                case .bad: return .bad
                }
            }
        }
        throw InboxError.connectionDropped
    }

    // MARK: - Envelope assembly + mapping

    // Header field names requested via BODY.PEEK[HEADER.FIELDS (...)] and
    // consumed by the local rules engine. Authentication-Results carries the
    // trusted SPF/DKIM/DMARC verdict (see AuthenticationResults).
    // List-Unsubscribe-Post (Stage 7) is the RFC 8058 one-click marker —
    // header-only, a few bytes per message; added deliberately per the
    // THREAT_PATTERNS.md data-access backlog discipline.
    // Header fields fetched with every envelope. The second group feeds
    // HeaderForensics (sender-identity checks, computed on this Mac); they
    // are compared locally and never sent anywhere — only the app's own
    // findings travel, and only for an allowlisted sender.
    private static let fetchedHeaderFields = [
        "List-Unsubscribe", "List-Unsubscribe-Post", "List-Id", "Precedence",
        "Authentication-Results",
        "Return-Path", "Reply-To", "DKIM-Signature",
    ]

    private struct RawEnvelope {
        var uid: UInt32?
        var envelope: Envelope?
        var internalDate: Date?
        var headerBytes: [UInt8] = []

        mutating func absorb(_ attr: MessageAttribute) {
            switch attr {
            case .uid(let uid):
                self.uid = uid.rawValue
            case .envelope(let env):
                self.envelope = env
            case .internalDate(let date):
                self.internalDate = date.asNativeDate
            default:
                break
            }
        }
    }

    private static func toMailMessage(
        _ raw: RawEnvelope,
        expectedAuthservID: String?,
        accountID: String?
    ) -> MailMessage {
        let env = raw.envelope
        // env.from is [EmailAddressListElement]; the list element is an enum
        // wrapping either a single address or a nested group. We take the
        // first single-address only — groups (RFC 5322 "name: ...;") are rare
        // in modern mail and we don't try to flatten them at Stage 3.
        let firstAddress: EmailAddress? = {
            guard case .singleAddress(let addr) = env?.from.first else { return nil }
            return addr
        }()
        let fromName = firstAddress?.personName.map { EncodedWord.decode(String(buffer: $0)) }
        let fromAddress: String = {
            guard let mailbox = firstAddress?.mailbox.map({ String(buffer: $0) }),
                  let host = firstAddress?.host.map({ String(buffer: $0) }) else {
                return "(unknown sender)"
            }
            return "\(mailbox)@\(host)"
        }()
        let subject = env?.subject.map { EncodedWord.decode(String(buffer: $0)) } ?? "(no subject)"
        let messageId = env?.messageID.map { String($0) }

        // Parse the fetched header block. Headers are ASCII/UTF-8; decode
        // leniently so a stray byte doesn't drop the whole block.
        let headerText = String(decoding: raw.headerBytes, as: UTF8.self)
        let headers = MailHeaderParser.parse(headerText)
        // Authentication-Results is trusted ONLY when we know the receiving
        // server's authserv-id (Gmail today). Unknown provider ⇒ nil verdict,
        // never a guess. Multiple A-R values pass in delivered order so the
        // parser's topmost-wins anti-forgery rule applies.
        let authentication = expectedAuthservID.flatMap {
            AuthenticationResults.parse(
                headerValues: headers.all("authentication-results"),
                expectedAuthservID: $0
            )
        }

        let forensics = HeaderForensics.evaluate(
            fromAddress: fromAddress,
            fromName: fromName,
            headers: headers,
            trustedAuthPresent: authentication != nil)

        return MailMessage(
            id: messageId ?? "uid-\(raw.uid ?? 0)",
            fromName: fromName,
            fromAddress: fromAddress,
            subject: subject,
            date: raw.internalDate ?? Date(),
            listUnsubscribe: headers.first("list-unsubscribe"),
            listUnsubscribePost: headers.first("list-unsubscribe-post"),
            listId: headers.first("list-id"),
            precedence: headers.first("precedence"),
            authentication: authentication,
            imapUID: raw.uid,
            accountID: accountID,
            forensics: forensics
        )
    }
}

// MARK: - MailArchiving (Stage 6)

// The ONLY implementation of the write boundary, and the only place in the
// app that opens a mailbox read-write. The signature is the gate:
// ConfirmedArchiveAction can be minted solely by ArchiveConfirmationFlow
// (see ArchiveConfirmation.swift), so this code is unreachable without an
// explicit user confirmation — by construction, not by convention.
extension IMAPMailSource: MailArchiving {
    func archive(_ action: ConfirmedArchiveAction) async throws -> ArchiveReceipt {
        // Same hard canvas guard as every network entry point.
        if RealIOGuard.isBlocked {
            throw InboxError.notConfigured
        }
        // UIDs are in-memory only; a message without one (stale row across
        // a UIDVALIDITY change, non-IMAP source) cannot be archived safely.
        guard let uid = action.message.imapUID else {
            Self.log.error("archive: message has no IMAP UID")
            throw InboxError.archiveFailed
        }

        let credentials = try loadCredentials()

        Self.log.info("archive: connecting")
        let asyncChannel = try await Self.connect(
            group: MultiThreadedEventLoopGroup.singleton,
            host: credentials.server,
            port: credentials.port
        )

        let messageID = action.message.id
        let receipt: ArchiveReceipt = try await Self.withSession(asyncChannel: asyncChannel) { iter, outbound in
            try await Self.awaitGreeting(iter: &iter)
            try await Self.login(
                account: credentials.account,
                password: credentials.password,
                iter: &iter,
                outbound: outbound
            )
            // A folder the user picked for THIS account (from the
            // server's own list) wins over discovery; otherwise ask the
            // server for its \All / \Archive flags as before.
            let destination: MailboxName
            if let chosen = ArchiveMailboxPreference.mailbox(for: self.accountID) {
                Self.log.info("archive: using the folder chosen for this account")
                destination = MailboxName(Array(chosen.utf8))
            } else {
                destination = try await Self.discoverArchiveDestination(iter: &iter, outbound: outbound)
            }
            // Read-write on purpose — this is the one SELECT in the app.
            _ = try await Self.openMailbox(.inbox, readOnly: false, iter: &iter, outbound: outbound)
            let newUID = try await Self.moveUID(uid, to: destination, iter: &iter, outbound: outbound)
            try await Self.logout(iter: &iter, outbound: outbound)
            return ArchiveReceipt(
                messageID: messageID,
                archivedTo: String(decoding: destination.bytes, as: UTF8.self),
                newUID: newUID
            )
        }
        Self.log.info("archive: done (new uid \(receipt.newUID.map(String.init) ?? "unreported", privacy: .public))")
        return receipt
    }

    /// Undo one archive: UID MOVE the message from the archive mailbox back
    /// to INBOX, using the COPYUID handle the archive receipt reported.
    /// Reachable only from an Undo click on a logged entry — restoring the
    /// pre-action state needs no dialog (see MailArchiving). Throws
    /// archiveFailed when the handle has gone stale (UIDVALIDITY change,
    /// message moved by another client) — the message is still findable in
    /// the archive mailbox either way; nothing is ever lost.
    func unarchive(accountID: String?, newUID: UInt32, from mailbox: String) async throws {
        if let accountID, let mine = self.accountID, accountID != mine {
            Self.log.error("unarchive: addressed to another account — refused")
            throw InboxError.archiveFailed
        }
        if RealIOGuard.isBlocked {
            throw InboxError.notConfigured
        }
        let credentials = try loadCredentials()

        Self.log.info("unarchive: connecting")
        let asyncChannel = try await Self.connect(
            group: MultiThreadedEventLoopGroup.singleton,
            host: credentials.server,
            port: credentials.port
        )

        try await Self.withSession(asyncChannel: asyncChannel) { iter, outbound in
            try await Self.awaitGreeting(iter: &iter)
            try await Self.login(
                account: credentials.account,
                password: credentials.password,
                iter: &iter,
                outbound: outbound
            )
            let source = MailboxName(Array(mailbox.utf8))
            let opened = try await Self.openMailbox(source, readOnly: false, iter: &iter, outbound: outbound)
            guard opened > 0 else {
                Self.log.error("unarchive: source mailbox is empty")
                throw InboxError.archiveFailed
            }
            // A UID MOVE that matches nothing still gets a tagged OK — but a
            // real move on a UIDPLUS server reports COPYUID. This handle only
            // exists because COPYUID worked on the way out, so its absence on
            // the way back means the message wasn't where the handle said
            // (stale UID). Throw so the log entry is NOT marked undone.
            guard try await Self.moveUID(newUID, to: .inbox, iter: &iter, outbound: outbound) != nil else {
                Self.log.error("unarchive: no COPYUID — stale handle, message not moved")
                throw InboxError.archiveFailed
            }
            try await Self.logout(iter: &iter, outbound: outbound)
        }
        Self.log.info("unarchive: done")
    }
}

// Bridges swift-nio-imap's ServerMessageDate (the type that backs IMAP's
// INTERNALDATE response) to Foundation.Date. The library hands us a
// Components struct with plain Int fields; we map them through DateComponents.
private extension ServerMessageDate {
    var asNativeDate: Date? {
        var dc = DateComponents()
        dc.year = self.components.year
        dc.month = self.components.month
        dc.day = self.components.day
        dc.hour = self.components.hour
        dc.minute = self.components.minute
        dc.second = self.components.second
        dc.timeZone = TimeZone(secondsFromGMT: self.components.zoneMinutes * 60)
        return Calendar(identifier: .gregorian).date(from: dc)
    }
}
