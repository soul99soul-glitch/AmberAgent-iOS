import XCTest
@testable import AmberMac

@MainActor final class DesktopBackupTests: XCTestCase {
    private final class Storage: DesktopConversationStorage {
        let memory: DesktopMemoryConversationStorage
        var saves = 0
        var failAtSave: Int?
        var holdFirstSave = false
        var saveGate: CheckedContinuation<Void, Never>?
        var memoryMappings: [[Int: Int]] = []
        init(_ values: [DesktopConversation]) { memory = DesktopMemoryConversationStorage(values) }
        func loadAll() async throws -> [DesktopConversation] { memory.values }
        func save(_ value: DesktopConversation) async throws -> DesktopConversation {
            saves += 1
            if saves == failAtSave { throw DesktopRuntimeError.message("disk failure") }
            let saved = try await memory.save(value)
            if holdFirstSave, saves == 1 { await withCheckedContinuation { saveGate = $0 } }
            return saved
        }
        func delete(_ id: UUID) async throws { try await memory.delete(id) }
        func remapMemoryCitations(_ value: DesktopConversation, mapping: [Int: Int]) async throws -> DesktopConversation {
            memoryMappings.append(mapping)
            return value
        }
    }
    private final class Provider: DesktopTextProvider {
        var run: DesktopGeneration?
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let value = DesktopGeneration(); run = value; return value
        }
    }

    private func payload(_ values: [DesktopConversation]) throws -> DesktopBackupPayload {
        DesktopBackupPayload(conversations: try values.map {
            .init(id: $0.id, document: try DesktopJSON.encode(DesktopConversationExport(conversation: $0)),
                files: [.init(path: "outputs/result.txt", data: Data("original file".utf8))])
        })
    }
    private func coordinator(_ storage: Storage, directory: URL) -> DesktopBackupCoordinator {
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.backup.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        return DesktopBackupCoordinator(storage: storage, files: DesktopWorkspaceFiles(directory: directory.appendingPathComponent("files")),
            insights: DesktopConversationInsights(directory: directory.appendingPathComponent("insights")), settings: settings,
            knowledge: DesktopKnowledgeStore(directory: directory.appendingPathComponent("knowledge")))
    }

    func testEncryptedAndPlainRoundTripAndWrongPassword() throws {
        let original = DesktopConversation(title: "private title", messages: [DesktopMessage(role: .user, text: "private body")])
        let value = try payload([original])
        let encrypted = try DesktopBackup.encode(value, password: "correct password")
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("private body"))
        let restored = try DesktopBackup.decode(encrypted, password: "correct password")
        XCTAssertEqual(restored.conversations[0].document, value.conversations[0].document)
        XCTAssertEqual(restored.conversations[0].files, value.conversations[0].files)
        XCTAssertThrowsError(try DesktopBackup.decode(encrypted, password: "wrong password"))
        XCTAssertThrowsError(try DesktopBackup.decode(encrypted, password: nil))
        let spaces = try DesktopBackup.encode(value, password: "   ")
        XCTAssertThrowsError(try DesktopBackup.decode(spaces, password: nil))
        XCTAssertEqual(try DesktopBackup.decode(spaces, password: "   ").conversations[0].id, original.id)
        let plain = try DesktopBackup.encode(value, password: nil)
        XCTAssertEqual(try DesktopBackup.decode(plain, password: nil).conversations[0].id, original.id)
    }

    func testCorruptDuplicateAndTraversalArchivesAreRejected() throws {
        let conversation = DesktopConversation()
        var value = try payload([conversation])
        let encoded = try DesktopBackup.encode(value, password: "secret")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["payload"] = Data("corrupt".utf8).base64EncodedString()
        XCTAssertThrowsError(try DesktopBackup.decode(JSONSerialization.data(withJSONObject: json), password: "secret"))
        value.conversations.append(value.conversations[0])
        XCTAssertThrowsError(try DesktopBackup.encode(value, password: nil))
        value = try payload([conversation])
        for path in ["../escape", "/tmp/escape", "a//b", "a/../b", "a\\b"] {
            value.conversations[0].files = [.init(path: path, data: Data())]
            XCTAssertThrowsError(try DesktopBackup.encode(value, password: nil))
        }
        value.conversations[0].files = [.init(path: "same", data: Data()), .init(path: "same", data: Data())]
        XCTAssertThrowsError(try DesktopBackup.encode(value, password: nil))
    }

    func testRestoreCreatesNewOwnerAndKeepsOriginalAndFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DesktopConversation(title: "existing", messages: [DesktopMessage(role: .user, text: "original")])
        let storage = Storage([original])
        let service = coordinator(storage, directory: directory)
        let result = try await service.restore(payload([original]))
        let restored = try XCTUnwrap(result.conversations.first)
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(storage.memory.values.first { $0.id == original.id }, original)
        let file = try await service.files.read(conversationID: restored.id, path: "outputs/result.txt")
        XCTAssertEqual(String(data: file, encoding: .utf8), "original file")
        let originalFiles = try await service.files.list(conversationID: original.id)
        XCTAssertTrue(originalFiles.isEmpty)
    }

    func testFailedRestoreRollsBackOnlyNewRecordsAndFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DesktopConversation(title: "untouched")
        let storage = Storage([original])
        storage.failAtSave = 2
        let service = coordinator(storage, directory: directory)
        let existingMemory = try service.knowledge.saveMemory(DesktopMemoryRecord(content: "keep this memory"))
        var incoming = DesktopMemoryRecord(content: "must roll back")
        incoming.id = existingMemory.id
        var value = try payload([DesktopConversation(title: "copy one"), DesktopConversation(title: "copy two")])
        value.memories = [incoming]
        do {
            _ = try await service.restore(value)
            XCTFail("Second write must fail")
        } catch {}
        XCTAssertEqual(storage.memory.values, [original])
        XCTAssertEqual(service.knowledge.memories, [existingMemory])
        let allocated = try XCTUnwrap(storage.memoryMappings.first?[incoming.id])
        let later = try service.knowledge.saveMemory(DesktopMemoryRecord(content: "new memory after rollback"))
        XCTAssertGreaterThan(later.id, allocated)
        let fileRoot = directory.appendingPathComponent("files")
        let owners = FileManager.default.fileExists(atPath: fileRoot.path) ? try FileManager.default.contentsOfDirectory(atPath: fileRoot.path) : []
        XCTAssertTrue(owners.isEmpty)
    }

    func testFreshUnconfiguredProviderIsPreservedAsMaterialAndDoesNotBreakRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DesktopConversation(title: "original")
        let storage = Storage([original])
        let service = coordinator(storage, directory: directory)
        let snapshot = try await service.snapshot(current: [original])
        XCTAssertTrue(snapshot.providers.isEmpty)
        XCTAssertEqual(snapshot.unconfiguredProviders.count, 1)
        let result = try await service.restore(snapshot)
        XCTAssertEqual(result.providerCount, 0)
        let owner = try XCTUnwrap(result.knowledgeConversationID)
        let raw = try await service.files.read(conversationID: owner, path: "configuration/unconfigured-providers.json")
        let templates = try JSONDecoder().decode([DesktopProviderConfiguration].self, from: raw)
        XCTAssertEqual(templates.first?.modelID, "")
        XCTAssertEqual(service.settings.providers.count, 1)
    }

    func testInvalidInsightRecordIsRejectedBeforeAnyWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DesktopConversation(title: "untouched")
        let storage = Storage([original])
        let service = coordinator(storage, directory: directory)
        var value = try payload([DesktopConversation()])
        value.conversations[0].insights = Data("corrupt".utf8)
        do { _ = try await service.restore(value); XCTFail("Invalid insights") } catch {}
        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(storage.memory.values, [original])
    }

    func testCancellationAfterFirstDurableWriteRollsBackNewOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DesktopConversation(title: "untouched")
        let storage = Storage([original])
        storage.holdFirstSave = true
        let service = coordinator(storage, directory: directory)
        let value = try payload([DesktopConversation(title: "copy one"), DesktopConversation(title: "copy two")])
        let task = Task { try await service.restore(value) }
        while storage.saveGate == nil { await Task.yield() }
        task.cancel()
        storage.saveGate?.resume()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(storage.memory.values, [original])
        let root = directory.appendingPathComponent("files")
        let owners = FileManager.default.fileExists(atPath: root.path) ? try FileManager.default.contentsOfDirectory(atPath: root.path) : []
        XCTAssertTrue(owners.isEmpty)
    }

    func testSnapshotAndRestoreKeepActualInsightRecordWithCopiedConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DesktopConversation(title: "known", messages: [DesktopMessage(role: .user, text: "question")])
        let storage = Storage([original])
        let service = coordinator(storage, directory: directory)
        let provider = Provider()
        let config = DesktopProviderConfiguration(name: "test", kind: .openAI, baseURL: "http://localhost/v1", modelID: "test")
        service.insights.generate(.recap, conversation: original, configuration: config, apiKey: "", provider: provider, isCurrent: { _ in true })
        while provider.run == nil { await Task.yield() }
        provider.run?.yield(.snapshot(text: "saved recap", reasoning: ""))
        provider.run?.yield(.complete)
        await service.insights.waitUntilIdle(original.id)
        let value = try await service.snapshot(current: [original])
        XCTAssertNotNil(value.conversations.first?.insights)
        let result = try await service.restore(value)
        let restored = try XCTUnwrap(result.conversations.first { $0.title == original.title })
        XCTAssertEqual(service.insights.value(.recap, for: restored)?.text, "saved recap")
        XCTAssertEqual(service.insights.value(.recap, for: original)?.text, "saved recap")
    }

    func testRestoredMemoryIDsAndSourcesUseCopiedConversationNamespace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DesktopConversation(title: "original", messages: [DesktopMessage(role: .user, text: "source")])
        let storage = Storage([original])
        let service = coordinator(storage, directory: directory)
        let existing = try service.knowledge.saveMemory(DesktopMemoryRecord(content: "existing memory"))
        var incoming = DesktopMemoryRecord(content: "restored memory")
        incoming.id = existing.id
        incoming.sourceConversationId = original.id.uuidString
        incoming.sourceMessageIds = original.messages.map { $0.id.uuidString }
        var value = try payload([original])
        value.memories = [incoming]
        let result = try await service.restore(value)
        let copy = try XCTUnwrap(result.conversations.first)
        let memory = try XCTUnwrap(service.knowledge.memories.first { $0.content == incoming.content })
        XCTAssertNotEqual(memory.id, existing.id)
        XCTAssertEqual(UUID(uuidString: memory.sourceConversationId ?? ""), copy.id)
        XCTAssertEqual(memory.sourceMessageIds, incoming.sourceMessageIds)
        XCTAssertEqual(storage.memoryMappings, [[incoming.id: memory.id]])
        XCTAssertEqual(service.knowledge.memories.first { $0.id == existing.id }, existing)
    }

    func testCancelledRestoreDoesNotWriteAnything() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DesktopConversation(title: "untouched")
        let storage = Storage([original])
        let service = coordinator(storage, directory: directory)
        let value = try payload([DesktopConversation()])
        let task = Task { try await service.restore(value) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(storage.memory.values, [original])
    }
}
