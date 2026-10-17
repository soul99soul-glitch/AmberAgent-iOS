import Foundation

// MARK: - Jev /v1/systemone client
//
// 官方契约（核对日期 2026-10-16，docs.typesafe.ai/api、images、primitives/box）：
// POST {endpoint}，Bearer 认证；body {model, state, questions, assets?}，questions 为
// map<id, Question>（key 不参与推理）。Choice/Score 的 confidence 来自分布；
// Noul 返回 0~1 概率、不含 confidence。429/529 可退避，401/403/422 不重试。
//
// vercelGateway 形态（核对日期 2026-10-16，@ai-sdk/gateway 源码）：
// POST ai-gateway.vercel.sh/v4/ai/decision-model；{stateParts, questions}
// 负载，模型走 ai-model-id header，题型 noul 记作 boolean；答案从顶层
// answers map 读（boolean→noul），Choice/Score confidence 经
// providerMetadata.typesafe.confidence[qid] 下发。
//
// 约束（IOSJevPolicy）：deadline 内排队+网络+重试+解析；超时必须取消底层任务；
// 单请求 ≤32 题 / ≤64 候选；state ≤48 KiB、文字请求体 ≤64 KiB、图片请求体
// ≤2 MiB、响应体 ≤256 KiB。Box 仅走原生接口，原生图片/Box 按官方要求开启图片头。
// 缺题、未知候选、非有限数值、失效快照均不得成为有效业务结果。

// MARK: Question / answer types

struct IOSJevImageAsset: Encodable, Equatable, Sendable {
    var data: Data
    var format: String

    private enum CodingKeys: String, CodingKey {
        case type, format
        case dataBase64 = "data_base64"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("image", forKey: .type)
        try container.encode(format, forKey: .format)
        try container.encode(data.base64EncodedString(), forKey: .dataBase64)
    }
}

struct IOSJevBox: Decodable, Equatable, Sendable {
    var top: Double
    var bottom: Double
    var left: Double
    var right: Double

    var isValid: Bool {
        [top, bottom, left, right].allSatisfy { $0.isFinite && (0.0...1.0).contains($0) }
            && left < right && top < bottom
    }
}

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

    static func box(id: String, instructions: String) -> IOSJevQuestion {
        IOSJevQuestion(id: id, type: "box", criteria: nil, instructions: instructions)
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
    /// Box：相对于图片宽高的四条边；解析结果不触发点击。
    var box: IOSJevBox?
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
        /// 出站形态：systemone = TypeSafe 原生契约；vercelGateway = Vercel
        /// AI Gateway 的 decision-model 契约（body {stateParts, questions}，
        /// 模型走 ai-model-id header，题型 noul 在线上记作 boolean）。
        var style: IOSJevAPIStyle = .systemone
        var assets: [String: IOSJevImageAsset] = [:]
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
            case ("box", "box"):
                guard let box = raw.box, box.isValid else { continue }
                results.append(IOSJevAnswer(id: question.id, type: "box", confidence: sanitizedConfidence(raw.confidence), box: box))
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
        var box: IOSJevBox?
    }

    private struct RawResponse: Decodable {
        var model: String?
        var answers: [String: RawAnswer]?
        var usage: RawUsage?
    }

    private struct RawUsage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    private struct RequestBody: Encodable {
        var model: String
        var state: String
        var questions: [String: IOSJevQuestion]
        var assets: [String: IOSJevImageAsset]?
    }

    // MARK: vercelGateway（Vercel AI Gateway decision-model，@ai-sdk/gateway 契约）

    // https://github.com/vercel/ai/blob/8a5233b15b1e69573d63faee6cd0014559252ee4/packages/gateway/src/gateway-decision-model.ts

    /// Gateway 线上题型：SDK 对外统一 choice/score/boolean，boolean 由 Gateway
    /// 映射到 TypeSafe 原生 noul。criteria 形状与 IOSJevQuestion.JevCriteria
    /// 同构（choice = 选项 map，score = 有序等级数组），直接复用编码。
    private struct GatewayQuestion: Encodable {
        var type: String
        var criteria: IOSJevQuestion.JevCriteria?
        var instructions: String?

        init(_ question: IOSJevQuestion) {
            type = question.type == "noul" ? "boolean" : question.type
            criteria = question.criteria
            instructions = question.instructions
        }
    }

    private struct GatewayStatePart: Encodable {
        var type: String
        var text: String?
        var mediaType: String?
        var data: FileData?

        struct FileData: Encodable {
            let type = "data"
            var data: String
        }

        init(text: String) {
            type = "text"
            self.text = text
        }

        init(image: IOSJevImageAsset) {
            type = "file"
            mediaType = image.format == "png" ? "image/png" : "image/jpeg"
            data = FileData(data: image.data.base64EncodedString())
        }
    }

    /// 模型不在 body（走 ai-model-id header）；文件字节通过有序 stateParts 发送。
    private struct GatewayDecisionBody: Encodable {
        var stateParts: [GatewayStatePart]
        var questions: [String: GatewayQuestion]
    }

    private struct GatewayDecisionResponse: Decodable {
        var model: String?
        var answers: [String: GatewayAnswer]?
        var usage: GatewayUsage?
        var providerMetadata: [String: GatewayProviderMetadata]?

        struct GatewayAnswer: Decodable {
            var type: String
            var choice: String?
            var score: Double?
            var probability: Double?
        }

        /// Gateway usage 是 camelCase（与 systemone 的 snake_case 不同）。
        struct GatewayUsage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
        }

        /// typesafe provider 的 Choice/Score confidence 经 providerMetadata
        /// .typesafe.confidence[questionId] 下发（noul 无 confidence 概念）。
        struct GatewayProviderMetadata: Decodable {
            var confidence: [String: Double]?
        }
    }

    /// 与实际出站共用编码，供协调器在并发预算锁内预留精确请求体字节数。
    func requestBodyByteCount(_ input: RequestInput) throws -> Int {
        try Self.encodedRequestBody(
            model: input.model, state: input.state, questions: input.questions, style: input.style,
            assets: input.assets
        ).count
    }

    /// Shared with callers that fit a bounded batch to the actual wire byte budget.
    static func encodedRequestBody(
        model: String,
        state: String,
        questions: [IOSJevQuestion],
        style: IOSJevAPIStyle,
        assets: [String: IOSJevImageAsset] = [:]
    ) throws -> Data {
        guard Set(questions.map(\.id)).count == questions.count else {
            throw IOSJevRequestError.invalidRequest("duplicate question id")
        }
        try validateImageInput(state: state, questions: questions, style: style, assets: assets)
        let questionMap = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
        let encoder = JSONEncoder()
        do {
            switch style.contract {
            case .systemone:
                return try encoder.encode(RequestBody(
                    model: model, state: state, questions: questionMap,
                    assets: assets.isEmpty ? nil : assets
                ))
            case .vercelDecisionModel:
                let stateParts = try gatewayStateParts(state: state, assets: assets)
                return try encoder.encode(GatewayDecisionBody(
                    stateParts: stateParts, questions: questionMap.mapValues(GatewayQuestion.init)
                ))
            }
        } catch let error as IOSJevRequestError {
            throw error
        } catch {
            throw IOSJevRequestError.invalidRequest("encode failed: \(error.localizedDescription)")
        }
    }

    private static func validateImageInput(
        state: String,
        questions: [IOSJevQuestion],
        style: IOSJevAPIStyle,
        assets: [String: IOSJevImageAsset]
    ) throws {
        guard style.supportsBoxQuestions || !questions.contains(where: { $0.type == "box" }) else {
            throw IOSJevRequestError.invalidRequest("box questions require native API")
        }
        // 未实现图片编码的供应商（Perplexity / Liquid）必须拒收 assets，否则会以
        // systemone 形状把图片发到不支持它的服务，换来一个 400。
        guard assets.isEmpty || style.supportsImages else {
            throw IOSJevRequestError.invalidRequest("images unsupported by provider")
        }
        guard !assets.isEmpty else { return }
        var questionValues: [String] = []
        for question in questions {
            if let instructions = question.instructions { questionValues.append(instructions) }
            switch question.criteria {
            case .options(let options): questionValues.append(contentsOf: options.values.compactMap { $0 })
            case .levels(let levels): questionValues.append(contentsOf: levels)
            case nil: break
            }
        }
        for (reference, asset) in assets {
            guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IOSJevRequestError.invalidRequest("empty image reference")
            }
            guard !asset.data.isEmpty else {
                throw IOSJevRequestError.invalidRequest("empty image data")
            }
            guard ["jpg", "jpeg", "png"].contains(asset.format) else {
                throw IOSJevRequestError.invalidRequest("unsupported image format")
            }
            let referencedInQuestion = questionValues.contains(where: { $0.contains(reference) })
            guard state.contains(reference) || referencedInQuestion else {
                throw IOSJevRequestError.invalidRequest("unreferenced image asset")
            }
            if style.contract == IOSJevProvider.Contract.vercelDecisionModel {
                guard !referencedInQuestion else {
                    throw IOSJevRequestError.invalidRequest("gateway image references are only supported in state")
                }
                guard let occurrence = state.range(of: reference),
                      state.range(of: reference, range: occurrence.upperBound..<state.endIndex) == nil else {
                    throw IOSJevRequestError.invalidRequest("gateway image reference must occur once in state")
                }
            }
        }
    }

    /// Replace each state image reference in place, retaining the surrounding text as context.
    private static func gatewayStateParts(
        state: String,
        assets: [String: IOSJevImageAsset]
    ) throws -> [GatewayStatePart] {
        guard !assets.isEmpty else { return [GatewayStatePart(text: state)] }
        let images = try assets.map { reference, asset -> (range: Range<String.Index>, asset: IOSJevImageAsset) in
            guard let range = state.range(of: reference) else {
                throw IOSJevRequestError.invalidRequest("unreferenced image asset")
            }
            return (range, asset)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var parts: [GatewayStatePart] = []
        var cursor = state.startIndex
        for image in images {
            guard cursor <= image.range.lowerBound else {
                throw IOSJevRequestError.invalidRequest("overlapping gateway image references")
            }
            if cursor < image.range.lowerBound {
                parts.append(GatewayStatePart(text: String(state[cursor..<image.range.lowerBound])))
            }
            parts.append(GatewayStatePart(image: image.asset))
            cursor = image.range.upperBound
        }
        if cursor < state.endIndex {
            parts.append(GatewayStatePart(text: String(state[cursor...])))
        }
        return parts
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
        // 空模型 slug 一律出站前拒绝（vercel 未配模型时不发无意义请求）。
        guard !input.model.isEmpty else {
            throw IOSJevRequestError.invalidRequest("empty model")
        }
        guard input.questions.count <= policy.maxQuestions else {
            throw IOSJevRequestError.invalidRequest("too many questions: \(input.questions.count)")
        }
        guard Set(input.questions.map(\.id)).count == input.questions.count else {
            throw IOSJevRequestError.invalidRequest("duplicate question id")
        }
        try Self.validateImageInput(
            state: input.state, questions: input.questions, style: input.style, assets: input.assets
        )
        let deadline = TimeInterval(deadlineMs ?? policy.deadlineMs) / 1_000

        if let cacheKey, let cached = cachedDecision(cacheKey: cacheKey) {
            return cached
        }

        let bodyData = try Self.encodedRequestBody(
            model: input.model, state: input.state, questions: input.questions, style: input.style,
            assets: input.assets
        )
        let maxRequestBytes = input.assets.isEmpty ? policy.maxRequestBytes : IOSJevPolicy.maxImageRequestBytes
        guard bodyData.count <= maxRequestBytes else {
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
        if input.style == .systemone,
           !input.assets.isEmpty || input.questions.contains(where: { $0.type == "box" }) {
            request.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        }
        if input.style.contract == .vercelDecisionModel {
            // 按契约而非供应商身份分支：将来若有第二家走 decision-model 契约，
            // 协议头不会静默丢失。
            // @ai-sdk/gateway decision-model 协议头：模型 ID 与 spec 版本
            // 走 header，protocol-version/auth-method 与 SDK 一致。
            request.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
            request.setValue("api-key", forHTTPHeaderField: "ai-gateway-auth-method")
            request.setValue("4", forHTTPHeaderField: "ai-decision-model-specification-version")
            request.setValue(input.model, forHTTPHeaderField: "ai-model-id")
        }
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

        let parsed = try parseAnswers(data: data, input: input)
        let answers = Self.validatedAnswers(for: input.questions, rawAnswers: parsed.rawAnswers)
        guard !answers.isEmpty else {
            throw IOSJevRequestError.invalidResponse("no valid answers")
        }
        let decision = IOSJevDecision(
            answers: answers,
            usage: parsed.usage,
            modelVersion: parsed.model ?? input.model,
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

    /// 按出站形态解析响应，统一回 (rawAnswers, usage, model)。
    /// systemone：顶层 answers map；vercelGateway：顶层 answers map（题型
    /// boolean 译回 noul、probability→noul 字段，Choice/Score confidence 从
    /// providerMetadata.typesafe.confidence[qid] 注入），usage 是 camelCase
    /// inputTokens/outputTokens。Gateway 未回显 model 时用出站 slug。
    private func parseAnswers(
        data: Data,
        input: RequestInput
    ) throws -> (rawAnswers: [String: RawAnswer], usage: IOSJevUsage?, model: String?) {
        switch input.style.contract {
        case .systemone:
            let raw: RawResponse
            do {
                raw = try JSONDecoder().decode(RawResponse.self, from: data)
            } catch {
                throw IOSJevRequestError.invalidResponse("decode failed: \(error.localizedDescription)")
            }
            guard let answers = raw.answers else {
                throw IOSJevRequestError.invalidResponse("missing answers map")
            }
            let usage = raw.usage.flatMap { rawUsage -> IOSJevUsage? in
                guard let inputTokens = rawUsage.inputTokens,
                      let outputTokens = rawUsage.outputTokens,
                      inputTokens >= 0, outputTokens >= 0 else { return nil }
                return IOSJevUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            }
            return (answers, usage, raw.model)

        case .vercelDecisionModel:
            let raw: GatewayDecisionResponse
            do {
                raw = try JSONDecoder().decode(GatewayDecisionResponse.self, from: data)
            } catch {
                throw IOSJevRequestError.invalidResponse("decode failed: \(error.localizedDescription)")
            }
            guard let answers = raw.answers else {
                throw IOSJevRequestError.invalidResponse("missing answers map")
            }
            let confidence = raw.providerMetadata?["typesafe"]?.confidence
            var mapped: [String: RawAnswer] = [:]
            for (id, answer) in answers {
                switch answer.type {
                case "boolean":
                    mapped[id] = RawAnswer(type: "noul", noul: answer.probability, choice: nil, score: nil, confidence: nil)
                case "choice":
                    mapped[id] = RawAnswer(type: "choice", noul: nil, choice: answer.choice, score: nil, confidence: confidence?[id])
                case "score":
                    mapped[id] = RawAnswer(type: "score", noul: nil, choice: nil, score: answer.score, confidence: confidence?[id])
                default:
                    continue // 未知题型不伪造，由 validatedAnswers 丢弃。
                }
            }
            let usage = raw.usage.flatMap { rawUsage -> IOSJevUsage? in
                guard let inputTokens = rawUsage.inputTokens,
                      let outputTokens = rawUsage.outputTokens,
                      inputTokens >= 0, outputTokens >= 0 else { return nil }
                return IOSJevUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            }
            return (mapped, usage, raw.model)
        }
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
