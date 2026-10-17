import XCTest
@testable import iosApp

final class IOSJevMultimodalCoordinatorTests: XCTestCase {
    private func settings() -> IOSJevSettings {
        var value = IOSJevSettings()
        value.setPinnedModelVersion("jev-1.14.0")
        value.setMode(.active, for: .phoneActions)
        value.setScopes([.selectedTaskText, .phoneContent, .phoneScreenshots], for: .phoneActions)
        return value
    }

    private func coordinator(_ settings: IOSJevSettings, _ transport: JevStubTransport) -> IOSJevDecisionCoordinator {
        IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport), settingsProvider: { settings },
            apiKeyProvider: { "fixture-key" }, now: { Date() }, metricsStore: { _, _ in }
        ))
    }

    private func response(for request: URLRequest, model: String = "jev-1.14.0") throws -> (Data, HTTPURLResponse) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let questions = try XCTUnwrap(object["questions"] as? [String: Any])
        let answers = Dictionary(uniqueKeysWithValues: questions.keys.map { ($0, ["type": "noul", "noul": 1.0] as [String: Any]) })
        return (try JSONSerialization.data(withJSONObject: ["model": model, "answers": answers]), jevResponse(200))
    }

    private func part(id: String = "phone", bytes: Int = 100) -> IOSJevBatchPart {
        IOSJevBatchPart(
            id: id, useCase: .phoneActions, requiredScopes: [.selectedTaskText, .phoneContent],
            state: "Current screenshot: image-fixture", questions: [.noul(id: "visible", instructions: "Is a button visible?")],
            assets: ["image-fixture": IOSJevImageAsset(data: Data(repeating: 1, count: bytes), format: "jpg")],
            cacheKey: "same-text"
        )
    }

    func testDeniedPhonePartCannotLeakImageIntoAllowedTextPart() async throws {
        var settings = settings()
        settings.setScopes([.selectedTaskText, .phoneContent], for: .phoneActions)
        settings.setMode(.active, for: .toolDiscovery)
        let transport = JevStubTransport { request in
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(object["assets"])
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("image-fixture"))
            return try self.response(for: request)
        }
        let outcomes = await coordinator(settings, transport).decideBatch(parts: [
            part(),
            IOSJevBatchPart(id: "tools", useCase: .toolDiscovery, requiredScopes: [.toolMetadata, .selectedTaskText],
                            state: "Allowed tool metadata", questions: [.noul(id: "relevant", instructions: "Is this useful?")])
        ], context: .init(turnBudgetKey: "turn", inputHash: "input"))
        guard case .skipped(let reason)? = outcomes["phone"] else { return XCTFail("phone image must be denied") }
        XCTAssertEqual(reason, "scope_not_allowed")
        guard case .applied? = outcomes["tools"] else { return XCTFail("allowed text must remain usable") }
        XCTAssertEqual(transport.calls, 1)
    }

    func testImageBodyOverTextLimitIsSentAndChargedToDailyByteBudget() async throws {
        var settings = settings()
        settings.policy.dailyRequestBodyBudgetBytes = 130_000
        let transport = JevStubTransport { request in
            XCTAssertGreaterThan(try XCTUnwrap(request.httpBody).count, settings.policy.maxRequestBytes)
            XCTAssertEqual(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"), "true")
            return try self.response(for: request)
        }
        let coordinator = coordinator(settings, transport)
        let context = IOSJevRunContext(turnBudgetKey: "turn", inputHash: "input")
        let first = await coordinator.decideBatch(parts: [part(bytes: 72_000)], context: context)
        guard case .applied(let decision)? = first["phone"] else { return XCTFail("image request should fit image budget") }
        XCTAssertEqual(decision.requestBytes, transport.lastBody?.count)
        let second = await coordinator.decideBatch(parts: [part(bytes: 72_000)], context: context)
        guard case .skipped(let reason)? = second["phone"] else { return XCTFail("image bytes must count toward daily budget") }
        XCTAssertEqual(reason, "budget_exhausted")
        XCTAssertEqual(transport.calls, 1)
    }

    func testImagesNeverUseCallerTextCacheKey() async throws {
        let transport = JevStubTransport { try self.response(for: $0) }
        let coordinator = coordinator(settings(), transport)
        let context = IOSJevRunContext(turnBudgetKey: "turn", inputHash: "same-text")
        let first = await coordinator.decideBatch(parts: [part(bytes: 100)], context: context)
        let second = await coordinator.decideBatch(parts: [part(bytes: 200)], context: context)
        guard case .applied? = first["phone"], case .applied? = second["phone"] else { return XCTFail("both image decisions must apply") }
        XCTAssertEqual(transport.calls, 2)
    }

    func testImageBodyOverImageLimitIsRejectedBeforeNetwork() async {
        let transport = JevStubTransport { try self.response(for: $0) }
        let outcomes = await coordinator(settings(), transport).decideBatch(
            parts: [part(bytes: IOSJevPolicy.maxImageRequestBytes)],
            context: .init(turnBudgetKey: "turn", inputHash: "input")
        )
        guard case .failed(let reason)? = outcomes["phone"] else { return XCTFail("oversize image request must fail") }
        XCTAssertEqual(reason, "request_too_large")
        XCTAssertEqual(transport.calls, 0)
    }

    func testVersionUpgradeTestsNewModelAndLeavesPersistenceToSettingsOwner() async throws {
        var settings = settings()
        settings.setPinnedModelVersion("jev-1.13.0")
        let transport = JevStubTransport { request in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "jev-1.14.0")
            XCTAssertNil(object["assets"], "upgrade test uses synthetic text, never phone content")
            return try self.response(for: request)
        }
        let result = await coordinator(settings, transport).runConnectionTest(apiKey: "fixture-key", modelVersion: "jev-1.14.0")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.modelVersion, "jev-1.14.0")
        XCTAssertEqual(settings.pinnedModelVersion, "jev-1.13.0")
    }

    func testVersionUpgradeRejectsUnexpectedResolvedModel() async throws {
        let transport = JevStubTransport { try self.response(for: $0, model: "jev-1.13.0") }
        let result = await coordinator(settings(), transport).runConnectionTest(apiKey: "fixture-key", modelVersion: "jev-1.14.0")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.errorReason, "model_version_mismatch")
    }

    func testGatewayVersionUpgradeUsesDecisionProtocolThenPersistsFixedSlug() async throws {
        var settings = settings()
        settings.setAPIStyle(.vercelGateway)
        settings.setProviderModel("typesafe-ai/jev")
        let transport = JevStubTransport { request in
            XCTAssertEqual(request.url, IOSJevSettings.vercelGatewayEndpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "ai-model-id"), "typesafe-ai/jev-1.14.0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ai-decision-model-specification-version"), "4")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNil(object["state"])
            let parts = try XCTUnwrap(object["stateParts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 1)
            XCTAssertEqual(parts[0]["type"] as? String, "text")
            return (Data(#"{"answers":{"connectivity":{"type":"boolean","probability":1.0}}}"#.utf8), jevResponse(200))
        }
        let result = await coordinator(settings, transport).runConnectionTest(apiKey: "fixture-key", modelVersion: settings.recommendedModelForAPI)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(settings.providerModel, "typesafe-ai/jev", "testing cannot mutate the saved model")
        settings.setProviderModel(try XCTUnwrap(result.modelVersion))
        let suite = "JevGatewayUpgrade-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        IOSSharedSettingsStore(userDefaults: defaults).updateJevSettings(settings)
        let loaded = IOSSharedSettingsStore(userDefaults: defaults).jevSettings
        XCTAssertEqual(loaded.activeModelVersion, "typesafe-ai/jev-1.14.0")
        XCTAssertTrue(loaded.canSendPhoneScreenshots(for: .phoneActions))
        XCTAssertEqual(loaded.effectiveMode(for: .phoneActions), .active)
        XCTAssertEqual(loaded.pinnedModelVersion, "jev-1.14.0", "Gateway upgrade preserves independent native pin")
    }
}
