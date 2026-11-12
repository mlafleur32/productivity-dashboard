//
//  ClaudeAnalyzerTests.swift
//  ProductivityDashboardTests
//
//  The analyzer suite. Everything runs against a fake transport — no test
//  here can open a socket. The security-relevant assertions:
//    - stripping happens INSIDE the analyzer: quoted/signature content
//      handed in as rawBody never appears in the serialized request
//    - a missing/empty/unreadable API key means the transport is never
//      invoked at all (fail-safe before any request exists)
//    - every failure mode maps to a typed error the pipeline treats as
//      "no cloud verdict"
//
//  CloudEligibleMessage can only be built through the real gate
//  (fileprivate init), so the helper below goes through CloudAllowlist —
//  the tests exercise the same construction path production will.
//

import Testing
import Foundation
@testable import ProductivityDashboard

// @MainActor: the app target defaults to MainActor isolation, so its
// types (and their conformances) are main-actor-isolated; running the
// suite there too removes the cross-isolation warnings (cleanup pass).
@MainActor
struct ClaudeAnalyzerTests {

    // MARK: - Fakes

    final class FakeTransport: HTTPTransport, @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var result: Result<(Data, HTTPURLResponse), Error>

        init(_ result: Result<(Data, HTTPURLResponse), Error>) {
            self.result = result
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            return try result.get()
        }
    }

    struct FakeKeyStore: APIKeyStoring {
        var key: String?
        var loadThrows = false
        func save(_ key: String) throws {}
        func load() throws -> String? {
            if loadThrows { throw CredentialsError.keychainError(-1) }
            return key
        }
        func delete() throws {}
    }

    struct FakeReader: AllowlistReading {
        let eligible: Set<String>
        func cloudEligibleSenders() -> Set<String> { eligible }
    }

    final class SpyUsageRecorder: UsageRecording, @unchecked Sendable {
        private(set) var records: [(input: Int, output: Int, model: CloudModel)] = []
        func record(inputTokens: Int, outputTokens: Int, model: CloudModel) {
            records.append((inputTokens, outputTokens, model))
        }
    }

    // MARK: - Helpers

    private func eligibleMessage(
        subject: String = "Quarterly review",
        from: String = "alice@firm.example"
    ) -> CloudEligibleMessage {
        let msg = MailMessage(
            id: UUID().uuidString,
            fromName: "Alice Chen",
            fromAddress: from,
            subject: subject,
            date: .now
        )
        // Through the real gate — the only way to mint the type.
        return CloudAllowlist.filter([msg], using: FakeReader(eligible: [from])).first!
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// A canned API envelope whose text block carries the verdict JSON.
    /// Includes a usage block by default, as the real API always does.
    private func envelope(
        verdictText: String, stopReason: String = "end_turn",
        inputTokens: Int = 700, outputTokens: Int = 60
    ) -> Data {
        let obj: [String: Any] = [
            "content": [["type": "text", "text": verdictText]],
            "stop_reason": stopReason,
            "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private let goodVerdictText = """
    {"importance":"important","scam":"clean","tasks":[{"title":"Send the Q3 numbers","due_hint":"by Friday"}]}
    """

    private func analyzer(
        key: String? = "sk-ant-test-key",
        keyThrows: Bool = false,
        transport: FakeTransport,
        model: CloudModel = .opus48,
        usageRecorder: UsageRecording? = nil
    ) -> ClaudeAnalyzer {
        ClaudeAnalyzer(
            keyStore: FakeKeyStore(key: key, loadThrows: keyThrows),
            transport: transport,
            model: { model },
            usageRecorder: usageRecorder ?? SpyUsageRecorder())
    }

    // MARK: - Happy path

    @Test("Decodes a structured verdict end to end")
    func happyPath() async throws {
        let transport = FakeTransport(.success((envelope(verdictText: goodVerdictText), httpResponse(status: 200))))
        let verdict = try await analyzer(transport: transport)
            .analyze(eligibleMessage(), rawBody: "Please send the Q3 numbers by Friday.")

        #expect(verdict.importance == .important)
        #expect(verdict.scam == .clean)
        #expect(verdict.tasks == [.init(title: "Send the Q3 numbers", dueHint: "by Friday")])
    }

    @Test("Request carries endpoint, auth header, version, and selected model")
    func requestShape() async throws {
        let transport = FakeTransport(.success((envelope(verdictText: goodVerdictText), httpResponse(status: 200))))
        _ = try await analyzer(key: "sk-ant-shape-key", transport: transport, model: .haiku45)
            .analyze(eligibleMessage(subject: "Subject line here"), rawBody: "Body text.")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-shape-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-4-5")
        #expect(json["system"] is String)
        // Structured output constraint present
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["schema"] is [String: Any])
        // No sampling params, no thinking config — rejected on current models
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["thinking"] == nil)
        // Subject and body made it into the user turn
        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? String)
        #expect(content.contains("Subject line here"))
        #expect(content.contains("Body text."))
    }

    // MARK: - Stripping is enforced inside the analyzer

    @Test("Quoted thread and signature content never reaches the request")
    func strippingEnforcedInternally() async throws {
        let transport = FakeTransport(.success((envelope(verdictText: goodVerdictText), httpResponse(status: 200))))
        let rawBody = """
        Please review the attached draft.

        On Mon, Jun 1, 2026 at 9:00 AM Sam Reyes <sam@example.com> wrote:
        > QUOTED-THREAD-CANARY do not transmit
        --
        SIGNATURE-CANARY Example Corp
        """
        _ = try await analyzer(transport: transport)
            .analyze(eligibleMessage(), rawBody: rawBody)

        let bodyString = String(data: try #require(transport.requests.first?.httpBody), encoding: .utf8)!
        #expect(bodyString.contains("Please review the attached draft."))
        #expect(!bodyString.contains("QUOTED-THREAD-CANARY"))
        #expect(!bodyString.contains("SIGNATURE-CANARY"))
    }

    // MARK: - Fail-safe: no key, no request

    @Test("Missing API key throws notConfigured and never touches the transport")
    func missingKeyNeverSends() async {
        let transport = FakeTransport(.success((Data(), httpResponse(status: 200))))
        await #expect(throws: CloudAnalysisError.notConfigured) {
            _ = try await analyzer(key: nil, transport: transport)
                .analyze(eligibleMessage(), rawBody: "body")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Whitespace-only key is treated as missing")
    func emptyKeyNeverSends() async {
        let transport = FakeTransport(.success((Data(), httpResponse(status: 200))))
        await #expect(throws: CloudAnalysisError.notConfigured) {
            _ = try await analyzer(key: "   ", transport: transport)
                .analyze(eligibleMessage(), rawBody: "body")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Keychain read failure is fail-safe: notConfigured, no request")
    func keyReadFailureNeverSends() async {
        let transport = FakeTransport(.success((Data(), httpResponse(status: 200))))
        await #expect(throws: CloudAnalysisError.notConfigured) {
            _ = try await analyzer(key: "irrelevant", keyThrows: true, transport: transport)
                .analyze(eligibleMessage(), rawBody: "body")
        }
        #expect(transport.requests.isEmpty)
    }

    // MARK: - HTTP status mapping

    @Test("HTTP statuses map to typed errors", arguments: [
        (400, CloudAnalysisError.invalidRequest),
        (401, CloudAnalysisError.authenticationFailed),
        (403, CloudAnalysisError.authenticationFailed),
        (429, CloudAnalysisError.rateLimited),
        (500, CloudAnalysisError.serverError),
        (529, CloudAnalysisError.serverError),
    ])
    func statusMapping(_ status: Int, _ expected: CloudAnalysisError) async {
        let transport = FakeTransport(.success((Data(), httpResponse(status: status))))
        await #expect(throws: expected) {
            _ = try await analyzer(transport: transport)
                .analyze(eligibleMessage(), rawBody: "body")
        }
    }

    // MARK: - Response handling

    @Test("A refusal stop reason maps to .refused, not a crash or a verdict")
    func refusalHandled() async {
        let transport = FakeTransport(.success((envelope(verdictText: "", stopReason: "refusal"), httpResponse(status: 200))))
        await #expect(throws: CloudAnalysisError.refused) {
            _ = try await analyzer(transport: transport)
                .analyze(eligibleMessage(), rawBody: "body")
        }
    }

    @Test("Undecodable verdict text maps to .invalidResponse")
    func malformedVerdict() async {
        let transport = FakeTransport(.success((envelope(verdictText: "not json at all"), httpResponse(status: 200))))
        await #expect(throws: CloudAnalysisError.invalidResponse) {
            _ = try await analyzer(transport: transport)
                .analyze(eligibleMessage(), rawBody: "body")
        }
    }

    @Test("Undecodable envelope maps to .invalidResponse")
    func malformedEnvelope() async {
        let transport = FakeTransport(.success((Data("<html>gateway error</html>".utf8), httpResponse(status: 200))))
        await #expect(throws: CloudAnalysisError.invalidResponse) {
            _ = try await analyzer(transport: transport)
                .analyze(eligibleMessage(), rawBody: "body")
        }
    }

    @Test("Transport failure maps to .networkFailure")
    func transportFailure() async {
        let transport = FakeTransport(.failure(URLError(.notConnectedToInternet)))
        await #expect(throws: CloudAnalysisError.networkFailure) {
            _ = try await analyzer(transport: transport)
                .analyze(eligibleMessage(), rawBody: "body")
        }
    }

    // MARK: - Usage recording (2026-07-05 follow-up)

    @Test("A successful analysis records the response's usage with the serving model")
    func usageRecordedOnSuccess() async throws {
        let transport = FakeTransport(.success((
            envelope(verdictText: goodVerdictText, inputTokens: 1234, outputTokens: 88),
            httpResponse(status: 200))))
        let spy = SpyUsageRecorder()
        _ = try await analyzer(transport: transport, model: .haiku45, usageRecorder: spy)
            .analyze(eligibleMessage(), rawBody: "body")

        let record = try #require(spy.records.first)
        #expect(spy.records.count == 1)
        #expect(record.input == 1234)
        #expect(record.output == 88)
        #expect(record.model == .haiku45)
    }

    @Test("A refusal still records usage — the API billed those tokens")
    func usageRecordedOnRefusal() async {
        let transport = FakeTransport(.success((
            envelope(verdictText: "", stopReason: "refusal", inputTokens: 500, outputTokens: 5),
            httpResponse(status: 200))))
        let spy = SpyUsageRecorder()
        await #expect(throws: CloudAnalysisError.refused) {
            _ = try await analyzer(transport: transport, usageRecorder: spy)
                .analyze(eligibleMessage(), rawBody: "body")
        }
        #expect(spy.records.count == 1)
        #expect(spy.records.first?.input == 500)
    }

    @Test("Nothing is recorded when no request is sent or no envelope decodes",
          arguments: ["notConfigured", "httpError", "undecodable"])
    func usageNotRecordedWithoutBilledResponse(_ scenario: String) async {
        let spy = SpyUsageRecorder()
        switch scenario {
        case "notConfigured":
            let transport = FakeTransport(.success((Data(), httpResponse(status: 200))))
            _ = try? await analyzer(key: nil, transport: transport, usageRecorder: spy)
                .analyze(eligibleMessage(), rawBody: "body")
        case "httpError":
            let transport = FakeTransport(.success((Data(), httpResponse(status: 429))))
            _ = try? await analyzer(transport: transport, usageRecorder: spy)
                .analyze(eligibleMessage(), rawBody: "body")
        default:
            let transport = FakeTransport(.success((
                Data("<html>gateway error</html>".utf8), httpResponse(status: 200))))
            _ = try? await analyzer(transport: transport, usageRecorder: spy)
                .analyze(eligibleMessage(), rawBody: "body")
        }
        #expect(spy.records.isEmpty)
    }
}
