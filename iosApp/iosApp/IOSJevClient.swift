import Foundation

// MARK: - Jev /v1/systemone client
//
// 官方契约（核对日期 2026-09-17，docs.typesafe.ai/api）：
// POST {endpoint}，Bearer 认证；body {model, state, questions}，questions 为
// map<id, Question>（key 不参与推理）。Choice/Score 的 confidence 来自分布；
// Noul 返回 0~1 概率、不含 confidence。429/529 可退避，401/403/422 不重试。
//
// 约束（IOSJevPolicy）：deadline 内排队+网络+重试+解析；超时必须取消底层任务；
// 单请求 ≤32 题 / ≤64 候选；state ≤48 KiB、请求体 ≤64 KiB、响应体 ≤256 KiB。
// 缺题、未知候选、非有限数值、失效快照均不得成为有效业务结果。

// MARK: Question / answer types

struct IOSJevQuestion: Encodable, Equatable, Sendable {
    var id: String
    var type: String
    /// Choice / Score：候选或分级说明进入 criteria（官方字段）。
    var criteria: JevCriteria?
    var instructions: String?

    enum JevCriteria: Encodable, Equatable, Sendable {
        /// Choice：option → rubric 描述（null 允许）。
        case options([String: String?])
        /// Score：有序分级描述，至少两级。
        case levels([String])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .options(let map): try container.encode(map)
            case .levels(let array): try container.encode(array)
            }
        }
    }

    static func score(id: String, levels: [String], instructions: String) -> IOSJevQuestion {
        IOSJevQuestion(id: id, type: "score", criteria: .levels(levels), instructions: instructions)
    }

    static func choice(id: String, options: [String: String?], instructions: String) -> IOSJevQuestion {
        IOSJevQuestion(id: id, type: "choice", criteria: .options(options), instructions: instructions)
    }

    static func noul(id: String, instructions: String) -> IOSJevQuestion {
        IOSJevQuestion(id: id, type: "noul", criteria: nil, instructions: instructions)
    }
}

struct IOSJevAnswer: Equatable, Sendable {
    var id: String
    var type: String
    /// Noul：0~1 概率（无 confidence，不伪造该字段）。
    var noul: Double?
    /// Choice：选中项 + confidence。
    var choice: String?
    var confidence: Double?
    /// Score：概率加权分（可落在两级之间）。
    var score: Double?
}

struct IOSJevUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
}

struct IOSJevDecision: Sendable {
    var answers: [IOSJevAnswer]
    var usage: IOSJevUsage?
    var modelVersion: String
    var latencyMs: Int
    var requestBytes: Int
    var responseBytes: Int
}

enum IOSJevRequestError: Error, Equatable {
    case missingKey
    case timeout
    case cancelled
    /// retryAfterSeconds：429 响应携带的 Retry-After（秒）。
    case http(status: Int, retryAfterSeconds: Double? = nil)
    case invalidResponse(String)
    /// 出站前的本地拒绝（题数超限/编码失败）：无网络流量，调用方不应计费。
    case invalidRequest(String)
    case stateTooLarge(bytes: Int)
    case requestTooLarge(bytes: Int)
    case transport(String)
}

// MARK: - Transport（测试注入点）

protocol IOSJevTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct IOSJevURLSessionTransport: IOSJevTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IOSJevRequestError.transport("non-HTTP response")
        }
        return (data, http)
    }
}

// MARK: - Client

final class IOSJevClient {
    struct RequestInput: Equatable {
        var endpoint: URL
        var apiKey: String
        var model: String
        var state: String
        var questions: [IOSJevQuestion]
    }

    private let transport: IOSJevTransport
    private let now: @Sendable () -> Date
    private var cache: [String: (expires: Date, decision: IOSJevDecision)] = [:]
    private let cacheLock = NSLock()

    init(transport: IOSJevTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    // MARK: Cache（仅内存、有界、TTL 5 分钟；键含完整输入/候选/用途/版本/范围/run 隔离）

    func cachedDecision(cacheKey: String) -> IOSJevDecision? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[cacheKey] else { return nil }
        guard entry.expires > now() else {
            cache.removeValue(forKey: cacheKey)
            return nil
        }
        return entry.decision
    }

    func storeCachedDecision(cacheKey: String, decision: IOSJevDecision, ttlSeconds: Int, maxEntries: Int = 128) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[cacheKey] = (now().addingTimeInterval(TimeInterval(ttlSeconds)), decision)
        if cache.count > maxEntries {
            // 有界：按过期时间丢最旧（网页动作不缓存，由调用方保证不传 cacheKey）。
            let sorted = cache.sorted { $0.value.expires < $1.value.expires }
            for (key, _) in sorted.prefix(cache.count - maxEntries) {
                cache.removeValue(forKey: key)
            }
        }
    }

    func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll()
    }

    // MARK: Validation

    /// confidence 必须是有限 0~1 数值，否则视为缺失（不伪造）。
    private static func sanitizedConfidence(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite, (0.0...1.0).contains(value) else { return nil }
        return value
    }

    /// 缺题、未知候选、非有限数值都不得成为有效结果。逐题校验并丢弃非法题，
    /// 返回合法答案；调用方以题目数判断可用性。
    static func validatedAnswers(
        for questions: [IOSJevQuestion],
        rawAnswers: [String: RawAnswer]
    ) -> [IOSJevAnswer] {
        var results: [IOSJevAnswer] = []
        for question in questions {
            guard let raw = rawAnswers[question.id] else { continue }
            switch (question.type, raw.type) {
            case ("noul", "noul"):
                guard let value = raw.noul, value.isFinite, (0.0...1.0).contains(value) else { continue }
                results.append(IOSJevAnswer(id: question.id, type: "noul", noul: value))
            case ("score", "score"):
                // Score 分数落在 0..级数-1（概率加权可落在两级之间）。
                let maxLevel: Double
                if case .levels(let levels)? = question.criteria, levels.count >= 2 {
                    maxLevel = Double(levels.count - 1)
                } else {
                    maxLevel = 1.0
                }
                guard let value = raw.score, value.isFinite, (0.0...maxLevel).contains(value) else { continue }
                results.append(IOSJevAnswer(id: question.id, type: "score", confidence: sanitizedConfidence(raw.confidence), score: value))
            case ("choice", "choice"):
                guard let choice = raw.choice, !choice.isEmpty else { continue }
                guard let options = question.criteria, case .options(let map) = options, map[choice] != nil || map.keys.contains(choice) else { continue }
                results.append(IOSJevAnswer(id: question.id, type: "choice", choice: choice, confidence: sanitizedConfidence(raw.confidence)))
            default:
                continue
            }
        }
        return results
    }

    struct RawAnswer: Decodable {
        var type: String
        var noul: Double?
        var choice: String?
        var score: Double?
        var confidence: Double?
    }

    private struct RawResponse: Decodable {
        var model: String?
        var answers: [String: RawAnswer]?
        var usage: RawUsage?
    }

    private struct RawUsage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
    }

    private struct RequestBody: Encodable {
        var model: String
        var state: String
        var questions: [String: IOSJevQuestion]
    }

    // MARK: Execute

    /// 单次判断。超限分块由调用方负责；这里做请求级硬校验并抛错。
    /// cacheKey 为 nil 时不缓存（网页动作等）。
    func decide(
        _ input: RequestInput,
        policy: IOSJevPolicy,
        deadlineMs: Int? = nil,
        cacheKey: String? = nil
    ) async throws -> IOSJevDecision {
        guard !input.apiKey.isEmpty else { throw IOSJevRequestError.missingKey }
        guard input.questions.count <= policy.maxQuestions else {
            throw IOSJevRequestError.invalidRequest("too many questions: \(input.questions.count)")
        }
        let deadline = TimeInterval(deadlineMs ?? policy.deadlineMs) / 1_000

        if let cacheKey, let cached = cachedDecision(cacheKey: cacheKey) {
            return cached
        }

        let body = RequestBody(
            model: input.model,
            state: input.state,
            questions: Dictionary(uniqueKeysWithValues: input.questions.map { ($0.id, $0) })
        )
        let encoder = JSONEncoder()
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw IOSJevRequestError.invalidRequest("encode failed: \(error.localizedDescription)")
        }
        guard bodyData.count <= policy.maxRequestBytes else {
            throw IOSJevRequestError.requestTooLarge(bytes: bodyData.count)
        }
        guard input.state.utf8.count <= policy.maxStateBytes else {
            throw IOSJevRequestError.stateTooLarge(bytes: input.state.utf8.count)
        }

        var request = URLRequest(url: input.endpoint)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(input.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = max(deadline + 0.5, 1.0)

        let startedAt = now()
        let (data, http) = try await executeWithRetry(
            request: request,
            deadline: startedAt.addingTimeInterval(deadline)
        )
        let latencyMs = Int(now().timeIntervalSince(startedAt) * 1_000)
        guard data.count <= policy.maxResponseBytes else {
            throw IOSJevRequestError.invalidResponse("response too large: \(data.count)")
        }

        let raw: RawResponse
        do {
            raw = try JSONDecoder().decode(RawResponse.self, from: data)
        } catch {
            throw IOSJevRequestError.invalidResponse("decode failed: \(error.localizedDescription)")
        }
        guard let rawAnswers = raw.answers else {
            throw IOSJevRequestError.invalidResponse("missing answers map")
        }
        let answers = Self.validatedAnswers(for: input.questions, rawAnswers: rawAnswers)
        guard !answers.isEmpty else {
            throw IOSJevRequestError.invalidResponse("no valid answers")
        }
        let usage = raw.usage.flatMap { rawUsage -> IOSJevUsage? in
            guard let inputTokens = rawUsage.input_tokens, let outputTokens = rawUsage.output_tokens,
                  inputTokens >= 0, outputTokens >= 0 else { return nil }
            return IOSJevUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        }
        let decision = IOSJevDecision(
            answers: answers,
            usage: usage,
            modelVersion: raw.model ?? input.model,
            latencyMs: latencyMs,
            requestBytes: bodyData.count,
            responseBytes: data.count
        )
        if let cacheKey {
            storeCachedDecision(
                cacheKey: cacheKey,
                decision: decision,
                ttlSeconds: policy.cacheTTLSeconds,
                maxEntries: policy.cacheMaxEntries
            )
        }
        return decision
    }

    // MARK: Retry（400/401/403/422 不重试；暂时性错误最多一次且需剩余 deadline；429 尊重 Retry-After）

    private func executeWithRetry(
        request: URLRequest,
        deadline: Date
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await executeWithinDeadline(request: request, deadline: deadline)
        } catch let error as IOSJevRequestError {
            guard now() < deadline else { throw error }
            switch error {
            case .http(let status, let retryAfter):
                guard status == 429 || status == 529 || (500...599).contains(status) else { throw error }
                // 429：只在 Retry-After 完整落在剩余 deadline 内时等待后重试一次。
                if status == 429, let retryAfter {
                    guard now().addingTimeInterval(retryAfter) < deadline else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                }
            case .timeout, .transport:
                break
            case .missingKey, .cancelled, .invalidRequest, .invalidResponse, .stateTooLarge, .requestTooLarge:
                throw error
            }
            return try await executeWithinDeadline(request: request, deadline: deadline)
        }
    }

    private func executeWithinDeadline(
        request: URLRequest,
        deadline: Date
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { throw IOSJevRequestError.timeout }
        // 只捕获 Sendable 局部量（transport/request），self 不进子任务闭包。
        let transport = self.transport

        // 结构化竞速：超时分支退出时组取消会一并取消实际网络任务，
        // 不因底层未结束而继续等待。
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await transport.data(for: request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(remaining, 0.01) * 1_000_000_000))
                throw IOSJevRequestError.timeout
            }
            guard let (data, http) = try await group.next() else {
                throw IOSJevRequestError.transport("no result")
            }
            group.cancelAll()
            guard (200...299).contains(http.statusCode) else {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                throw IOSJevRequestError.http(status: http.statusCode, retryAfterSeconds: retryAfter)
            }
            return (data, http)
        }
    }
}

// MARK: - Keychain helper

extension IOSCredentialSideTable {
    /// Jev API Key 的 Keychain side-table ref。
    static var jevApiKey: String { settingsPath("jev.apiKey") }
}
