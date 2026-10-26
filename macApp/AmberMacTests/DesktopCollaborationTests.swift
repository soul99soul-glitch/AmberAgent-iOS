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
        let id = try runtime.startCouncil(parentConversationID: owner, objective: "Council topic", seats: members(2))
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
        let id = try runtime.startCouncil(parentConversationID: UUID(), objective: "Council", seats: members(2))
        await waitForCalls(2, provider: provider)
        provider.calls[0].generation.yield(.snapshot(text: "Verified seat result", reasoning: "")); provider.calls[0].generation.yield(.complete)
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
}
