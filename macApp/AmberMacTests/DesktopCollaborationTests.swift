import XCTest
@testable import AmberMac

@MainActor final class DesktopCollaborationTests: XCTestCase {
    private final class Notifications: DesktopNotificationDelivery {
        var sent: [[String: String]] = []
        func requestAuthorization() async throws -> Bool { true }
        func isAuthorized() async -> Bool { true }
        func send(identifier: String, title: String, body: String, userInfo: [String: String]) async throws { sent.append(userInfo) }
    }
    private final class Provider: DesktopTextProvider {
        struct Call {
            let configuration: DesktopProviderConfiguration
            let apiKey: String
            let messages: [DesktopMessage]
            let responseID: UUID
            let generation: DesktopGeneration
        }
        var calls: [Call] = []
        var automatic = false
        func userMessage(id: UUID, text: String, attachments: [DesktopMessageAttachment]) throws -> DesktopMessage {
            DesktopMessage(id: id, role: .user, text: text)
        }
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let generation = DesktopGeneration()
            calls.append(Call(configuration: configuration, apiKey: apiKey, messages: messages, responseID: responseID, generation: generation))
            if automatic {
                generation.yield(.snapshot(text: "Output \(calls.count)", reasoning: "private reasoning"))
                generation.yield(.complete)
            }
            return generation
        }
    }
    private func settings() throws -> DesktopSettings {
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.collaboration.tests.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        let provider = DesktopProviderConfiguration(name: "Test", kind: .responses, baseURL: "https://example.com/v1", models: [DesktopModelConfiguration(modelID: "one", name: "First"), DesktopModelConfiguration(modelID: "two", name: "Second")])
        try settings.saveProvider(provider, apiKey: "test-key")
        settings.selectModel(provider.models[0].id)
        return settings
    }
    private func members(_ count: Int, modelID: UUID? = nil) -> [DesktopCollaborationMember] {
        (0..<count).map { DesktopCollaborationMember(name: "Member \($0)", rolePrompt: "Role \($0)", modelID: modelID) }
    }
    private func waitForCalls(_ count: Int, provider: Provider) async {
        for _ in 0..<200 {
            if provider.calls.count >= count { break }
            await Task.yield()
        }
        XCTAssertEqual(provider.calls.count, count)
    }

    func testSubagentsUseFrozenSelectedModelsAndReturnToOriginalParent() async throws {
        let settings = try settings(), provider = Provider()
        let model = try XCTUnwrap(settings.selectedProvider?.models.last)
        let owner = UUID(), runtime = DesktopCollaborations(settings: settings, provider: provider)
        let id = try runtime.startSubagents(parentConversationID: owner, objective: "Task", members: members(1, modelID: model.id))
        await waitForCalls(1, provider: provider)
        settings.selectModel(try XCTUnwrap(settings.selectedProvider?.models.first?.id))
        XCTAssertEqual(provider.calls[0].configuration.selectedModel?.id, model.id)
        XCTAssertEqual(provider.calls[0].apiKey, "test-key")
        XCTAssertEqual(provider.calls[0].messages.map(\.role), [.system, .user])
        provider.calls[0].generation.yield(.snapshot(text: "Final public output", reasoning: "private"))
        provider.calls[0].generation.yield(.complete)
        let resultFinished = await runtime.waitUntilFinished(id)
        let result = try XCTUnwrap(resultFinished)
        XCTAssertEqual(result.parentConversationID, owner)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.outputs[0].text, "Final public output")
        XCTAssertFalse(result.finalText.contains("private"))
    }

    func testGlobalConcurrencyAndCancellationDoNotMixReusedMemberIDsAcrossParents() async throws {
        let settings = try settings(), provider = Provider()
        let runtime = DesktopCollaborations(settings: settings, provider: provider, maxConcurrent: 2)
        let sharedMembers = members(3), owner1 = UUID(), owner2 = UUID()
        let firstID = try runtime.startSubagents(parentConversationID: owner1, objective: "First", members: sharedMembers)
        await waitForCalls(2, provider: provider)
        let secondID = try runtime.startSubagents(parentConversationID: owner2, objective: "Second", members: sharedMembers)
        await Task.yield()
        runtime.cancel(firstID)
        let firstFinished = await runtime.waitUntilFinished(firstID)
        let first = try XCTUnwrap(firstFinished)
        XCTAssertEqual(first.status, .cancelled)
        XCTAssertTrue(first.outputs.allSatisfy { $0.status == .cancelled })
        await waitForCalls(4, provider: provider)
        for call in provider.calls.suffix(2) {
            call.generation.yield(.snapshot(text: "Second parent output", reasoning: "")); call.generation.yield(.complete)
        }
        await waitForCalls(5, provider: provider)
        provider.calls[4].generation.yield(.snapshot(text: "Last second parent output", reasoning: ""))
        provider.calls[4].generation.yield(.complete)
        let secondFinished = await runtime.waitUntilFinished(secondID)
        let second = try XCTUnwrap(secondFinished)
        XCTAssertEqual(second.parentConversationID, owner2)
        XCTAssertEqual(second.status, .completed)
        XCTAssertTrue(second.outputs.allSatisfy { $0.text.contains("second parent") || $0.text.contains("Second parent") })
        XCTAssertEqual(Set(provider.calls.map(\.responseID)).count, provider.calls.count)
    }

    func testTimeoutPreservesPartialOutputAndCancelsGeneration() async throws {
        let settings = try settings(), provider = Provider()
        let runtime = DesktopCollaborations(settings: settings, provider: provider)
        let id = try runtime.startSubagents(parentConversationID: UUID(), objective: "Timeout", members: members(1), timeoutSeconds: 1)
        await waitForCalls(1, provider: provider)
        provider.calls[0].generation.yield(.snapshot(text: "Partial text", reasoning: ""))
        let resultFinished = await runtime.waitUntilFinished(id)
        let result = try XCTUnwrap(resultFinished)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.outputs[0].status, .timedOut)
        XCTAssertEqual(result.outputs[0].text, "Partial text")
        XCTAssertTrue(result.finalText.isEmpty)
        provider.calls[0].generation.yield(.snapshot(text: "Late output", reasoning: ""))
        XCTAssertEqual(runtime.runs.first(where: { $0.id == id })?.outputs[0].text, "Partial text")
    }

    func testCouncilRunsSeatsThenSynthesizesTheirActualOutputs() async throws {
        let settings = try settings(), provider = Provider()
        provider.automatic = true
        let runtime = DesktopCollaborations(settings: settings, provider: provider)
        let owner = UUID()
        let id = try runtime.startCouncil(parentConversationID: owner, objective: "Council topic", seats: members(2), rounds: 1)
        let resultFinished = await runtime.waitUntilFinished(id)
        let result = try XCTUnwrap(resultFinished)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.parentConversationID, owner)
        XCTAssertEqual(result.outputs.count, 3)
        XCTAssertEqual(result.outputs.last?.name, "综合")
        XCTAssertEqual(result.finalText, "Output 3")
        XCTAssertTrue(provider.calls[2].messages.last?.text.contains("Output 1") ?? false)
        XCTAssertTrue(provider.calls[2].messages.last?.text.contains("Output 2") ?? false)
        XCTAssertFalse(provider.calls[2].messages.last?.text.contains("private reasoning") ?? true)
    }

    func testSeatFailureCanProduceMarkedPartialCouncilButNeverFalseSuccess() async throws {
        let settings = try settings(), provider = Provider()
        let runtime = DesktopCollaborations(settings: settings, provider: provider)
        let id = try runtime.startCouncil(parentConversationID: UUID(), objective: "Council", seats: members(2), rounds: 1)
        await waitForCalls(1, provider: provider)
        provider.calls[0].generation.yield(.snapshot(text: "Verified seat result", reasoning: "")); provider.calls[0].generation.yield(.complete)
        await waitForCalls(2, provider: provider)
        provider.calls[1].generation.yield(.failed("raw body with secret"))
        await waitForCalls(3, provider: provider)
        XCTAssertFalse(provider.calls[2].messages.last?.text.contains("secret") ?? true)
        provider.calls[2].generation.yield(.snapshot(text: "Partial synthesis", reasoning: "")); provider.calls[2].generation.yield(.complete)
        let resultFinished = await runtime.waitUntilFinished(id)
        let result = try XCTUnwrap(resultFinished)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.outputs.filter { $0.status == .failed }.count, 1)
        XCTAssertEqual(result.finalText, "Partial synthesis")
    }

    func testUnknownOrDisabledModelFailsBeforeStartingAnyChild() throws {
        let provider = Provider(), runtime = DesktopCollaborations(settings: try settings(), provider: provider)
        XCTAssertThrowsError(try runtime.startSubagents(parentConversationID: UUID(), objective: "Task", members: members(1, modelID: UUID())))
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertTrue(runtime.runs.isEmpty)
    }

    func testCompletedRunRestoresOwnerAndOutputWithoutReplayingProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber.collaboration.persist.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try settings(), provider = Provider()
        provider.automatic = true
        let runtime = DesktopCollaborations(settings: settings, provider: provider, directory: directory)
        await runtime.waitUntilLoaded()
        let owner = UUID()
        let id = try runtime.startSubagents(parentConversationID: owner, objective: "Persist", members: members(1))
        _ = await runtime.waitUntilFinished(id)
        let saved = await runtime.flush()
        XCTAssertTrue(saved)
        let nextProvider = Provider()
        let restored = DesktopCollaborations(settings: settings, provider: nextProvider, directory: directory)
        await restored.waitUntilLoaded()
        let record = try XCTUnwrap(restored.runs.first(where: { $0.id == id }))
        XCTAssertEqual(record.parentConversationID, owner)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.outputs[0].text, "Output 1")
        XCTAssertTrue(nextProvider.calls.isEmpty)
        XCTAssertNil(restored.loadError)
    }

    func testInterruptedRunRestoresAsCancelledPreservingPartialAndOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber.collaboration.recovery.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = UUID(), member = UUID()
        var output = DesktopCollaborationOutput(id: member, name: "Interrupted", modelName: "First")
        output.status = .running; output.text = "Saved partial"
        let original = DesktopCollaborationRun(id: UUID(), parentConversationID: owner, objective: "Interrupted", isCouncil: false, createdAt: Date(), outputs: [output])
        try JSONEncoder().encode([original]).write(to: directory.appendingPathComponent("runs.json"))
        let provider = Provider()
        let restored = DesktopCollaborations(settings: try settings(), provider: provider, directory: directory)
        await restored.waitUntilLoaded()
        let record = try XCTUnwrap(restored.runs.first)
        XCTAssertEqual(record.id, original.id)
        XCTAssertEqual(record.parentConversationID, owner)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.outputs[0].status, .cancelled)
        XCTAssertEqual(record.outputs[0].text, "Saved partial")
        XCTAssertNotNil(record.error)
        XCTAssertTrue(provider.calls.isEmpty)
        let persisted = try JSONDecoder().decode([DesktopCollaborationRun].self, from: Data(contentsOf: directory.appendingPathComponent("runs.json")))
        XCTAssertEqual(persisted.first?.status, .cancelled)
    }

    func testUnreadableHistoryIsPreservedAndBlocksUnrecordedRuns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber.collaboration.corrupt.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let badData = Data("broken history".utf8), file = directory.appendingPathComponent("runs.json")
        try badData.write(to: file)
        let provider = Provider()
        let runtime = DesktopCollaborations(settings: try settings(), provider: provider, directory: directory)
        await runtime.waitUntilLoaded()
        XCTAssertNotNil(runtime.loadError)
        XCTAssertThrowsError(try runtime.startSubagents(parentConversationID: UUID(), objective: "Must not dispatch", members: members(1)))
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), badData)
        let saved = await runtime.flush()
        XCTAssertFalse(saved)
    }

    func testFailedStartPersistenceDoesNotReachProvider() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber.collaboration.notdirectory.\(UUID())")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("not a directory".utf8).write(to: path)
        let provider = Provider()
        let runtime = DesktopCollaborations(settings: try settings(), provider: provider, directory: path)
        await runtime.waitUntilLoaded()
        let id = try runtime.startSubagents(parentConversationID: UUID(), objective: "Must not dispatch", members: members(1))
        let finished = await runtime.waitUntilFinished(id)
        XCTAssertEqual(finished?.status, .failed)
        XCTAssertNotNil(runtime.persistenceError)
        XCTAssertTrue(provider.calls.isEmpty)
    }

    func testCouncilNotifiesOnlyOnceForDurableParentRun() async throws {
        let settings = try settings(), provider = Provider(), delivery = Notifications()
        settings.notificationsEnabled = true; provider.automatic = true
        let notifications = DesktopNotifications(settings: settings, delivery: delivery)
        let runtime = DesktopCollaborations(settings: settings, provider: provider, notifications: notifications)
        let owner = UUID()
        let id = try runtime.startCouncil(parentConversationID: owner, objective: "Council", seats: members(2))
        _ = await runtime.waitUntilFinished(id)
        XCTAssertEqual(delivery.sent.count, 1)
        XCTAssertEqual(delivery.sent[0]["runID"], id.uuidString.lowercased())
        XCTAssertEqual(delivery.sent[0]["conversationID"], owner.uuidString.lowercased())
        XCTAssertEqual(delivery.sent[0]["outcome"], "completed")
    }

    func testCancelledCollaborationDoesNotSendCompletionNotification() async throws {
        let settings = try settings(), provider = Provider(), delivery = Notifications()
        settings.notificationsEnabled = true
        let runtime = DesktopCollaborations(settings: settings, provider: provider,
            notifications: DesktopNotifications(settings: settings, delivery: delivery))
        let id = try runtime.startSubagents(parentConversationID: UUID(), objective: "Cancelled", members: members(1))
        await waitForCalls(1, provider: provider)
        runtime.cancel(id)
        _ = await runtime.waitUntilFinished(id)
        XCTAssertTrue(delivery.sent.isEmpty)
    }

    func testCouncilRoundsSpeakSequentiallyWithHostCommentaryBetweenRounds() async throws {
        let settings = try settings(), provider = Provider()
        provider.automatic = true
        let runtime = DesktopCollaborations(settings: settings, provider: provider)
        let id = try runtime.startCouncil(parentConversationID: UUID(), objective: "Topic", seats: members(2), rounds: 3)
        let finished = await runtime.waitUntilFinished(id)
        let result = try XCTUnwrap(finished)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.rounds, 3)
        XCTAssertEqual(result.outputs.map(\.name), [
            "Member 0 · 第1轮", "Member 1 · 第1轮", "主持人 · 第1轮点评",
            "Member 0 · 第2轮", "Member 1 · 第2轮", "主持人 · 第2轮点评",
            "Member 0 · 第3轮", "Member 1 · 第3轮", "综合"])
        // The second seat sees the first seat's same-round output; round 2 sees the host commentary.
        XCTAssertTrue(provider.calls[1].messages.last?.text.contains("Output 1") ?? false)
        XCTAssertTrue(provider.calls[3].messages.last?.text.contains("[主持人 · 第1轮点评] Output 3") ?? false)
        XCTAssertEqual(result.finalText, "Output 9")
    }

    func testDebateModeChangesSeatPromptWording() {
        let debate = DesktopCollaborations.seatPrompt(objective: "T", mode: .debate, round: 1, rounds: 2, transcript: [])
        let free = DesktopCollaborations.seatPrompt(objective: "T", mode: .freeChat, round: 1, rounds: 2, transcript: [])
        XCTAssertTrue(debate.contains("模式：辩论"))
        XCTAssertTrue(debate.contains("回应前文的核心判断"))
        XCTAssertTrue(free.contains("补充前文没有覆盖的新角度"))
        XCTAssertFalse(free.contains("回应前文的核心判断"))
    }

    func testOldRunsDecodeWithDefaultModeRoundsAndSteps() throws {
        let json = #"[{"id":"\#(UUID())","parentConversationID":"\#(UUID())","objective":"Old","isCouncil":true,"createdAt":0,"outputs":[{"id":"\#(UUID())","name":"A","modelName":"M","text":"t","status":"completed"}],"finalText":"","status":"completed"}]"#
        let run = try XCTUnwrap(JSONDecoder().decode([DesktopCollaborationRun].self, from: Data(json.utf8)).first)
        XCTAssertEqual(run.mode, .freeChat)
        XCTAssertEqual(run.rounds, 1)
        XCTAssertEqual(run.outputs[0].steps, [])
    }

    func testPlannedSeatsSkipDistractorObjectsAndResolveNamedModels() throws {
        let settings = try settings(), models = settings.modelSelections, host = UUID()
        let text = #"先列举 {历史, 政治}。{"seats":[{"name":"史官","rolePrompt":"看历史 {先例}"},{"name":"史官","rolePrompt":"重复"},{"name":"策士","lens":"看策略","model":"Second"}]}"#
        let seats = DesktopCollaborations.plannedSeats(from: text, models: models, hostModelID: host)
        XCTAssertEqual(seats.map(\.name), ["史官", "策士"])
        XCTAssertEqual(seats[0].rolePrompt, "看历史 {先例}")
        XCTAssertEqual(seats[0].modelID, host)
        XCTAssertEqual(seats[1].modelID, models.first { $0.modelName == "Second" }?.id)
        XCTAssertTrue(DesktopCollaborations.plannedSeats(from: #"{"seats":[{"name":"独"}]}"#, models: models, hostModelID: host).isEmpty)
    }

    func testEmptyCouncilSeatsAreHostPlanned() async throws {
        let settings = try settings(), provider = Provider()
        let runtime = DesktopCollaborations(settings: settings, provider: provider)
        let id = try runtime.startCouncil(parentConversationID: UUID(), objective: "Plan", seats: [], rounds: 1)
        await waitForCalls(1, provider: provider)
        XCTAssertTrue(provider.calls[0].messages.last?.text.contains("\"seats\"") ?? false)
        provider.calls[0].generation.yield(.snapshot(text: #"{"seats":[{"name":"甲","rolePrompt":"一"},{"name":"乙","rolePrompt":"二"}]}"#, reasoning: ""))
        provider.calls[0].generation.yield(.complete)
        provider.automatic = true
        let finished = await runtime.waitUntilFinished(id)
        let result = try XCTUnwrap(finished)
        XCTAssertEqual(result.outputs.map(\.name), ["主持人 · 规划席位", "甲 · 第1轮", "乙 · 第1轮", "综合"])
        XCTAssertEqual(result.status, .completed)
    }

    func testSubagentToolPolicyIsReadOnlyAndRoleScoped() {
        let explorer = DesktopCollaborationRole.builtIns.first { $0.id == "explorer" }
        XCTAssertEqual(Set(DesktopSubagentToolPolicy.toolNames(for: explorer)), ["search_web", "scrape_web", "workspace_file_read", "workspace_file_list"])
        XCTAssertEqual(DesktopSubagentToolPolicy.toolNames(for: DesktopCollaborationRole.builtIns.first { $0.id == "fixer" }), [])
        let rogue = DesktopCollaborationRole(id: "x", name: "X", prompt: "p",
            toolAllowlist: ["workspace_file_write", "terminal_exec", "mcp_call_tool", "memory_tool", "subagent_dispatch", "workspace_file_read"], maxTurns: 2)
        XCTAssertEqual(DesktopSubagentToolPolicy.toolNames(for: rogue), ["workspace_file_read"])
        for name in DesktopSubagentToolPolicy.toolNames(for: nil) {
            XCTAssertEqual(DesktopToolRegistry.effect(for: name, arguments: "{}") == .sideEffect, false, name)
        }
    }

    func testSubagentReportArgumentsBecomeOutputText() {
        XCTAssertEqual(DesktopSubagentToolPolicy.reportText(arguments: #"{"summary":" 结论 ","findings":"证据"}"#), "结论\n\n证据")
        XCTAssertNil(DesktopSubagentToolPolicy.reportText(arguments: #"{"summary":"  "}"#))
        XCTAssertNil(DesktopSubagentToolPolicy.reportText(arguments: "not json"))
    }

    func testSubagentsUseInjectedToolRunnerWithRoleScopeAndRecordSteps() async throws {
        let settings = try settings(), provider = Provider()
        let runtime = DesktopCollaborations(settings: settings, provider: provider)
        var requests: [DesktopCollaborationToolRequest] = []
        runtime.toolRunner = { request, onSteps in
            requests.append(request)
            onSteps([.init(tool: "search_web", arguments: #"{"query":"q"}"#, result: "hits"), .init(text: "done")])
            let generation = DesktopGeneration()
            generation.yield(.snapshot(text: "Reported summary", reasoning: ""))
            generation.yield(.complete)
            return generation
        }
        let owner = UUID()
        let member = DesktopCollaborationMember(name: "Explorer", rolePrompt: "scout", roleID: "explorer", skillNames: ["notes"])
        let id = try runtime.startSubagents(parentConversationID: owner, objective: "Find", members: [member])
        let finished = await runtime.waitUntilFinished(id)
        let result = try XCTUnwrap(finished)
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].ownerID, owner)
        XCTAssertEqual(requests[0].maxSteps, 5)
        XCTAssertEqual(requests[0].skillNames, ["notes"])
        XCTAssertTrue(requests[0].systemPrompt.contains("subagent_report"))
        XCTAssertFalse(requests[0].toolNames.contains("workspace_file_write"))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.outputs[0].text, "Reported summary")
        XCTAssertEqual(result.outputs[0].steps.map(\.tool), ["search_web", nil])
    }
}
