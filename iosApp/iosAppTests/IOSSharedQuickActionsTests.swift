import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSSharedQuickActionsTests: XCTestCase {
    func testCreateEditDeletePersistIdentityOrderAndUnrelatedSettings() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        fixture.store.setEnableWebSearch(false)
        let unrelated = try fixture.settingsExcludingQuickMessages()
        let baselineIDs = fixture.store.snapshot.quickMessages.map { $0.id.toHexDashString() }

        let first = try fixture.store.saveQuickAction(title: "  查天气  ", prompt: "  查询今天的天气\n")
        let second = try fixture.store.saveQuickAction(title: "出行", prompt: "规划出行路线")
        let edited = try fixture.store.saveQuickAction(
            id: first.id.uppercased(), title: "天气预报", prompt: "查询明天的天气"
        )
        XCTAssertNotNil(UUID(uuidString: first.id))
        XCTAssertEqual(edited.id, first.id)
        XCTAssertEqual(first.title, "查天气")
        XCTAssertEqual(first.prompt, "查询今天的天气")
        XCTAssertEqual(
            fixture.store.snapshot.quickMessages.map { $0.id.toHexDashString() },
            baselineIDs + [first.id, second.id]
        )
        XCTAssertEqual(try fixture.settingsExcludingQuickMessages(), unrelated)

        let reloaded = fixture.reload()
        XCTAssertEqual(Array(reloaded.savedQuickActions().suffix(2)), [edited, second])
        XCTAssertFalse(reloaded.snapshot.enableWebSearch)
        try reloaded.deleteQuickAction(id: first.id.uppercased())
        let afterDelete = fixture.reload()
        XCTAssertEqual(afterDelete.snapshot.quickMessages.map { $0.id.toHexDashString() }, baselineIDs + [second.id])
        XCTAssertFalse(afterDelete.snapshot.enableWebSearch)
        assertQuickActionError(.missingAction) { try afterDelete.resolvedQuickActionPrompt(id: first.id, input: nil) }
        assertQuickActionError(.missingAction) { try afterDelete.saveQuickAction(id: first.id, title: "复活", prompt: "旧任务") }
        assertQuickActionError(.missingAction) { try afterDelete.deleteQuickAction(id: first.id) }
    }

    func testValidationRejectsInvalidTasksWithoutChangingRevisionOrPersistence() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let revision = fixture.store.revision
        let persisted = fixture.persistedJSON
        assertQuickActionError(.emptyTitle) { try fixture.store.saveQuickAction(title: "\n ", prompt: "任务") }
        assertQuickActionError(.titleTooLong) { try fixture.store.saveQuickAction(title: String(repeating: "字", count: 41), prompt: "任务") }
        assertQuickActionError(.emptyPrompt) { try fixture.store.saveQuickAction(title: "任务", prompt: "\n ") }
        assertQuickActionError(.promptTooLong) { try fixture.store.saveQuickAction(title: "任务", prompt: String(repeating: "字", count: 2001)) }
        assertQuickActionError(.unsupportedPrompt) { try fixture.store.saveQuickAction(title: "路由", prompt: " [ROUTE:image] \n") }
        assertQuickActionError(.missingAction) { try fixture.store.saveQuickAction(id: "not-a-current-id", title: "任务", prompt: "内容") }
        XCTAssertEqual(fixture.store.revision, revision)
        XCTAssertEqual(fixture.persistedJSON, persisted)

        let boundary = try fixture.store.saveQuickAction(title: String(repeating: "字", count: 40), prompt: String(repeating: "字", count: 2000))
        XCTAssertEqual(fixture.reload().savedQuickActions().last, boundary)
    }

    func testTemplateRequiresInputReplacesAllSpellingsAndLeavesStoredTemplateIntact() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let action = try fixture.store.saveQuickAction(title: "翻译", prompt: "翻译 {输入}；核对 {輸入}；解释 {input}")
        let revision = fixture.store.revision
        let persisted = fixture.persistedJSON
        assertQuickActionError(.missingInput) { try fixture.store.resolvedQuickActionPrompt(id: action.id, input: nil) }
        assertQuickActionError(.missingInput) { try fixture.store.resolvedQuickActionPrompt(id: action.id, input: "  \n") }
        XCTAssertEqual(
            try fixture.store.resolvedQuickActionPrompt(id: action.id, input: "  hello \n"),
            "翻译 hello；核对 hello；解释 hello"
        )
        XCTAssertEqual(fixture.store.savedQuickActions().last, action)
        XCTAssertEqual(fixture.reload().savedQuickActions().last, action)
        XCTAssertEqual(fixture.store.revision, revision)
        XCTAssertEqual(fixture.persistedJSON, persisted)
    }

    func testResolvedTemplateValidatesExpandedLengthRoutingAndRemainingPlaceholders() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let repeated = try fixture.store.saveQuickAction(title: "重复", prompt: "{input}{input}")
        assertQuickActionError(.promptTooLong) {
            try fixture.store.resolvedQuickActionPrompt(id: repeated.id, input: String(repeating: "字", count: 1001))
        }
        XCTAssertEqual(
            try fixture.store.resolvedQuickActionPrompt(id: repeated.id, input: String(repeating: "字", count: 1000)).count,
            2000
        )
        let inputOnly = try fixture.store.saveQuickAction(title: "输入", prompt: "{输入}")
        assertQuickActionError(.unsupportedPrompt) { try fixture.store.resolvedQuickActionPrompt(id: inputOnly.id, input: "[ROUTE:image]") }
        assertQuickActionError(.unresolvedInput) { try fixture.store.resolvedQuickActionPrompt(id: inputOnly.id, input: "处理 {input}") }
    }

    func testPlainPromptIgnoresOptionalInputAndDoesNotRequireIt() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let action = try fixture.store.saveQuickAction(title: "简报", prompt: "生成今日简报")
        XCTAssertEqual(try fixture.store.resolvedQuickActionPrompt(id: action.id, input: nil), action.prompt)
        XCTAssertEqual(try fixture.store.resolvedQuickActionPrompt(id: action.id, input: "其他输入"), action.prompt)
    }

    func testRestoredLegacyTaskWithBlankTitleKeepsDisplayAndExecutableIdentity() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let action = try fixture.store.saveQuickAction(title: "旧标题", prompt: "旧任务内容")
        let json = IosSettingsJsonBridge.shared.encode(settings: fixture.store.snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var messages = try XCTUnwrap(object["quickMessages"] as? [[String: Any]])
        let index = try XCTUnwrap(messages.firstIndex { $0["id"] as? String == action.id })
        messages[index]["title"] = "  \n"
        object["quickMessages"] = messages
        let data = try JSONSerialization.data(withJSONObject: object)
        let imported = try IosSettingsJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
        XCTAssertTrue(fixture.store.restoreSnapshot(imported))

        let reloaded = fixture.reload()
        let legacy = try XCTUnwrap(reloaded.savedQuickActions().first { $0.id == action.id })
        XCTAssertEqual(legacy.title, String(localized: "未命名快捷消息", table: "AppIntents"))
        XCTAssertEqual(try reloaded.resolvedQuickActionPrompt(id: action.id, input: nil), "旧任务内容")
        let entity = IOSSavedActionEntity(id: legacy.id, title: legacy.title)
        XCTAssertEqual(entity.id, action.id)
        XCTAssertEqual(entity.title, legacy.title)
        assertQuickActionError(.emptyTitle) { try reloaded.saveQuickAction(id: action.id, title: "", prompt: "编辑内容") }
    }

    func testFailedRestoreDoesNotReportSuccessChangeSnapshotOrAdvanceRevision() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        fixture.addCredentialProvider()
        let action = try fixture.store.saveQuickAction(title: "任务", prompt: "原始内容")
        let actions = fixture.store.savedQuickActions()
        let revision = fixture.store.revision
        let persisted = fixture.persistedJSON
        fixture.credentials.values.removeAll()
        fixture.credentials.rejectWrites = true

        for operation in [
            { _ = try fixture.store.saveQuickAction(title: "新任务", prompt: "新内容") },
            { _ = try fixture.store.saveQuickAction(id: action.id, title: "编辑", prompt: "修改内容") },
            { try fixture.store.deleteQuickAction(id: action.id) }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard let actionError = error as? IOSSharedQuickActionError,
                      case .persistenceFailed(let message) = actionError else {
                    return XCTFail("Expected persistence failure, got \(error)")
                }
                XCTAssertEqual(message, fixture.store.credentialPersistenceError)
            }
            XCTAssertEqual(fixture.store.savedQuickActions(), actions)
            XCTAssertEqual(fixture.store.revision, revision)
            XCTAssertEqual(fixture.persistedJSON, persisted)
        }

        fixture.credentials.rejectWrites = false
        let retry = try fixture.store.saveQuickAction(id: action.id, title: "编辑", prompt: "修改内容")
        XCTAssertEqual(fixture.reload().savedQuickActions().last, retry)
        XCTAssertNil(fixture.store.credentialPersistenceError)
        XCTAssertEqual(fixture.store.revision, revision + 1)
    }

    func testWatchFailureKeepsSelectedIDsAndReportsStorageError() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        fixture.addCredentialProvider()
        let action = try fixture.store.saveQuickAction(title: "任务", prompt: "原始内容")
        let companion = IOSWatchCompanionService(baseDirectory: fixture.root, defaults: fixture.defaults)
        companion.setSelectedQuickActionIDs([action.id])
        let revision = fixture.store.revision
        fixture.credentials.values.removeAll()
        fixture.credentials.rejectWrites = true

        XCTAssertNil(companion.saveQuickAction(id: action.id, title: "编辑", prompt: "修改内容", sharedSettings: fixture.store))
        XCTAssertFalse(companion.deleteQuickAction(id: action.id, sharedSettings: fixture.store))
        XCTAssertEqual(companion.selectedQuickActionIDs, [action.id])
        XCTAssertTrue(companion.hasConfiguredQuickActionSelection)
        XCTAssertNotNil(companion.storageError)
        XCTAssertEqual(fixture.store.revision, revision)
        let restartedCompanion = IOSWatchCompanionService(baseDirectory: fixture.root, defaults: fixture.defaults)
        XCTAssertEqual(restartedCompanion.selectedQuickActionIDs, [action.id])

        fixture.credentials.rejectWrites = false
        XCTAssertTrue(companion.deleteQuickAction(id: action.id, sharedSettings: fixture.store))
        XCTAssertTrue(companion.selectedQuickActionIDs.isEmpty)
        XCTAssertNil(companion.storageError)
        XCTAssertFalse(companion.deleteQuickAction(id: action.id, sharedSettings: fixture.store))
        XCTAssertNil(companion.saveQuickAction(id: action.id, title: "复活", prompt: "旧内容", sharedSettings: fixture.store))
        XCTAssertFalse(fixture.store.savedQuickActions().contains { $0.id == action.id })
    }

    func testWatchDefaultSelectionRemainsUnconfiguredWhenDeleteFails() throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        fixture.addCredentialProvider()
        let action = try fixture.store.saveQuickAction(title: "任务", prompt: "原始内容")
        let companion = IOSWatchCompanionService(baseDirectory: fixture.root, defaults: fixture.defaults)
        fixture.credentials.values.removeAll()
        fixture.credentials.rejectWrites = true
        XCTAssertFalse(companion.deleteQuickAction(id: action.id, sharedSettings: fixture.store))
        XCTAssertFalse(companion.hasConfiguredQuickActionSelection)
        XCTAssertNil(fixture.defaults.object(forKey: "app.amber.ios.watch.selectedQuickActionIDs"))
    }

    private func assertQuickActionError<T>(
        _ expected: IOSSharedQuickActionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? IOSSharedQuickActionError, expected, file: file, line: line)
        }
    }
}

@MainActor
final class IOSSavedActionIntentResolverTests: XCTestCase {
    func testPlainTaskDoesNotRequestInput() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let action = try fixture.store.saveQuickAction(title: "简报", prompt: "生成简报")
        let result = try await IOSSavedActionIntentResolver.resolve(id: action.id, input: nil, settingsStore: { fixture.store }) {
            XCTFail("Plain tasks must not ask for input")
            return ""
        }
        XCTAssertEqual(result, action.prompt)
    }

    func testSuppliedInputDoesNotRequestAnotherValue() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let action = try fixture.store.saveQuickAction(title: "翻译", prompt: "翻译 {input}")
        let result = try await IOSSavedActionIntentResolver.resolve(id: action.id, input: "hello", settingsStore: { fixture.store }) {
            XCTFail("Supplied input must not be requested again")
            return ""
        }
        XCTAssertEqual(result, "翻译 hello")
    }

    func testMissingTemplateInputRequestsOnceAndReadsEditedTaskAfterAnswer() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let action = try fixture.store.saveQuickAction(title: "翻译", prompt: "翻译 {input}")
        var requests = 0
        var reads = 0
        let result = try await IOSSavedActionIntentResolver.resolve(id: action.id, input: nil, settingsStore: {
            reads += 1
            return fixture.reload()
        }) {
            requests += 1
            try fixture.store.saveQuickAction(id: action.id, title: "总结", prompt: "总结 {輸入}")
            return "hello"
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(result, "总结 hello")
        XCTAssertEqual(fixture.reload().savedQuickActions().last?.prompt, "总结 {輸入}")
    }

    func testDeletedWhileRequestingInputFailsInsteadOfRunningOldEntity() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let action = try fixture.store.saveQuickAction(title: "翻译", prompt: "翻译 {input}")
        do {
            _ = try await IOSSavedActionIntentResolver.resolve(id: action.id, input: nil, settingsStore: { fixture.reload() }) {
                try fixture.store.deleteQuickAction(id: action.id)
                return "hello"
            }
            XCTFail("Deleted task must not execute")
        } catch {
            XCTAssertEqual(error as? IOSSharedQuickActionError, .missingAction)
        }
    }

    func testStaleIDDoesNotRequestInput() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        do {
            _ = try await IOSSavedActionIntentResolver.resolve(id: UUID().uuidString, input: nil, settingsStore: { fixture.store }) {
                XCTFail("Missing tasks must fail before asking for input")
                return "hello"
            }
            XCTFail("Missing task must not execute")
        } catch {
            XCTAssertEqual(error as? IOSSharedQuickActionError, .missingAction)
        }
    }

    func testEmptyAnswerFailsWithoutLoopingOrHandingOffPlaceholder() async throws {
        let fixture = try QuickActionFixture()
        defer { fixture.cleanUp() }
        let action = try fixture.store.saveQuickAction(title: "翻译", prompt: "翻译 {input}")
        var requests = 0
        do {
            _ = try await IOSSavedActionIntentResolver.resolve(id: action.id, input: nil, settingsStore: { fixture.store }) {
                requests += 1
                return " \n"
            }
            XCTFail("Empty answer must not execute")
        } catch {
            XCTAssertEqual(error as? IOSSharedQuickActionError, .missingInput)
        }
        XCTAssertEqual(requests, 1)
    }
}

@MainActor
private final class QuickActionFixture {
    let suite = "IOSSharedQuickActions.\(UUID().uuidString)"
    let defaults: UserDefaults
    let credentials = QuickActionCredentials()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-action-tests-\(UUID().uuidString)")
    let store: IOSSharedSettingsStore

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = IOSSharedSettingsStore(
            userDefaults: defaults, loadCredential: credentials.load,
            storeCredential: credentials.store, deleteCredential: credentials.delete
        )
    }

    var persistedJSON: String? { defaults.string(forKey: "app.amber.ios.sharedSettingsJson") }

    func reload() -> IOSSharedSettingsStore {
        IOSSharedSettingsStore(
            userDefaults: defaults, loadCredential: credentials.load,
            storeCredential: credentials.store, deleteCredential: credentials.delete
        )
    }

    func addCredentialProvider() {
        store.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Quick action provider", apiKey: "quick-action-test-key", baseUrl: "https://example.com/v1",
            modelName: "Model", modelId: "model"
        ))
    }

    func settingsExcludingQuickMessages() throws -> NSDictionary {
        let json = IosSettingsJsonBridge.shared.encode(settings: store.snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object.removeValue(forKey: "quickMessages")
        return NSDictionary(dictionary: object)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class QuickActionCredentials {
    var values: [String: String] = [:]
    var rejectWrites = false

    func load(_ key: String) -> String? { values[key] }
    func store(_ key: String, _ value: String) -> Bool {
        guard !rejectWrites else { return false }
        values[key] = value
        return true
    }
    func delete(_ key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }
}
