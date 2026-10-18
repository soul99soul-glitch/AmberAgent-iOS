import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

// The production executor dispatches its actor-bound work internally. Mirror
// the background runtime test harness when crossing Swift's executor boundary.
private final class SiteMemoryTestExecutor: @unchecked Sendable {
    private let executor: any IOSToolExecutor

    init(_ executor: any IOSToolExecutor) { self.executor = executor }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        await executor.execute(name: name, arguments: arguments, isUserInitiated: isUserInitiated)
    }
}

@MainActor
final class IOSWebMountSiteMemoryTests: IOSWebMountToolTestCase {
    func testSiteMemoryApprovalBaselineIsStableUntilStoredMemoryChanges() throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        let entry = IOSWebMountSiteMemoryEntry(
            id: "existing", kind: .pitfalls, name: "测试", detail: "测试条目",
            urlPattern: nil, locatorJSON: nil, updatedAtMillis: 1, source: .agent
        )
        controller.registry.replaceSiteMemory(host: "github.com", entries: [entry])
        let proposal = #"{"host":"github.com","action":"propose","changes":[{"operation":"delete","id":"existing"}]}"#
        let initial = try XCTUnwrap(executor.webMountApprovalPreview(toolName: "wm_site_memory", input: proposal))
        let baselines = try (0..<100).map { _ in
            try XCTUnwrap(executor.webMountApprovalPreview(toolName: "wm_site_memory", input: proposal)?.siteMemoryBaseline)
        }
        XCTAssertTrue(baselines.allSatisfy { $0 == initial.siteMemoryBaseline },
                      "Unchanged stored memory must not make approval stale")
        controller.registry.replaceSiteMemory(host: "github.com", entries: [entry, .init(
            id: "new", kind: .pitfalls, name: "新增", detail: "不同内容",
            urlPattern: nil, locatorJSON: nil, updatedAtMillis: 2, source: .user
        )])
        let changed = try XCTUnwrap(executor.webMountApprovalPreview(toolName: "wm_site_memory", input: proposal))
        XCTAssertNotEqual(changed.siteMemoryBaseline, initial.siteMemoryBaseline,
                          "Actual edits while an approval is pending must still invalidate it")
    }

    func testSiteMemoryHighRiskAutoApprovalAppliesBatchWithoutForegroundCard() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        let policy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:], globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: true, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        let proposal = #"{"host":"github.com","action":"propose","changes":[{"operation":"add","kind":"pitfalls","name":"一","detail":"说明一"},{"operation":"add","kind":"pitfalls","name":"二","detail":"说明二"}]}"#
        let result = await executor.execute(executor.executionRequest(
            toolName: "wm_site_memory", operation: proposal, isUserInitiated: false,
            executionPolicy: policy
        ))
        guard case .webMountResult(let output) = result else {
            return XCTFail("High-risk auto-approval must apply the batch, got \(result)")
        }
        XCTAssertEqual(try jsonObject(output)["ok"] as? Bool, true)
        XCTAssertEqual(controller.registry.siteMemory(host: "github.com").count, 2)
    }

    func testSiteMemoryConsecutiveApprovalsAddUpdateDeleteAndRejectRealConflict() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        let conversationId = KotlinUuid.companion.random()
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(), sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: executor, searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let policy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:], globalAutoApproveEnabled: true,
            highRiskAutoApproveEnabled: false, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        let model = Model(
            modelId: "site-memory-test", displayName: "Site Memory Test", id: KotlinUuid.companion.random(),
            type: ModelType.chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil
        )
        let params = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: nil,
            tools: ToolKt.iosToolDeclarations(names: ["wm_site_memory"]), reasoningLevel: .off,
            customHeaders: [], customBody: []
        )
        func pending(_ changes: [[String: Any]], executionPolicy: IOSExecutionPolicySnapshot? = nil) -> ChatPendingToolApproval {
            let tool = UIMessagePart.Tool(
                toolCallId: UUID().uuidString, toolName: "wm_site_memory",
                input: IOSWebMountController.json(["host": "www.github.com", "action": "propose", "changes": changes]),
                output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )
            let assistant = UIMessage(
                id: KotlinUuid.companion.random(), role: MessageRole.assistant, parts: [tool], annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 10, day: 2,
                                                       hour: 0, minute: 0, second: 0, nanosecond: 0),
                finishedAt: nil, modelId: nil, usage: nil, translation: nil
            )
            return ChatPendingToolApproval(
                toolCall: tool,
                providerSetting: IOSCouncilRoomRunner.makeProviderSetting(baseUrl: "https://example.com/v1", apiKey: "test"),
                params: params, runId: "site-memory-test", startedAt: 1, inputDigest: "test",
                conversationId: conversationId, baseMessages: [assistant], executionPolicy: executionPolicy ?? policy
            )
        }
        func request(_ pending: ChatPendingToolApproval) async throws -> WebMountToolApprovalRequest {
            let result = await runtime.execute(.init(kind: .webMount, toolCall: pending.toolCall), context: pending)
            guard case .waitingForApproval(.webMount(let approval)) = result else {
                throw NSError(domain: "SiteMemoryApproval", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Ordinary auto-approval must still show a card: \(result)"])
            }
            XCTAssertEqual(approval.siteId, "github", "The www equivalent must identify the registered site in the card")
            return approval
        }
        func resultObject(_ messages: [UIMessage]) throws -> [String: Any] {
            let text = try XCTUnwrap(messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
                .first?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.first)
            return try jsonObject(text)
        }
        func finish(_ pending: ChatPendingToolApproval, _ approval: WebMountToolApprovalRequest) async throws -> [String: Any] {
            try resultObject(await runtime.finishWebMountApproval(pending: pending, allow: true, approvalRequest: approval))
        }
        for index in 0..<3 {
            let call = pending([["operation": "add", "kind": "pitfalls", "name": "条目\(index)", "detail": "说明"]])
            let approval = try await request(call)
            let result = try await finish(call, approval)
            XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        }
        XCTAssertEqual(controller.registry.siteMemory(host: "github.com").count, 3)
        let id = try XCTUnwrap(controller.registry.siteMemory(host: "github.com").first?.id)
        let update = pending([["operation": "update", "id": id, "kind": "pitfalls", "name": "已更新", "detail": "新说明"]])
        let updateApproval = try await request(update)
        let updated = try await finish(update, updateApproval)
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        XCTAssertEqual(controller.registry.siteMemory(host: "github.com").first?.name, "已更新")
        let deletion = pending([["operation": "delete", "id": id]])
        let deleteApproval = try await request(deletion)
        let deleted = try await finish(deletion, deleteApproval)
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        XCTAssertFalse(controller.registry.siteMemory(host: "github.com").contains { $0.id == id })

        let remainingId = try XCTUnwrap(controller.registry.siteMemory(host: "github.com").first?.id)
        let conflicted = pending([["operation": "delete", "id": remainingId]])
        let conflictApproval = try await request(conflicted)
        var entries = controller.registry.siteMemory(host: "github.com")
        entries.append(.init(id: "manual-edit", kind: .pitfalls, name: "手工新增", detail: "审批期间修改",
                             urlPattern: nil, locatorJSON: nil, updatedAtMillis: 3, source: .user))
        controller.registry.replaceSiteMemory(host: "github.com", entries: entries)
        let stale = try await finish(conflicted, conflictApproval)
        XCTAssertEqual(stale["error_code"] as? String, "stale_site_memory_proposal")
        XCTAssertEqual(controller.registry.siteMemory(host: "github.com"), entries)
        let retry = try await request(conflicted)
        let retried = try await finish(conflicted, retry)
        XCTAssertEqual(retried["ok"] as? Bool, true, "Fresh approval must work after a real conflict: \(retried)")

        let highRisk = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:], globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: true, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        let automatic = pending([["operation": "add", "kind": "pitfalls", "name": "前台自动", "detail": "说明"]],
                                executionPolicy: highRisk)
        let foreground = await runtime.execute(.init(kind: .webMount, toolCall: automatic.toolCall), context: automatic)
        guard case .completed(let messages) = foreground else { return XCTFail("\(foreground)") }
        XCTAssertEqual(try resultObject(messages)["ok"] as? Bool, true)

        let background = SiteMemoryTestExecutor(try XCTUnwrap(runtime.backgroundToolExecutors(
            providerSetting: automatic.providerSetting, params: params, runId: "site-memory-test",
            conversationId: conversationId, executionPolicy: highRisk
        )["wm_site_memory"]))
        let backgroundResult = await background.execute(name: "wm_site_memory", arguments: automatic.toolCall.input, isUserInitiated: false)
        guard case .filled(let output) = backgroundResult else { return XCTFail("\(backgroundResult)") }
        XCTAssertEqual(try jsonObject(output)["ok"] as? Bool, true)

        // Jev escalation narrows this same snapshot before dispatch. The
        // runtime must restore approval rather than losing or applying a write.
        let narrowed = pending([["operation": "add", "kind": "pitfalls", "name": "被收紧", "detail": "不应写入"]],
                               executionPolicy: highRisk.withoutAutoApprove())
        let beforeDenial = controller.registry.siteMemory(host: "github.com")
        let narrowedApproval = try await request(narrowed)
        let denied = try resultObject(await runtime.finishWebMountApproval(
            pending: narrowed, allow: false, approvalRequest: narrowedApproval
        ))
        XCTAssertEqual(denied["denied"] as? Bool, true)
        XCTAssertEqual(controller.registry.siteMemory(host: "github.com"), beforeDenial)
        let narrowedBackground = SiteMemoryTestExecutor(try XCTUnwrap(runtime.backgroundToolExecutors(
            providerSetting: narrowed.providerSetting, params: params, runId: "site-memory-test",
            conversationId: conversationId, executionPolicy: highRisk.withoutAutoApprove()
        )["wm_site_memory"]))
        guard case .denied = await narrowedBackground.execute(
            name: "wm_site_memory", arguments: narrowed.toolCall.input, isUserInitiated: false
        ) else { return XCTFail("Background execution must report a foreground approval requirement") }
        XCTAssertEqual(controller.registry.siteMemory(host: "github.com"), beforeDenial)
    }

    func testSiteMemoryCapabilityAutoApprovalIsReviewedByJevInForegroundAndBackground() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        var configured = IOSJevSettings()
        configured.setMode(.active, for: .autoApprovalGate)
        configured.pinnedModelVersion = "jev-fixed-v1"
        let jevSettings = configured
        sharedSettings.updateJevSettings(jevSettings)
        let transport = JevStubTransport { _ in
            let answers = ["destructive": 0.1, "exfiltration": 0.95, "offTask": 0.1, "authorized": 0.1]
            let payload: [String: Any] = [
                "model": "jev-latest",
                "answers": Dictionary(uniqueKeysWithValues: answers.map {
                    ("single.\($0.key)", ["type": "noul", "noul": $0.value])
                })
            ]
            return (try! JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport), settingsProvider: { jevSettings },
            apiKeyProvider: { "test-key" }, now: { Date() }, metricsStore: { _, _ in }
        ))
        let gate = IOSJevAutoApprovalGate(deps: .init(coordinator: coordinator, settingsProvider: { jevSettings }))
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(), sharedSettings: sharedSettings,
            localToolExecutor: executor, searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] }), autoApprovalGate: gate
        )
        let capability = try XCTUnwrap(IOSCapabilityRegistry.capability(forToolName: "wm_site_memory"))
        let policy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [capability.id: IOSAgentPermissionPolicy.autoApproveHighRisk.rawValue],
            globalAutoApproveEnabled: false, highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: false, webSearchEnabled: false
        )
        let model = Model(
            modelId: "site-memory-test", displayName: "Site Memory Test", id: KotlinUuid.companion.random(),
            type: ModelType.chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil
        )
        let params = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: nil,
            tools: ToolKt.iosToolDeclarations(names: ["wm_site_memory"]), reasoningLevel: .off,
            customHeaders: [], customBody: []
        )
        let tool = UIMessagePart.Tool(
            toolCallId: UUID().uuidString, toolName: "wm_site_memory",
            input: #"{"host":"github.com","action":"propose","changes":[{"operation":"add","kind":"pitfalls","name":"应被复核","detail":"不能自动落库"}]}"#,
            output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )
        let conversationId = KotlinUuid.companion.random()
        let pending = ChatPendingToolApproval(
            toolCall: tool,
            providerSetting: IOSCouncilRoomRunner.makeProviderSetting(baseUrl: "https://example.com/v1", apiKey: "test"),
            params: params, runId: "site-memory-jev-review", startedAt: 1, inputDigest: "test",
            conversationId: conversationId, baseMessages: [], executionPolicy: policy
        )
        let result = await runtime.execute(.init(kind: .webMount, toolCall: tool), context: pending)
        if case .waitingForApproval(.webMount) = result {} else {
            XCTFail("Capability auto-approval must reach the active Jev gate: \(result)")
        }
        XCTAssertGreaterThan(transport.calls, 0)
        XCTAssertEqual(gate.escalationReasons(requestId: tool.toolCallId), ["外发数据"])
        XCTAssertTrue(controller.registry.siteMemory(host: "github.com").isEmpty)

        let background = SiteMemoryTestExecutor(try XCTUnwrap(runtime.backgroundToolExecutors(
            providerSetting: pending.providerSetting, params: params, runId: pending.runId,
            conversationId: conversationId, executionPolicy: policy
        )["wm_site_memory"]))
        let outcome = await background.execute(name: "wm_site_memory", arguments: tool.input, isUserInitiated: false)
        if case .denied = outcome {} else { XCTFail("Jev must require foreground approval in background: \(outcome)") }
        XCTAssertTrue(controller.registry.siteMemory(host: "github.com").isEmpty)
    }

    func testSiteMemoryJevReviewEligibilityUsesCapabilityPolicyAndRunSnapshot() async throws {
        let executor = makeExecutor(webMountController: makeWebMountController(globalEnabled: true))
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(), sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: executor, searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let cases: [(String, IOSAgentPermissionPolicy, Bool, Bool)] = [
            ("wm_site_memory", .autoApproveHighRisk, false, true),
            ("workspace_file_read", .autoApprove, false, true),
            ("workspace_file_write", .autoApproveHighRisk, false, true),
            ("wm_site_memory", .disabled, true, false),
            ("workspace_file_write", .disabled, true, false),
            ("wm_site_memory", .askEveryTime, false, false),
            ("workspace_file_read", .askEveryTime, true, true)
        ]
        for (name, capabilityPolicy, globalEnabled, expected) in cases {
            let capability = try XCTUnwrap(IOSCapabilityRegistry.capability(forToolName: name))
            let snapshot = IOSExecutionPolicySnapshot(
                capabilityPolicies: [capability.id: capabilityPolicy.rawValue],
                globalAutoApproveEnabled: globalEnabled, highRiskAutoApproveEnabled: false,
                execJavaScriptEnabled: false, webSearchEnabled: false
            )
            let tool = UIMessagePart.Tool(
                toolCallId: UUID().uuidString, toolName: name, input: "{}", output: [],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )
            let eligible = await runtime.withExecutionPolicy(snapshot) {
                runtime.hasAutoApprovalPolicy(for: tool)
            }
            XCTAssertEqual(eligible, expected, "\(name): \(capabilityPolicy), global=\(globalEnabled)")
        }
    }

    func testSiteMemoryAutoApprovalHonorsDisabledPolicyAndValidatesWholeBatch() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        let capability = try XCTUnwrap(IOSCapabilityRegistry.capability(forToolName: "wm_site_memory"))
        let highRisk = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:], globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: true, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        let valid = #"{"host":"github.com","action":"propose","changes":[{"operation":"add","kind":"pitfalls","name":"一","detail":"说明"}]}"#
        let disabled = IOSExecutionPolicySnapshot(
            capabilityPolicies: [capability.id: IOSAgentPermissionPolicy.disabled.rawValue], globalAutoApproveEnabled: true,
            highRiskAutoApproveEnabled: true, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        guard case .denied = await executor.execute(executor.executionRequest(
            toolName: "wm_site_memory", operation: valid, isUserInitiated: false, executionPolicy: disabled
        )) else { return XCTFail("Disabled policy must still block high-risk auto-approval") }
        let invalid = #"{"host":"github.com","action":"propose","changes":[{"operation":"add","kind":"pitfalls","name":"一","detail":"说明"},{"kind":"pitfalls","name":"缺操作","detail":"无效"}]}"#
        let result = await executor.execute(executor.executionRequest(
            toolName: "wm_site_memory", operation: invalid, isUserInitiated: false, executionPolicy: highRisk
        ))
        guard case .webMountResult(let output) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try jsonObject(output)["error_code"] as? String, "invalid_site_memory_proposal")
        XCTAssertTrue(controller.registry.siteMemory(host: "github.com").isEmpty,
                      "Invalid changes must never partially save a batch")
        let perCapability = IOSExecutionPolicySnapshot(
            capabilityPolicies: [capability.id: IOSAgentPermissionPolicy.autoApproveHighRisk.rawValue], globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: false, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        let approved = await executor.execute(executor.executionRequest(
            toolName: "wm_site_memory", operation: valid, isUserInitiated: false, executionPolicy: perCapability
        ))
        guard case .webMountResult(let saved) = approved else {
            return XCTFail("Capability high-risk policy must also apply: \(approved)")
        }
        XCTAssertEqual(try jsonObject(saved)["ok"] as? Bool, true)
    }

    func testSiteMemoryApprovalWriteNextOpenSanitizationAndDeletion() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        controller.registry.setEnabled(id: "github", enabled: true)
        let executor = makeExecutor(webMountController: controller)
        let proposal = IOSWebMountController.json([
            "host": "github.com", "action": "propose",
            "changes": [[
                "operation": "add", "kind": "pages", "name": "订单页",
                "detail": "联系 alice@example.com，手机 13800138000、备用号 138 0013 8000 和 138-0013-8000，订单号 ABC123456789，版本 1.2?价格 19.9",
                "url_pattern": "https://github.com/orders/ABC123456789?token=private&page=2"
            ]]
        ])
        let policy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:], globalAutoApproveEnabled: true,
            highRiskAutoApproveEnabled: false, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        let pending = await executor.execute(executor.executionRequest(
            toolName: "wm_site_memory", operation: proposal, isUserInitiated: false,
            executionPolicy: policy
        ))
        guard case .needsUserAction = pending else { return XCTFail("Proposal must require the approval card") }
        XCTAssertTrue(controller.registry.siteMemory(host: "github.com").isEmpty)
        let preview = try XCTUnwrap(executor.webMountApprovalPreview(toolName: "wm_site_memory", input: proposal))
        XCTAssertEqual(preview.siteMemoryChanges?.count, 1)
        XCTAssertFalse((preview.siteMemoryChanges ?? []).joined().contains("alice@example.com"))
        let approved = await executor.execute(executor.executionRequest(
            toolName: "wm_site_memory", operation: proposal, isUserInitiated: true,
            executionPolicy: policy
        ))
        guard case .webMountResult(let written) = approved else { return XCTFail("Approved proposal was not executed") }
        XCTAssertEqual(try jsonObject(written)["ok"] as? Bool, true)
        let entry = try XCTUnwrap(controller.registry.siteMemory(host: "github.com").first)
        XCTAssertEqual(entry.source, .agent)
        XCTAssertEqual(entry.urlPattern, "https://github.com/orders/[订单号已隐去]")
        XCTAssertFalse(entry.detail.contains("alice@example.com"))
        XCTAssertFalse(entry.detail.contains("13800138000"))
        XCTAssertFalse(entry.detail.contains("138 0013 8000"))
        XCTAssertFalse(entry.detail.contains("138-0013-8000"))
        XCTAssertFalse(entry.detail.contains("ABC123456789"))
        XCTAssertTrue(entry.detail.contains("版本 1.2?价格 19.9"))
        let longEntries = (0..<5).map { index in
            IOSWebMountSiteMemoryEntry(
                id: "budget-\(index)", kind: .pages,
                name: String(repeating: "N", count: 80),
                detail: String(repeating: "D", count: 500),
                urlPattern: "https://github.com/" + String(repeating: "x", count: 280),
                locatorJSON: nil, updatedAtMillis: 1, source: .user
            )
        }
        controller.registry.replaceSiteMemory(host: "github.com", entries: [entry] + longEntries)
        let opened = try jsonObject(await controller.execute(
            toolName: "wm_open", input: #"{"site_id":"github"}"#, isUserInitiated: true
        ))
        let memory = try XCTUnwrap(opened["site_memory"] as? [String: Any])
        XCTAssertEqual(memory["untrusted_site_memory"] as? Bool, true)
        XCTAssertEqual((memory["entries"] as? [[String: Any]])?.first?["id"] as? String, entry.id)
        let summaryBudget = try XCTUnwrap(memory["summary_budget_chars"] as? Int)
        XCTAssertLessThanOrEqual(IOSWebMountController.json(memory).count, summaryBudget)
        XCTAssertTrue(controller.registry.deleteSiteMemoryEntry(host: "github.com", id: entry.id))
        XCTAssertFalse(controller.registry.siteMemory(host: "github.com").contains { $0.id == entry.id })
        controller.registry.replaceSiteMemory(host: "github.com", entries: [entry])
        controller.registry.clearSiteMemory(host: "github.com")
        XCTAssertTrue(controller.registry.siteMemory(host: "github.com").isEmpty)
    }

    func testSiteMemoryForWWWHostIsIncludedOnFirstOpen() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        controller.registry.setEnabled(id: "github", enabled: true)
        let entry = IOSWebMountSiteMemoryEntry(
            id: "github-memory", kind: .pages, name: "项目页", detail: "从项目菜单进入",
            urlPattern: nil, locatorJSON: nil, updatedAtMillis: 1, source: .user
        )
        controller.registry.replaceSiteMemory(host: "github.com", entries: [entry])

        let opened = try jsonObject(await controller.execute(
            toolName: "wm_open",
            input: #"{"site_id":"github","url":"https://www.github.com/login"}"#,
            isUserInitiated: true
        ))

        let memory = try XCTUnwrap(opened["site_memory"] as? [String: Any], IOSWebMountController.json(opened))
        XCTAssertEqual(memory["host"] as? String, "github.com")
        XCTAssertEqual((memory["entries"] as? [[String: Any]])?.first?["id"] as? String, entry.id)
        XCTAssertEqual(memory["untrusted_site_memory"] as? Bool, true)
    }

    func testRemovingAndReaddingSameHostDoesNotExposePriorSiteMemory() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let host = "site-memory-revisit.example"
        let siteId = "user_memory_revisit"
        let proposal = IOSWebMountController.json([
            "host": host, "action": "propose",
            "changes": [["operation": "add", "kind": "pitfalls", "name": "提示", "detail": "检查页面"]]
        ])
        let originalSite = IOSWebMountSite(
            id: siteId, displayName: "Memory Revisit", homepageURL: "https://\(host)/",
            authKind: .anonymous, loginCookieName: nil, nativeAdapterId: nil, iconKey: nil,
            oauthProviderId: nil, allowedHosts: [host], enabled: true, addedAtMillis: 1
        )
        XCTAssertTrue(controller.registry.add(originalSite))
        controller.settings.syncAllowedHosts(controller.registry.sites.flatMap(\.allowedHosts))
        let originalBaseline = try XCTUnwrap(controller.siteMemoryApprovalBaseline(input: proposal))
        let entry = IOSWebMountSiteMemoryEntry(
            id: "old-memory", kind: .pitfalls, name: "旧页面提示", detail: "不要复用旧页面状态",
            urlPattern: nil, locatorJSON: nil, updatedAtMillis: 1, source: .user
        )
        controller.registry.replaceSiteMemory(host: host, entries: [entry])

        let removed = try jsonObject(await controller.execute(
            toolName: "wm_site_remove",
            input: IOSWebMountController.json(["site_id": siteId]),
            isUserInitiated: true
        ))
        XCTAssertEqual(removed["removed"] as? Bool, true)
        XCTAssertTrue(controller.registry.siteMemory(host: host).isEmpty)

        let replacementSite = IOSWebMountSite(
            id: siteId, displayName: "Memory Revisit", homepageURL: "https://\(host)/",
            authKind: .anonymous, loginCookieName: nil, nativeAdapterId: nil, iconKey: nil,
            oauthProviderId: nil, allowedHosts: [host], enabled: true, addedAtMillis: 2
        )
        XCTAssertTrue(controller.registry.add(replacementSite))
        controller.settings.syncAllowedHosts(controller.registry.sites.flatMap(\.allowedHosts))
        let replacementBaseline = try XCTUnwrap(controller.siteMemoryApprovalBaseline(input: proposal))
        XCTAssertNotEqual(replacementBaseline, originalBaseline)
        let opened = try jsonObject(await controller.execute(
            toolName: "wm_open",
            input: IOSWebMountController.json(["site_id": siteId]),
            isUserInitiated: true
        ))
        XCTAssertNil(opened["site_memory"])
    }

    func testSiteMemoryHostLimitRejectsProposal() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let entries = (0..<IOSWebMountRegistry.maximumMemoryEntriesPerHost).map { index in
            IOSWebMountSiteMemoryEntry(id: "entry-\(index)", kind: .pitfalls, name: "Item \(index)",
                                       detail: "description", urlPattern: nil, locatorJSON: nil,
                                       updatedAtMillis: 1, source: .user)
        }
        controller.registry.replaceSiteMemory(host: "github.com", entries: entries)
        let result = try jsonObject(await controller.execute(
            toolName: "wm_site_memory",
            input: #"{"host":"github.com","action":"propose","changes":[{"operation":"add","kind":"pitfalls","name":"extra","detail":"extra"}]}"#,
            isUserInitiated: true
        ))
        XCTAssertEqual(result["error_code"] as? String, "invalid_site_memory_proposal")
        XCTAssertEqual(controller.registry.siteMemory(host: "github.com").count, 40)
    }

    func testSiteMemoryActionLocatorSurvivesLocalRead() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let locator: [String: Any] = [
            "role": "button", "tag": "button", "name": "筛选",
            "url_pattern": "https://github.com/issues?view=all",
            "attributes": ["data-testid": "filter-button", "alice@example.com": "private"]
        ]
        let proposal = IOSWebMountController.json([
            "host": "github.com", "action": "propose",
            "changes": [["operation": "add", "kind": "actions", "name": "筛选",
                         "detail": "用当前 ref 打开筛选", "locator": locator]]
        ])
        let written = try jsonObject(await controller.execute(
            toolName: "wm_site_memory", input: proposal, isUserInitiated: true
        ))
        XCTAssertEqual(written["ok"] as? Bool, true)
        let read = try jsonObject(await controller.execute(
            toolName: "wm_site_memory", input: #"{"host":"github.com","action":"read"}"#,
            isUserInitiated: true
        ))
        let entry = try XCTUnwrap((read["entries"] as? [[String: Any]])?.first)
        let savedLocator = try XCTUnwrap(entry["locator"] as? [String: Any])
        XCTAssertEqual(savedLocator["role"] as? String, "button")
        XCTAssertEqual(savedLocator["url_pattern"] as? String, "https://github.com/issues")
        XCTAssertEqual((savedLocator["attributes"] as? [String: Any])?["data-testid"] as? String, "filter-button")
        XCTAssertFalse(try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: savedLocator), encoding: .utf8)).contains("alice@example.com"))
    }

    func testSiteMemoryDeletionAndClearPersist() {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let entry = IOSWebMountSiteMemoryEntry(id: "remembered", kind: .pitfalls,
                                               name: "旧页面", detail: "先观察实际页面",
                                               urlPattern: nil, locatorJSON: nil,
                                               updatedAtMillis: 1, source: .user)
        registry.replaceSiteMemory(host: "github.com", entries: [entry])
        XCTAssertEqual(IOSWebMountRegistry(userDefaults: defaults).siteMemory(host: "github.com"), [entry])
        XCTAssertTrue(registry.deleteSiteMemoryEntry(host: "github.com", id: entry.id))
        XCTAssertTrue(IOSWebMountRegistry(userDefaults: defaults).siteMemory(host: "github.com").isEmpty)
        registry.replaceSiteMemory(host: "github.com", entries: [entry])
        registry.clearSiteMemory(host: "github.com")
        XCTAssertTrue(IOSWebMountRegistry(userDefaults: defaults).siteMemory(host: "github.com").isEmpty)
    }

}
