import XCTest
@testable import iosApp

// IOSJevClientTests：typed 答案映射、响应校验（未知 ID / 错类型 / 缺题 / 非法
// 数值 / 超大响应）、deadline 取消真实任务、重试截止、429 Retry-After、缓存
// TTL/有界、体积上限。

final class IOSJevClientTests: XCTestCase {

    private func httpResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: IOSJevSettings.productionEndpoint,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    private func scoreResponse(answers: [String: Double], confidence: Double = 0.8) -> Data {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": answers.mapValues { score in
                ["type": "score", "score": score, "confidence": confidence] as [String: Any]
            },
            "usage": ["input_tokens": 12, "output_tokens": 34],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeQuestions(_ ids: [String]) -> [IOSJevQuestion] {
        ids.map { IOSJevQuestion.score(id: $0, levels: ["0 无关", "3 相关"], instructions: "test") }
    }

    private func makeInput(
        transport: JevStubTransport,
        questions: [IOSJevQuestion],
        state: String = "state",
        apiKey: String = "test-key",
        assets: [String: IOSJevImageAsset] = [:]
    ) -> IOSJevClient.RequestInput {
        IOSJevClient.RequestInput(
            endpoint: IOSJevSettings.productionEndpoint,
            apiKey: apiKey,
            model: "jev-latest",
            state: state,
            questions: questions,
            assets: assets
        )
    }

    /// vercelGateway 输入：endpoint 为 Vercel AI Gateway decision-model，
    /// 模型为 provider/model slug。
    private func vercelInput(
        questions: [IOSJevQuestion],
        model: String = "typesafe-ai/jev",
        state: String = "state",
        assets: [String: IOSJevImageAsset] = [:]
    ) -> IOSJevClient.RequestInput {
        IOSJevClient.RequestInput(
            endpoint: IOSJevSettings.vercelGatewayEndpoint,
            apiKey: "vercel-key",
            model: model,
            state: state,
            questions: questions,
            style: .vercelGateway,
            assets: assets
        )
    }

    private func vercelHTTPResponse(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: IOSJevSettings.vercelGatewayEndpoint,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    /// Gateway decision-model 响应：顶层 answers map（题型 boolean/choice/
    /// score），camelCase usage，confidence 经 providerMetadata.typesafe 下发。
    private func vercelResponse(
        answers: [String: [String: Any]],
        confidence: [String: Double]? = nil,
        usage: [String: Any]? = ["inputTokens": 120, "outputTokens": 30]
    ) -> Data {
        var payload: [String: Any] = ["answers": answers]
        if let usage { payload["usage"] = usage }
        if let confidence { payload["providerMetadata"] = ["typesafe": ["confidence": confidence]] }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private let policy = IOSJevPolicy()

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date()
        var now: Date { jevSync(lock) { _now } }
        func advance(_ seconds: TimeInterval) { jevSync(lock) { _now = _now.addingTimeInterval(seconds) } }
    }

    // MARK: Happy path & mapping

    func testDecideMapsTypedAnswersAndUsage() async throws {
        let transport = JevStubTransport { [weak self] _ in
            (self?.scoreResponse(answers: ["t1": 0.9, "t2": 0.1]) ?? Data(), self?.httpResponse(status: 200) ?? HTTPURLResponse())
        }
        let client = IOSJevClient(transport: transport)
        let decision = try await client.decide(
            makeInput(transport: transport, questions: makeQuestions(["t1", "t2"])),
            policy: policy
        )
        XCTAssertEqual(decision.answers.count, 2)
        XCTAssertTrue(decision.answers.contains { $0.id == "t1" && $0.score == 0.9 })
        XCTAssertEqual(decision.usage?.inputTokens, 12)
        XCTAssertEqual(decision.usage?.outputTokens, 34)
        XCTAssertEqual(decision.modelVersion, "jev-latest")
    }

    func testDuplicateQuestionIdsAreRejectedBeforeNetwork() async {
        let transport = JevStubTransport { _ in
            (self.scoreResponse(answers: ["duplicate": 1]), self.httpResponse(status: 200))
        }
        let client = IOSJevClient(transport: transport)
        let input = makeInput(
            transport: transport,
            questions: makeQuestions(["duplicate", "duplicate"])
        )

        do {
            _ = try await client.decide(input, policy: policy)
            XCTFail("expected local duplicate id rejection")
        } catch let error as IOSJevRequestError {
            XCTAssertEqual(error, .invalidRequest("duplicate question id"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(transport.calls, 0, "duplicate question ids must be rejected before network")
    }

    func testNoulAndChoiceMapping() async throws {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": [
                "n1": ["type": "noul", "noul": 0.87],
                "c1": ["type": "choice", "choice": "a", "probabilities": ["a": 0.8, "b": 0.2], "confidence": 0.66],
            ],
        ]
        let transport = JevStubTransport { _ in (try! JSONSerialization.data(withJSONObject: payload), self.httpResponse(status: 200)) }
        let client = IOSJevClient(transport: transport)
        let questions: [IOSJevQuestion] = [
            .noul(id: "n1", instructions: "yes?"),
            .choice(id: "c1", options: ["a": "A 选项", "b": nil], instructions: "pick"),
        ]
        let decision = try await client.decide(makeInput(transport: transport, questions: questions), policy: policy)
        XCTAssertEqual(decision.answers.count, 2)
        XCTAssertEqual(decision.answers.first { $0.id == "n1" }?.noul, 0.87)
        XCTAssertEqual(decision.answers.first { $0.id == "c1" }?.choice, "a")
        XCTAssertEqual(decision.answers.first { $0.id == "c1" }?.confidence, 0.66)
    }

    // MARK: Validation

    func testUnknownChoiceCandidateIsDropped() async throws {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": [
                "c1": ["type": "choice", "choice": "unknown_option", "confidence": 0.9],
            ],
        ]
        let transport = JevStubTransport { _ in (try! JSONSerialization.data(withJSONObject: payload), self.httpResponse(status: 200)) }
        let client = IOSJevClient(transport: transport)
        let questions: [IOSJevQuestion] = [.choice(id: "c1", options: ["a": "A", "b": nil], instructions: "pick")]
        do {
            _ = try await client.decide(makeInput(transport: transport, questions: questions), policy: policy)
            XCTFail("expected invalidResponse")
        } catch let error as IOSJevRequestError {
            guard case .invalidResponse = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testMissingQuestionAndNonFiniteScoreAreDropped() {
        let questions = makeQuestions(["t1", "t2", "t3"])
        let raw: [String: IOSJevClient.RawAnswer] = [
            "t1": .init(type: "score", noul: nil, choice: nil, score: 0.5, confidence: nil),
            // t2 缺题
            "t3": .init(type: "score", noul: nil, choice: nil, score: Double.nan, confidence: nil),
        ]
        let answers = IOSJevClient.validatedAnswers(for: questions, rawAnswers: raw)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.id, "t1")
    }

    func testScoreOutOfRangeIsRejected() {
        let questions = makeQuestions(["t1"])
        let raw = ["t1": IOSJevClient.RawAnswer(type: "score", noul: nil, choice: nil, score: 1.5, confidence: nil)]
        XCTAssertTrue(IOSJevClient.validatedAnswers(for: questions, rawAnswers: raw).isEmpty)
    }

    func testWrongTypeAnswerIsDropped() {
        let questions = makeQuestions(["t1"])
        let raw = ["t1": IOSJevClient.RawAnswer(type: "noul", noul: 0.5, choice: nil, score: nil, confidence: nil)]
        XCTAssertTrue(IOSJevClient.validatedAnswers(for: questions, rawAnswers: raw).isEmpty)
    }

    func testOversizedResponseIsRejected() async throws {
        let big = scoreResponse(answers: ["t1": 0.5]) + Data(repeating: 0x20, count: policy.maxResponseBytes + 1)
        let transport = JevStubTransport { _ in (big, self.httpResponse(status: 200)) }
        let client = IOSJevClient(transport: transport)
        do {
            _ = try await client.decide(makeInput(transport: transport, questions: makeQuestions(["t1"])), policy: policy)
            XCTFail("expected invalidResponse")
        } catch let error as IOSJevRequestError {
            guard case .invalidResponse = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testOversizedStateIsRejectedWithoutNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let client = IOSJevClient(transport: transport)
        let hugeState = String(repeating: "a", count: policy.maxStateBytes + 1)
        let result = try? await client.decide(
            makeInput(transport: transport, questions: makeQuestions(["t1"]), state: hugeState),
            policy: policy
        )
        XCTAssertNil(result)
        XCTAssertEqual(transport.calls, 0)
    }

    // MARK: Deadline / cancellation

    func testTimeoutCancelsUnderlyingTask() async {
        let transport = JevStubTransport { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return (Data(), self.httpResponse(status: 200))
        }
        let client = IOSJevClient(transport: transport)
        let started = Date()
        do {
            _ = try await client.decide(
                makeInput(transport: transport, questions: makeQuestions(["t1"])),
                policy: policy,
                deadlineMs: 200
            )
            XCTFail("expected timeout")
        } catch let error as IOSJevRequestError {
            guard case .timeout = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2.0, "deadline must not wait for the underlying task")
        // 竞速取消后底层任务会收到取消信号（sleep 抛 CancellationError）。
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(transport.sawCancellation, "deadline must cancel the actual network task")
    }

    // MARK: Retry

    func testTransientFailureRetriesOnceWithinDeadline() async throws {
        let counter = JevCallCounter()
        let transport = JevStubTransport { _ in
            let call = counter.next()
            if call == 1 {
                return (Data(), self.httpResponse(status: 500))
            }
            return (self.scoreResponse(answers: ["t1": 0.7]), self.httpResponse(status: 200))
        }
        let client = IOSJevClient(transport: transport)
        let decision = try await client.decide(
            makeInput(transport: transport, questions: makeQuestions(["t1"])),
            policy: policy
        )
        XCTAssertEqual(decision.answers.first?.score, 0.7)
        XCTAssertEqual(transport.calls, 2, "one retry for transient failure")
    }

    func testAuthErrorDoesNotRetry() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 401)) }
        let client = IOSJevClient(transport: transport)
        do {
            _ = try await client.decide(makeInput(transport: transport, questions: makeQuestions(["t1"])), policy: policy)
            XCTFail("expected http error")
        } catch let error as IOSJevRequestError {
            guard case .http(let status, _) = error, status == 401 else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(transport.calls, 1, "401 must not retry")
    }

    func testRetryAbandonsWhenNoDeadlineRemains() async {
        let transport = JevStubTransport { _ in
            (Data(), self.httpResponse(status: 500))
        }
        let client = IOSJevClient(transport: transport)
        do {
            _ = try await client.decide(
                makeInput(transport: transport, questions: makeQuestions(["t1"])),
                policy: policy,
                deadlineMs: 120
            )
            XCTFail("expected timeout/http error")
        } catch {
            // 500 或 timeout 均可接受；关键是不超过 deadline 太多。
        }
        XCTAssertLessThanOrEqual(transport.calls, 2)
    }

    // MARK: Cache

    func testCacheHitAvoidsTransportAndExpiryRetries() async throws {
        let clock = TestClock()
        let transport = JevStubTransport { _ in (self.scoreResponse(answers: ["t1": 0.6]), self.httpResponse(status: 200)) }
        let client = IOSJevClient(transport: transport, now: { clock.now })
        let input = makeInput(transport: transport, questions: makeQuestions(["t1"]))
        _ = try await client.decide(input, policy: policy, cacheKey: "k1")
        _ = try await client.decide(input, policy: policy, cacheKey: "k1")
        XCTAssertEqual(transport.calls, 1, "second call must hit cache")

        // TTL 过期后重新请求。
        clock.advance(TimeInterval(policy.cacheTTLSeconds + 1))
        _ = try await client.decide(input, policy: policy, cacheKey: "k1")
        XCTAssertEqual(transport.calls, 2)
    }

    func testCacheBoundedAtMaxEntries() async throws {
        let counter = JevCallCounter()
        let transport = JevStubTransport { _ in
            let index = counter.next() - 1
            return (self.scoreResponse(answers: ["t\(index)": 0.6]), self.httpResponse(status: 200))
        }
        let client = IOSJevClient(transport: transport)
        for index in 0..<150 {
            _ = try await client.decide(
                makeInput(transport: transport, questions: makeQuestions(["t\(index)"])),
                policy: policy,
                cacheKey: "k\(index)"
            )
        }
        XCTAssertEqual(counter.current, 150)
        // 第 151 次请求（新 key）必须回源；有界淘汰不崩溃。
        _ = try await client.decide(
            makeInput(transport: transport, questions: makeQuestions(["t150"])),
            policy: policy,
            cacheKey: "k150"
        )
        XCTAssertEqual(counter.current, 151)
    }

    // MARK: Missing key & key sanitization

    func testMissingKeyFailsFastWithoutNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let client = IOSJevClient(transport: transport)
        do {
            _ = try await client.decide(
                makeInput(transport: transport, questions: makeQuestions(["t1"]), apiKey: ""),
                policy: policy
            )
            XCTFail("expected missingKey")
        } catch let error as IOSJevRequestError {
            guard case .missingKey = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(transport.calls, 0)
    }

    func testSanitizedAPIKeyStripsEmbeddedNewlinesQuotesAndBearerPrefix() {
        XCTAssertEqual(
            IOSJevClient.sanitizedAPIKey("tsk_live_abc\n123\r\n456"),
            "tsk_live_abc123456"
        )
        XCTAssertEqual(
            IOSJevClient.sanitizedAPIKey("  \"Bearer tsk_live_abc\n\t123\u{200B}\u{FEFF}\"  "),
            "tsk_live_abc123"
        )
        XCTAssertEqual(
            IOSJevClient.sanitizedAPIKey("Authorization: bearer 'tsk_live_\r\nxyz\u{200C}\u{200D}'"),
            "tsk_live_xyz"
        )
        XCTAssertEqual(IOSJevClient.sanitizedAPIKey("Bearer   \n\r\t\u{200B}"), "")
        XCTAssertEqual(IOSJevClient.sanitizedAPIKey("  \n\r\t "), "")
    }

    func testDecideSanitizesAPIKeyAndModelBeforeSendingAuthorizationHeader() async throws {
        var capturedAuth: String?
        let transport = JevStubTransport { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            return (self.scoreResponse(answers: ["t1": 0.8]), self.httpResponse(status: 200))
        }
        let client = IOSJevClient(transport: transport)
        var input = makeInput(
            transport: transport,
            questions: makeQuestions(["t1"]),
            apiKey: "  \"Bearer tsk_live_part1\npart2\r\npart3\u{200B}\"  "
        )
        input.model = "jev-1.14.\n0\r\t"
        let decision = try await client.decide(input, policy: policy)
        XCTAssertEqual(capturedAuth, "Bearer tsk_live_part1part2part3")
        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "jev-1.14.0")
        XCTAssertEqual(decision.answers.first?.score, 0.8)

        // 仅含 Bearer 与空白/换行符的无效 Key 在本地按 missingKey 拒绝。
        do {
            _ = try await client.decide(
                makeInput(transport: transport, questions: makeQuestions(["t1"]), apiKey: "Bearer \n\r\t\u{200B}"),
                policy: policy
            )
            XCTFail("expected missingKey for empty bearer token")
        } catch let error as IOSJevRequestError {
            XCTAssertEqual(error, .missingKey)
        }
        XCTAssertEqual(transport.calls, 1)
    }

    // MARK: vercelGateway（Vercel AI Gateway decision-model）

    /// 请求形态：body {stateParts, questions}，模型与协议版本走 header；
    /// 纯文字作为一个 text part，noul 线上记作 boolean。
    func testVercelRequestShapeAndAnswerMapping() async throws {
        let seenHeaders = NSMutableArray()
        let transport = JevStubTransport { request in
            if let headers = request.allHTTPHeaderFields {
                seenHeaders.add(headers)
            }
            return (self.vercelResponse(answers: [
                "t1": ["type": "score", "score": 2.5, "probabilities": ["2": 0.7, "3": 0.3]],
                "n1": ["type": "boolean", "probability": 0.9],
            ]), self.vercelHTTPResponse())
        }
        let client = IOSJevClient(transport: transport)
        let questions: [IOSJevQuestion] = [
            .score(id: "t1", levels: ["0", "1", "2", "3"], instructions: "score it"),
            .noul(id: "n1", instructions: "prob?"),
        ]
        let decision = try await client.decide(
            vercelInput(questions: questions),
            policy: policy
        )

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["model"], "decision body 不含 model（走 header）")
        XCTAssertNil(object["messages"], "decision body 不是 chat completions 形态")
        XCTAssertNil(object["state"])
        let stateParts = try XCTUnwrap(object["stateParts"] as? [[String: String]])
        XCTAssertEqual(stateParts, [["type": "text", "text": "state"]])
        let questionsMap = try XCTUnwrap(object["questions"] as? [String: Any])
        XCTAssertEqual((questionsMap["t1"] as? [String: Any])?["type"] as? String, "score")
        // noul 在线上必须记作 boolean（Gateway 统一题型）。
        XCTAssertEqual((questionsMap["n1"] as? [String: Any])?["type"] as? String, "boolean")

        let headers = try XCTUnwrap(seenHeaders.firstObject as? [String: String])
        XCTAssertEqual(headers["ai-model-id"], "typesafe-ai/jev")
        XCTAssertEqual(headers["ai-decision-model-specification-version"], "4")
        XCTAssertNil(headers["ai-evaluation-model-specification-version"])
        XCTAssertEqual(headers["ai-gateway-protocol-version"], "0.0.1")
        XCTAssertEqual(headers["ai-gateway-auth-method"], "api-key")
        XCTAssertEqual(headers["Authorization"], "Bearer vercel-key")

        XCTAssertEqual(decision.answers.count, 2)
        XCTAssertEqual(decision.answers.first { $0.id == "t1" }?.score, 2.5)
        XCTAssertEqual(decision.answers.first { $0.id == "n1" }?.noul, 0.9)
        XCTAssertEqual(decision.usage?.inputTokens, 120)
        XCTAssertEqual(decision.usage?.outputTokens, 30)
        XCTAssertEqual(decision.modelVersion, "typesafe-ai/jev", "Gateway 不回显 model，用出站 slug")
    }

    /// Choice/Score confidence 经 providerMetadata.typesafe.confidence[qid]
    /// 注入；boolean 概率译回 noul。
    func testVercelConfidenceAndChoiceMapping() async throws {
        let transport = JevStubTransport { _ in
            (self.vercelResponse(
                answers: [
                    "c1": ["type": "choice", "choice": "a", "probabilities": ["a": 0.8, "b": 0.2]],
                    "s1": ["type": "score", "score": 0.5],
                ],
                confidence: ["c1": 0.66, "s1": 0.4]
            ), self.vercelHTTPResponse())
        }
        let client = IOSJevClient(transport: transport)
        let questions: [IOSJevQuestion] = [
            .choice(id: "c1", options: ["a": "A 选项", "b": nil], instructions: "pick"),
            .score(id: "s1", levels: ["0 无关", "3 相关"], instructions: "rate"),
        ]
        let decision = try await client.decide(vercelInput(questions: questions), policy: policy)
        XCTAssertEqual(decision.answers.first { $0.id == "c1" }?.choice, "a")
        XCTAssertEqual(decision.answers.first { $0.id == "c1" }?.confidence, 0.66)
        XCTAssertEqual(decision.answers.first { $0.id == "s1" }?.confidence, 0.4)
    }

    /// 非 JSON 响应体 → invalidResponse，不得成为有效业务结果。
    func testVercelNonJSONBodyIsInvalidResponse() async {
        let transport = JevStubTransport { _ in
            (Data("not json".utf8), self.vercelHTTPResponse())
        }
        let client = IOSJevClient(transport: transport)
        do {
            _ = try await client.decide(
                vercelInput(questions: makeQuestions(["t1"])),
                policy: policy
            )
            XCTFail("expected invalidResponse")
        } catch let error as IOSJevRequestError {
            guard case .invalidResponse = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// 缺 answers map → invalidResponse（不伪造答案）。
    func testVercelMissingAnswersIsInvalidResponse() async {
        let payload: [String: Any] = ["usage": ["inputTokens": 1, "outputTokens": 1]]
        let transport = JevStubTransport { _ in
            (try! JSONSerialization.data(withJSONObject: payload), self.vercelHTTPResponse())
        }
        let client = IOSJevClient(transport: transport)
        do {
            _ = try await client.decide(
                vercelInput(questions: makeQuestions(["t1"])),
                policy: policy
            )
            XCTFail("expected invalidResponse")
        } catch let error as IOSJevRequestError {
            guard case .invalidResponse = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// 空模型 slug：出站前本地拒绝，零网络流量。
    func testVercelEmptyModelRejectedWithoutNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.vercelHTTPResponse()) }
        let client = IOSJevClient(transport: transport)
        let result = try? await client.decide(
            vercelInput(questions: makeQuestions(["t1"]), model: ""),
            policy: policy
        )
        XCTAssertNil(result)
        XCTAssertEqual(transport.calls, 0)
    }

    // MARK: Native images and Box (Jev 1.14)

    func testTextRequestOmitsAssetsAndImageHeader() async throws {
        let transport = JevStubTransport { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"))
            return (self.scoreResponse(answers: ["t1": 0.7]), self.httpResponse(status: 200))
        }
        let client = IOSJevClient(transport: transport)
        _ = try await client.decide(makeInput(transport: transport, questions: makeQuestions(["t1"])), policy: policy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.lastBody)) as? [String: Any])
        XCTAssertNil(object["assets"])
        XCTAssertEqual(Set(object.keys), ["model", "state", "questions"])
    }

    func testNativeImageWireHeaderAndExactRequestBytes() async throws {
        let image = Data([0xff, 0xd8, 0xff, 0x00, 0xfb])
        let transport = JevStubTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"), "true")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (self.scoreResponse(answers: ["t1": 0.7]), self.httpResponse(status: 200))
        }
        let client = IOSJevClient(transport: transport)
        var input = makeInput(
            transport: transport, questions: makeQuestions(["t1"]), state: "Current screen: image-unique-ref",
            assets: ["image-unique-ref": IOSJevImageAsset(data: image, format: "jpg")]
        )
        input.model = "jev-1.14.0"
        let reservedBytes = try client.requestBodyByteCount(input)
        let decision = try await client.decide(input, policy: policy)
        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let assets = try XCTUnwrap(object["assets"] as? [String: [String: Any]])
        let asset = try XCTUnwrap(assets["image-unique-ref"])
        XCTAssertEqual(Set(asset.keys), ["type", "format", "data_base64"])
        XCTAssertEqual(asset["type"] as? String, "image")
        XCTAssertEqual(asset["format"] as? String, "jpg")
        XCTAssertEqual(asset["data_base64"] as? String, image.base64EncodedString())
        XCTAssertEqual(object["state"] as? String, input.state)
        XCTAssertEqual(object["model"] as? String, "jev-1.14.0")
        XCTAssertEqual(decision.requestBytes, body.count)
        XCTAssertEqual(reservedBytes, body.count, "budget reservation includes the encoded assets")
    }

    func testAssetReferencesAcceptOnlyValueLocations() throws {
        let assets = ["unique-image-ref": IOSJevImageAsset(data: Data([1]), format: "png")]
        let questions: [IOSJevQuestion] = [
            .noul(id: "instructions", instructions: "Compare unique-image-ref with the current screen"),
            .choice(id: "criteria", options: ["match": "Looks like unique-image-ref"], instructions: "Choose"),
            .score(id: "levels", levels: ["none", "unique-image-ref"], instructions: "Rate"),
        ]
        for question in questions {
            XCTAssertNoThrow(try IOSJevClient.encodedRequestBody(
                model: "jev-1.14.0", state: "screen", questions: [question], style: .systemone, assets: assets
            ))
        }
        let keyOnly = IOSJevQuestion.choice(id: "unique-image-ref", options: ["unique-image-ref": "ordinary text"], instructions: "Choose")
        XCTAssertThrowsError(try IOSJevClient.encodedRequestBody(
            model: "jev-1.14.0", state: "screen", questions: [keyOnly], style: .systemone, assets: assets
        )) { error in
            XCTAssertEqual(error as? IOSJevRequestError, .invalidRequest("unreferenced image asset"))
        }
    }

    func testInvalidAssetsAreRejectedBeforeNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.httpResponse(status: 200)) }
        let client = IOSJevClient(transport: transport)
        let invalidAssets: [[String: IOSJevImageAsset]] = [
            [" \n": .init(data: Data([1]), format: "jpg")],
            ["image-ref": .init(data: Data(), format: "png")],
            ["image-ref": .init(data: Data([1]), format: "webp")],
            ["missing-ref": .init(data: Data([1]), format: "jpeg")],
        ]
        for assets in invalidAssets {
            do {
                _ = try await client.decide(makeInput(
                    transport: transport, questions: makeQuestions(["t1"]), state: "image-ref", assets: assets
                ), policy: policy)
                XCTFail("invalid assets must not be sent")
            } catch let error as IOSJevRequestError {
                guard case .invalidRequest = error else { return XCTFail("wrong error: \(error)") }
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(transport.calls, 0)
    }

    func testGatewayImageWirePreservesOrderContextAndExactBytes() async throws {
        let firstReference = "amber-image-0587b52b-e6a3-4634-b002-8a843e376194"
        let secondReference = "amber-image-c015231e-2314-4d10-a472-cf4608c53b4a"
        let firstData = Data([1, 2, 3])
        let secondData = Data([4, 5, 6])
        let transport = JevStubTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v4/ai/decision-model")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ai-decision-model-specification-version"), "4")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ai-model-id"), "typesafe-ai/jev-1.14.0")
            XCTAssertNil(request.value(forHTTPHeaderField: "ai-evaluation-model-specification-version"))
            XCTAssertNil(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"))
            return (self.vercelResponse(answers: ["t1": ["type": "score", "score": 0.7]]), self.vercelHTTPResponse())
        }
        let client = IOSJevClient(transport: transport)
        let input = vercelInput(
            questions: makeQuestions(["t1"]), model: "typesafe-ai/jev-1.14.0",
            state: "Before: \(firstReference)\nAfter: \(secondReference)\nCompare both screens.",
            assets: [
                secondReference: .init(data: secondData, format: "png"),
                firstReference: .init(data: firstData, format: "jpeg"),
            ]
        )
        let reservedBytes = try client.requestBodyByteCount(input)
        let decision = try await client.decide(input, policy: policy)
        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["stateParts", "questions"])
        let parts = try XCTUnwrap(object["stateParts"] as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "file", "text", "file", "text"])
        XCTAssertEqual(parts[0]["text"] as? String, "Before: ")
        XCTAssertEqual(parts[2]["text"] as? String, "\nAfter: ")
        XCTAssertEqual(parts[4]["text"] as? String, "\nCompare both screens.")
        XCTAssertEqual(parts[1]["mediaType"] as? String, "image/jpeg")
        XCTAssertEqual(parts[3]["mediaType"] as? String, "image/png")
        XCTAssertEqual(parts[1]["data"] as? [String: String], ["type": "data", "data": firstData.base64EncodedString()])
        XCTAssertEqual(parts[3]["data"] as? [String: String], ["type": "data", "data": secondData.base64EncodedString()])
        XCTAssertEqual(reservedBytes, body.count)
        XCTAssertEqual(decision.requestBytes, body.count)
        let text = parts.compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(text.contains(firstReference))
        XCTAssertFalse(text.contains(secondReference))
    }

    func testGatewayRejectsBoxBeforeNetwork() async {
        let transport = JevStubTransport { _ in (Data(), self.vercelHTTPResponse()) }
        let client = IOSJevClient(transport: transport)
        do {
            _ = try await client.decide(vercelInput(questions: [.box(id: "target", instructions: "Find the button")]), policy: policy)
            XCTFail("unsupported gateway Box request must fail locally")
        } catch let error as IOSJevRequestError {
            XCTAssertEqual(error, .invalidRequest("box questions require native API"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(transport.calls, 0)
    }

    func testGatewayRejectsUnsupportedImageReferencesWithoutDroppingImage() async {
        let transport = JevStubTransport { _ in (Data(), self.vercelHTTPResponse()) }
        let client = IOSJevClient(transport: transport)
        let assets = ["image-ref": IOSJevImageAsset(data: Data([1]), format: "jpg")]
        let inputs = [
            vercelInput(questions: [.noul(id: "t1", instructions: "Inspect image-ref")], assets: assets),
            vercelInput(questions: [.choice(id: "t1", options: ["a": "image-ref"], instructions: "Pick")], assets: assets),
            vercelInput(questions: makeQuestions(["t1"]), state: "image-ref then image-ref", assets: assets),
            vercelInput(questions: makeQuestions(["t1"]), state: "unreferenced", assets: assets),
            vercelInput(questions: makeQuestions(["t1"]), state: "image-ref-extension", assets: [
                "image-ref": .init(data: Data([1]), format: "jpg"),
                "image-ref-extension": .init(data: Data([2]), format: "png"),
            ]),
        ]
        for input in inputs {
            do {
                _ = try await client.decide(input, policy: policy)
                XCTFail("an image must not be dropped from an unsupported reference location")
            } catch let error as IOSJevRequestError {
                guard case .invalidRequest = error else { return XCTFail("wrong error: \(error)") }
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(transport.calls, 0)
    }

    func testImageBodyUsesSeparateLimitWithoutExpandingStateLimit() async throws {
        let transport = JevStubTransport { _ in (self.scoreResponse(answers: ["t1": 0.7]), self.httpResponse(status: 200)) }
        let client = IOSJevClient(transport: transport)
        let asset = IOSJevImageAsset(data: Data(repeating: 0, count: policy.maxRequestBytes), format: "png")
        let input = makeInput(
            transport: transport, questions: makeQuestions(["t1"]), state: "image-ref", assets: ["image-ref": asset]
        )
        let decision = try await client.decide(input, policy: policy)
        XCTAssertGreaterThan(decision.requestBytes, policy.maxRequestBytes)
        XCTAssertLessThan(decision.requestBytes, IOSJevPolicy.maxImageRequestBytes)
        var hugeState = input
        hugeState.state = "image-ref" + String(repeating: "a", count: policy.maxStateBytes)
        do {
            _ = try await client.decide(hugeState, policy: policy)
            XCTFail("image support must not expand state limit")
        } catch let error as IOSJevRequestError {
            XCTAssertEqual(error, .stateTooLarge(bytes: hugeState.state.utf8.count))
        }
        var oversizedImage = input
        oversizedImage.assets["image-ref"] = .init(data: Data(repeating: 0, count: IOSJevPolicy.maxImageRequestBytes), format: "png")
        do {
            _ = try await client.decide(oversizedImage, policy: policy)
            XCTFail("encoded image request must respect its hard limit")
        } catch let error as IOSJevRequestError {
            guard case .requestTooLarge(let bytes) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertGreaterThan(bytes, IOSJevPolicy.maxImageRequestBytes)
        }
        XCTAssertEqual(transport.calls, 1)
    }

    func testGatewayImageBodyUsesEncodedImageLimitAndRetainsStateLimit() async throws {
        let transport = JevStubTransport { _ in
            (self.vercelResponse(answers: ["t1": ["type": "score", "score": 0.7]]), self.vercelHTTPResponse())
        }
        let client = IOSJevClient(transport: transport)
        var input = vercelInput(
            questions: makeQuestions(["t1"]), model: "typesafe-ai/jev-1.14.0", state: "image-ref",
            assets: ["image-ref": .init(data: Data(repeating: 0, count: policy.maxRequestBytes), format: "png")]
        )
        let decision = try await client.decide(input, policy: policy)
        XCTAssertGreaterThan(decision.requestBytes, policy.maxRequestBytes)
        XCTAssertLessThan(decision.requestBytes, IOSJevPolicy.maxImageRequestBytes)
        input.state = "image-ref" + String(repeating: "a", count: policy.maxStateBytes)
        do {
            _ = try await client.decide(input, policy: policy)
            XCTFail("Gateway images must not expand the state limit")
        } catch let error as IOSJevRequestError {
            XCTAssertEqual(error, .stateTooLarge(bytes: input.state.utf8.count))
        }
        input.state = "image-ref"
        input.assets["image-ref"] = .init(data: Data(repeating: 0, count: IOSJevPolicy.maxImageRequestBytes), format: "png")
        do {
            _ = try await client.decide(input, policy: policy)
            XCTFail("Gateway images must respect the encoded request limit")
        } catch let error as IOSJevRequestError {
            guard case .requestTooLarge(let bytes) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertGreaterThan(bytes, IOSJevPolicy.maxImageRequestBytes)
        }
        XCTAssertEqual(transport.calls, 1)
    }

    func testBoxRequestHeaderWireAndAnswerMapping() async throws {
        let payload: [String: Any] = [
            "model": "jev-1.14.0",
            "answers": ["target": ["type": "box", "box": ["top": 0.25, "bottom": 0.82, "left": 0.44, "right": 0.84], "confidence": 0.92]],
        ]
        let transport = JevStubTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"), "true")
            return (try JSONSerialization.data(withJSONObject: payload), self.httpResponse(status: 200))
        }
        let client = IOSJevClient(transport: transport)
        let input = makeInput(transport: transport, questions: [.box(id: "target", instructions: "Find the mug")])
        let decision = try await client.decide(input, policy: policy)
        XCTAssertEqual(decision.answers.first?.box, IOSJevBox(top: 0.25, bottom: 0.82, left: 0.44, right: 0.84))
        XCTAssertEqual(decision.answers.first?.confidence, 0.92)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.lastBody)) as? [String: Any])
        let questions = try XCTUnwrap(object["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions["target"]?["type"] as? String, "box")
        XCTAssertNil(questions["target"]?["criteria"])
        XCTAssertNil(object["assets"], "Box alone does not encode an empty assets map")
        var oversized = input
        oversized.questions = [.box(id: "target", instructions: String(repeating: "a", count: policy.maxRequestBytes))]
        do {
            _ = try await client.decide(oversized, policy: policy)
            XCTFail("Box without assets keeps the text body limit")
        } catch let error as IOSJevRequestError {
            guard case .requestTooLarge = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(transport.calls, 1)
    }

    func testBoxValidationDropsInvalidEdgesAndSanitizesConfidence() {
        let question = IOSJevQuestion.box(id: "target", instructions: "Find the mug")
        let invalidBoxes = [
            IOSJevBox(top: .nan, bottom: 1, left: 0, right: 1),
            IOSJevBox(top: 0, bottom: .infinity, left: 0, right: 1),
            IOSJevBox(top: -0.1, bottom: 1, left: 0, right: 1),
            IOSJevBox(top: 0, bottom: 1, left: 0, right: 1.01),
            IOSJevBox(top: 0.4, bottom: 0.4, left: 0, right: 1),
            IOSJevBox(top: 0, bottom: 1, left: 0.8, right: 0.2),
        ]
        for box in invalidBoxes {
            let raw = IOSJevClient.RawAnswer(type: "box", confidence: 0.9, box: box)
            XCTAssertTrue(IOSJevClient.validatedAnswers(for: [question], rawAnswers: ["target": raw]).isEmpty)
        }
        let fullImage = IOSJevBox(top: 0, bottom: 1, left: 0, right: 1)
        for confidence in [Double.nan, .infinity, -0.1, 1.1] {
            let raw = IOSJevClient.RawAnswer(type: "box", confidence: confidence, box: fullImage)
            let answer = IOSJevClient.validatedAnswers(for: [question], rawAnswers: ["target": raw]).first
            XCTAssertEqual(answer?.box, fullImage)
            XCTAssertNil(answer?.confidence)
        }
        XCTAssertTrue(IOSJevClient.validatedAnswers(
            for: [question], rawAnswers: ["target": .init(type: "box", confidence: 0.9)]
        ).isEmpty)
    }
}
