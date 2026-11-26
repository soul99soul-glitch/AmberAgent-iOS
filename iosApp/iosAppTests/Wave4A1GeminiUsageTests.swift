import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class Wave4A1GeminiUsageTests: XCTestCase {
    private let user = UIMessage.companion.user(prompt: "hi")
    private let params = TextGenerationParams(
        model: Model(
            modelId: "gemini-test", displayName: "Gemini", id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: [], tools: [], contextWindowTokens: nil, providerOverwrite: nil
        ),
        temperature: nil, topP: nil, maxTokens: nil, tools: [],
        reasoningLevel: .off, customHeaders: [], customBody: []
    )

    func testLatestSnapshotReachesStreamAccumulatorAndGeneratedMessage() async throws {
        let usage = #"{"promptTokenCount":1000,"cachedContentTokenCount":700,"candidatesTokenCount":20,"thoughtsTokenCount":8,"totalTokenCount":1028}"#
        for reason in ["STOP", "MAX_TOKENS"] {
            let (client, session) = fixture([
                #"{"candidates":[{"content":{"parts":[{"text":"one"}]}}],"usageMetadata":{"promptTokenCount":1000,"cachedContentTokenCount":600,"candidatesTokenCount":1}}"#,
                #"{"response":{"candidates":[{"content":{"parts":[{"text":" two"}]},"finishReason":"\#(reason)"}],"usageMetadata":\#(usage)}}"#,
                #"{"response":{"usageMetadata":\#(usage)}}"#,
                "[DONE]",
            ])
            defer { session.invalidateAndCancel() }
            let accumulator = MessageStreamAccumulator(initialMessages: [user], model: nil)
            var reported: [TokenUsage] = []
            var finishes: [String] = []
            try await client.streamText(messages: [user], params: params) { chunk in
                accumulator.append(chunk: chunk)
                if let usage = chunk.usage { reported.append(usage) }
                finishes.append(contentsOf: chunk.choices.compactMap(\.finishReason))
            }
            XCTAssertEqual(reported.count, 1)
            XCTAssertEqual(finishes, reason == "STOP" ? [] : [reason])
            let messages = accumulator.snapshot()
            let metrics = ChatContextUsageMetrics.lastAssistantTurn(in: messages)
            XCTAssertEqual(metrics.promptTokens, 1_000)
            XCTAssertEqual(metrics.cachedTokens, 700)
            XCTAssertEqual(Double(metrics.cachedTokens) / Double(metrics.promptTokens), 0.7)
            XCTAssertEqual(metrics.completionTokens, 28)
            XCTAssertEqual(messages.last?.usage?.totalTokens, 1_028)

            let generated = try await client.generateText(messages: [user], params: params)
            let message = try XCTUnwrap(generated.choices.first?.message)
            XCTAssertEqual((message.parts.first as? UIMessagePart.Text)?.text, "one two")
            XCTAssertEqual(generated.choices.first?.finishReason, reason)
            XCTAssertEqual(generated.usage, messages.last?.usage)
            XCTAssertEqual(message.usage, generated.usage)
        }
    }

    func testToolPromptAndThoughtsSurviveSharedTotalRecalculation() async throws {
        let (client, session) = fixture([
            #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#,
            #"{"usageMetadata":{"promptTokenCount":1000,"toolUsePromptTokenCount":30,"candidatesTokenCount":15,"thoughtsTokenCount":5}}"#,
        ])
        defer { session.invalidateAndCancel() }
        let accumulator = MessageStreamAccumulator(initialMessages: [user], model: nil)
        try await client.streamText(messages: [user], params: params) { accumulator.append(chunk: $0) }
        let usage = try XCTUnwrap(accumulator.snapshot().last?.usage)
        XCTAssertEqual(usage.promptTokens, 1_030)
        XCTAssertEqual(usage.completionTokens, 20)
        XCTAssertEqual(usage.totalTokens, 1_050)
        XCTAssertEqual(usage.cachedTokens, 0)
    }

    func testMissingMetadataLeavesUsageUnknownOnBothExits() async throws {
        let (client, session) = fixture([
            #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#,
            #"{"usageMetadata":{}}"#,
            #"{"usageMetadata":{"promptTokenCount":true,"cachedContentTokenCount":null}}"#,
        ])
        defer { session.invalidateAndCancel() }
        try await client.streamText(messages: [user], params: params) { XCTAssertNil($0.usage) }
        let generated = try await client.generateText(messages: [user], params: params)
        XCTAssertNil(generated.usage)
        XCTAssertNil(generated.choices.first?.message?.usage)
    }

    func testUsageOnlyResponseKeepsAuthoritativeTotalOnAssistant() async throws {
        let (client, session) = fixture([
            #"{"response":{"candidates":[]},"usageMetadata":{"totalTokenCount":42}}"#,
        ])
        defer { session.invalidateAndCancel() }
        let accumulator = MessageStreamAccumulator(initialMessages: [user], model: nil)
        try await client.streamText(messages: [user], params: params) { accumulator.append(chunk: $0) }
        let messages = accumulator.snapshot()
        XCTAssertNil(messages.first?.usage)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.usage?.totalTokens, 42)
        XCTAssertEqual(messages.last?.usage?.promptTokens, 0)
        XCTAssertEqual(messages.last?.usage?.completionTokens, 0)
    }

    private func fixture(_ lines: [String]) -> (IOSGeminiClient, URLSession) {
        GeminiUsageURLProtocol.body = Data(lines.map { "data: \($0)\n" }.joined().utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiUsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = ProviderSetting.Google(
            id: KotlinUuid.companion.random(), enabled: true, name: "Gemini", models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false, descriptionText: nil, shortDescriptionText: nil, apiKey: "test",
            baseUrl: "https://gemini.invalid", vertexAI: false, useServiceAccount: false,
            privateKey: "", serviceAccountEmail: "", location: "", projectId: "", authMode: .apiKey
        )
        return (IOSGeminiClient(provider: provider, session: session), session)
    }
}

private final class GeminiUsageURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
