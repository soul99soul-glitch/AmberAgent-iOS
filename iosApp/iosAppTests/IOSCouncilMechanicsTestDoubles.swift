import XCTest
import SwiftUI
import Observation
@preconcurrency import Shared
@testable import iosApp


@MainActor
final class CouncilDurableAwaitGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resume() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
final class CouncilPresentationProbe {
    var authoritativeText: String
    var snapshotCount = 0
    var published: [String] = []

    init(authoritativeText: String = "") {
        self.authoritativeText = authoritativeText
    }
}

@MainActor
final class ScriptedCouncilStreamer: IOSCouncilTextStreaming {
    private var outputs: [Result<String, Error>]
    private(set) var callCount = 0
    private(set) var cancelCount = 0
    private(set) var receivedModels: [Model] = []
    private(set) var receivedProviderNames: [String] = []
    private(set) var receivedUserPrompts: [String] = []

    init(_ outputs: [Result<String, Error>]) {
        self.outputs = outputs
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        callCount += 1
        receivedModels.append(params.model)
        receivedProviderNames.append(providerSetting.name)
        receivedUserPrompts.append(
            messages.last?.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined() ?? ""
        )
        guard !outputs.isEmpty else { throw CouncilTestError.unexpectedCall }
        let next = outputs.removeFirst()
        switch next {
        case .success(let text):
            onUpdate(text, 1)
            return text
        case .failure(let error):
            throw error
        }
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
final class PartialTailCouncilStreamer: IOSCouncilTextStreaming {
    static let partialTail = "风险判断已经生成到这里。"
    private let failedTail: String?
    private(set) var callCount = 0

    init(failedTail: String? = partialTail) {
        self.failedTail = failedTail
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        callCount += 1
        switch callCount {
        case 1:
            return publish("最终议题", through: onUpdate)
        case 2:
            return publish("工程发言", through: onUpdate)
        case 3:
            onUpdate(failedTail ?? "", 1)
            throw CouncilTestError.scriptedFailure
        case 4:
            return publish("主持总结", through: onUpdate)
        default:
            throw CouncilTestError.unexpectedCall
        }
    }

    func cancel() {}

    private func publish(
        _ text: String,
        through onUpdate: @MainActor (String, CGFloat) -> Void
    ) -> String {
        onUpdate(text, 1)
        return text
    }
}

final class CouncilTestAPIKeyStore: SettingsAPIKeyStore {
    private var key: String?

    init(key: String?) {
        self.key = key
    }

    func loadApiKey() -> String? {
        key
    }

    func saveApiKey(_ key: String) -> Bool {
        self.key = key
        return true
    }
}

@MainActor
final class CancellingCouncilSearchTransport: IOSSearchHTTPTransport {
    private let secondRequestStarted: XCTestExpectation
    private(set) var requestCount = 0
    private(set) var queries: [String] = []
    private(set) var cancelledRequestCount = 0

    init(secondRequestStarted: XCTestExpectation) {
        self.secondRequestStarted = secondRequestStarted
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requestCount += 1
        let urlItems = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        var form = URLComponents()
        form.percentEncodedQuery = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let items = urlItems + (form.queryItems ?? [])
        queries.append(items.first { $0.name == "q" || $0.name == "gsrsearch" }?.value ?? "")
        if requestCount == 2 { secondRequestStarted.fulfill() }
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            cancelledRequestCount += 1
            throw CancellationError()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (response, Data())
    }
}

@MainActor
final class ProgressingFinalCouncilStreamer: IOSCouncilTextStreaming {
    private var immediateOutputs = ["最终议题", "工程发言", "风险发言"]

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        if !immediateOutputs.isEmpty {
            let text = immediateOutputs.removeFirst()
            onUpdate(text, 1)
            return text
        }
        onUpdate("第一段", 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        onUpdate("第一段第二段", 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        return "第一段第二段"
    }

    func cancel() {}
}

@MainActor
final class DelayedPartialCouncilStreamer: IOSCouncilTextStreaming {
    static let partialTail = "工程发言已生成到这里。"
    private let partialPublished: XCTestExpectation
    private var callCount = 0

    init(partialPublished: XCTestExpectation) {
        self.partialPublished = partialPublished
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        callCount += 1
        switch callCount {
        case 1:
            onUpdate("最终议题", 1)
            return "最终议题"
        case 2:
            // Let the placeholder's first checkpoint land, then publish a speaking
            // tail and hold long enough for a second throttled checkpoint.
            try await Task.sleep(nanoseconds: 450_000_000)
            onUpdate(Self.partialTail, 1)
            partialPublished.fulfill()
            try await Task.sleep(nanoseconds: 450_000_000)
            return Self.partialTail
        case 3:
            onUpdate("风险发言", 1)
            return "风险发言"
        case 4:
            onUpdate("主持总结", 1)
            return "主持总结"
        default:
            throw CouncilTestError.unexpectedCall
        }
    }

    func cancel() {}
}

@MainActor
final class FailedSeatThenBlockingCouncilStreamer: IOSCouncilTextStreaming {
    private let hostStarted: XCTestExpectation
    private var callCount = 0
    private var continuation: CheckedContinuation<String, Error>?

    init(hostStarted: XCTestExpectation) {
        self.hostStarted = hostStarted
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        callCount += 1
        switch callCount {
        case 1:
            onUpdate("最终议题", 1)
            return "最终议题"
        case 2:
            onUpdate("工程发言", 1)
            return "工程发言"
        case 3:
            throw CouncilTestError.scriptedFailure
        case 4:
            hostStarted.fulfill()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        default:
            throw CouncilTestError.unexpectedCall
        }
    }

    func cancel() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

@MainActor
final class BlockingCouncilProbeStreamer: IOSCouncilTextStreaming {
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var cancelCount = 0

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

@MainActor
final class RestartableCouncilStreamer: IOSCouncilTextStreaming {
    private let firstStreamStarted: XCTestExpectation
    private var firstContinuation: CheckedContinuation<String, Never>?
    private var firstUpdate: (@MainActor (String, CGFloat) -> Void)?
    private var replacementOutputs = ["最终议题", "工程发言", "风险发言", "主持总结"]
    private(set) var callCount = 0
    private(set) var cancelCount = 0

    init(firstStreamStarted: XCTestExpectation) {
        self.firstStreamStarted = firstStreamStarted
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        callCount += 1
        if callCount == 1 {
            firstUpdate = onUpdate
            firstStreamStarted.fulfill()
            return await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        guard !replacementOutputs.isEmpty else {
            throw CouncilTestError.unexpectedCall
        }
        let text = replacementOutputs.removeFirst()
        onUpdate(text, 1)
        return text
    }

    func cancel() {
        cancelCount += 1
        guard let continuation = firstContinuation else { return }
        firstUpdate?("旧轮精确尾部", 1)
        firstContinuation = nil
        firstUpdate = nil
        continuation.resume(returning: "旧轮精确尾部")
    }
}

@MainActor
final class CountingCouncilResearcher: IOSCouncilResearching {
    private(set) var callCount = 0
    private(set) var receivedObjectives: [String] = []
    let marker: String
    init(marker: String = "SEAT_RESEARCH_MARKER_42") { self.marker = marker }
    func research(
        objective: String,
        settings: Settings?,
        maxSearches: Int,
        maxScrapes: Int
    ) async -> IOSCouncilResearchBundle {
        callCount += 1
        receivedObjectives.append(objective)
        return IOSCouncilResearchBundle(
            searches: [],
            scrapedPages: [IOSCouncilScrapedPage(url: "seat://research", content: marker)],
            failures: []
        )
    }
}

final class StaticCouncilResearcher: IOSCouncilResearching {
    func research(
        objective: String,
        settings: Settings?,
        maxSearches: Int,
        maxScrapes: Int
    ) async -> IOSCouncilResearchBundle {
        IOSCouncilResearchBundle(
            searches: [],
            scrapedPages: [
                IOSCouncilScrapedPage(
                    url: "https://example.com/current",
                    content: "Fresh context for \(objective)."
                )
            ],
            failures: []
        )
    }
}

@MainActor
final class RecordingCouncilResearcher: IOSCouncilResearching {
    private(set) var callCount = 0

    func research(
        objective: String,
        settings: Settings?,
        maxSearches: Int,
        maxScrapes: Int
    ) async -> IOSCouncilResearchBundle {
        callCount += 1
        return IOSCouncilResearchBundle(searches: [], scrapedPages: [], failures: [])
    }
}

@MainActor
final class PacedCouncilStreamer: IOSCouncilTextStreaming {
    /// 每次调用模拟一段完整生产序列：流式拍 1 → 排空拍中间值 → 排空拍 0。
    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        onUpdate("第一段", 1)
        onUpdate("第一段第二段", 0.5)
        onUpdate("第一段第二段第三段", 0)
        return "第一段第二段第三段"
    }

    func cancel() {}
}

enum CouncilTestError: LocalizedError {
    case scriptedFailure
    case unexpectedCall

    var errorDescription: String? {
        switch self {
        case .scriptedFailure: "scripted seat failure"
        case .unexpectedCall: "unexpected streamer call"
        }
    }
}
