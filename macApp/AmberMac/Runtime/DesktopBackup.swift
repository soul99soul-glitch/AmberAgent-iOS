import CommonCrypto
import CryptoKit
import Foundation
import Security

struct DesktopBackupPayload: Codable, Sendable {
    struct Preferences: Codable, Sendable {
        let systemPrompt: String
        let appearance: String
        let messageFontFamily: DesktopMessageFontFamily
        let messageFontSize: Double
        let assistantName: String
        let userNickname: String
        let reasoningExpandedByDefault: Bool
        let automaticallyFollowGeneration: Bool
        let notificationsEnabled: Bool?
        let selectedProviderID: UUID?
        let auxiliaryModelIDs: [String: UUID]

        @MainActor init(_ settings: DesktopSettings) {
            systemPrompt = settings.systemPrompt; appearance = settings.appearance
            messageFontFamily = settings.messageFontFamily; messageFontSize = settings.messageFontSize
            assistantName = settings.assistantName; userNickname = settings.userNickname
            reasoningExpandedByDefault = settings.reasoningExpandedByDefault
            automaticallyFollowGeneration = settings.automaticallyFollowGeneration
            notificationsEnabled = settings.notificationsEnabled
            selectedProviderID = settings.selectedProviderID; auxiliaryModelIDs = settings.auxiliaryModelIDs
        }
    }
    struct File: Codable, Equatable, Sendable {
        let path: String
        let data: Data
    }
    struct Conversation: Codable, Sendable {
        let id: UUID
        let document: String
        var insights: Data?
        var files: [File] = []
        var pins: [DesktopPinnedSnippet]?
    }
    var version = 1
    var createdAt = Date()
    var conversations: [Conversation] = []
    var providers: [DesktopProviderConfiguration] = []
    var unconfiguredProviders: [DesktopProviderConfiguration] = []
    var memories: [DesktopMemoryRecord] = []
    var knowledgeFiles: [File] = []
    var preferences: Preferences?
}

// The Mac payload has its own schema. The KDF and AES-GCM parameters match IOSSyncBackup.
enum DesktopBackup {
    static let fileExtension = "ambermacbackup"
    private static let format = "amber.mac.backup.v1"
    private static let iterations = 210_000
    private struct Envelope: Codable {
        var format: String
        var encrypted: Bool
        var salt: Data?
        var payload: Data
        var sha256: String
    }

    static func encode(_ value: DesktopBackupPayload, password: String?) throws -> Data {
        try validate(value)
        try Task.checkCancellation()
        let plain = try JSONEncoder().encode(value)
        let password = password ?? ""
        let encrypted = !password.isEmpty
        let salt = encrypted ? try random(16) : nil
        let payload: Data
        if let salt {
            let box = try AES.GCM.seal(plain, using: key(password, salt: salt), authenticating: Data(format.utf8))
            guard let combined = box.combined else { throw failure("无法生成加密备份。") }
            payload = combined
        } else { payload = plain }
        try Task.checkCancellation()
        return try JSONEncoder().encode(Envelope(format: format, encrypted: encrypted, salt: salt,
            payload: payload, sha256: hash(payload)))
    }

    static func decode(_ data: Data, password: String?) throws -> DesktopBackupPayload {
        try Task.checkCancellation()
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == format, hash(envelope.payload) == envelope.sha256 else {
            throw failure("备份格式不支持或文件已损坏。")
        }
        let plain: Data
        if envelope.encrypted {
            guard let salt = envelope.salt, salt.count == 16 else { throw failure("备份加密参数无效。") }
            let password = password ?? ""
            guard !password.isEmpty else { throw failure("请输入备份密码。") }
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.payload),
                    using: key(password, salt: salt), authenticating: Data(format.utf8))
            } catch { throw failure("备份密码错误或文件已损坏。") }
        } else {
            guard envelope.salt == nil else { throw failure("备份加密参数不一致。") }
            plain = envelope.payload
        }
        try Task.checkCancellation()
        let value = try JSONDecoder().decode(DesktopBackupPayload.self, from: plain)
        try validate(value)
        return value
    }

    static func validateRemoteArchive(_ data: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == format, envelope.encrypted, envelope.salt?.count == 16,
              hash(envelope.payload) == envelope.sha256 else {
            throw failure("远端快照必须是有效的加密 Amber Mac 备份。")
        }
        _ = try AES.GCM.SealedBox(combined: envelope.payload)
    }

    static func validate(_ value: DesktopBackupPayload) throws {
        guard value.version == 1 else { throw failure("不支持此备份版本。") }
        guard Set(value.conversations.map(\.id)).count == value.conversations.count,
              Set(value.providers.map(\.id)).count == value.providers.count,
              Set(value.providers.flatMap { $0.models.map(\.id) }).count == value.providers.flatMap(\.models).count,
              Set(value.memories.map(\.id)).count == value.memories.count else { throw failure("备份包含重复记录。") }
        for conversation in value.conversations {
            guard let data = conversation.document.data(using: .utf8),
                  (try JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw failure("会话记录不是完整 JSON。") }
            try validateFiles(conversation.files)
        }
        try validateFiles(value.knowledgeFiles)
    }

    static func validateFiles(_ files: [DesktopBackupPayload.File]) throws {
        guard Set(files.map(\.path)).count == files.count else { throw failure("备份包含重复文件路径。") }
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.isEmpty, !file.path.hasPrefix("/"), !file.path.contains("\\"), !file.path.contains("\0"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw failure("备份包含越出工作区的文件路径。")
            }
        }
    }

    static func readFiles(in directory: URL) throws -> [DesktopBackupPayload.File] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        var files: [DesktopBackupPayload.File] = []
        func collect(_ folder: URL, prefix: String) throws {
            let attributes = try manager.attributesOfItem(atPath: folder.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw failure("知识资料不能包含符号链接。") }
            for url in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw failure("知识资料不能包含符号链接。") }
                let path = prefix + url.lastPathComponent
                if values.isDirectory == true { try collect(url, prefix: path + "/") }
                else if values.isRegularFile == true { files.append(.init(path: path, data: try Data(contentsOf: url))) }
            }
        }
        try collect(directory, prefix: "")
        return files.sorted { $0.path < $1.path }
    }

    private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var output = Data(repeating: 0, count: 32)
        let status = output.withUnsafeMutableBytes { bytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        bytes.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw failure("无法派生备份加密密钥。") }
        return SymmetricKey(data: output)
    }

    private static func random(_ count: Int) throws -> Data {
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw failure("无法生成加密随机数。") }
        return data
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ message: String) -> DesktopRuntimeError { .message(message) }
}

struct DesktopBackupRestoreResult: Sendable {
    let conversations: [DesktopConversation]
    let providerCount: Int
    let memoryCount: Int
    let knowledgeConversationID: UUID?

    var message: String {
        var text = "已恢复 \(conversations.count) 个会话副本、\(providerCount) 个服务商配置副本和 \(memoryCount) 条记忆。现有内容已保留。"
        if providerCount > 0 { text += " 配置不含密钥，请在设置中填写或重新登录。" }
        if knowledgeConversationID != nil { text += " 配置和知识资料副本保存在“备份恢复资料”的会话文件中；通用偏好待手动应用，技能和 SOUL 等待导入启用。" }
        return text
    }
}

@MainActor final class DesktopBackupCoordinator {
    let storage: any DesktopConversationStorage
    let files: DesktopWorkspaceFiles
    let insights: DesktopConversationInsights
    let settings: DesktopSettings
    let knowledge: DesktopKnowledgeStore
    let artifactShelf: DesktopArtifactShelf

    init(storage: any DesktopConversationStorage, files: DesktopWorkspaceFiles, insights: DesktopConversationInsights,
         settings: DesktopSettings, knowledge: DesktopKnowledgeStore, artifactShelf: DesktopArtifactShelf = DesktopArtifactShelf()) {
        self.storage = storage; self.files = files; self.insights = insights; self.settings = settings; self.knowledge = knowledge
        self.artifactShelf = artifactShelf
    }

    func snapshot(current: [DesktopConversation]) async throws -> DesktopBackupPayload {
        let templates = settings.providers.filter { $0.authMode == .apiKey && $0.models.allSatisfy { $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        let templateIDs = Set(templates.map(\.id))
        var value = DesktopBackupPayload(providers: settings.providers.filter { !templateIDs.contains($0.id) },
            unconfiguredProviders: templates, memories: knowledge.memories)
        value.preferences = .init(settings)
        guard knowledge.loadError == nil else { throw DesktopRuntimeError.message("知识资料未读取成功，无法完整备份。") }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let summaries = try await storage.listSummaries()
        let ids = Set(summaries.map(\.id)).union(currentByID.keys).sorted { $0.uuidString < $1.uuidString }
        for id in ids {
            try Task.checkCancellation()
            let loaded: DesktopConversation?
            if let current = currentByID[id] { loaded = current }
            else { loaded = try await storage.load(id) }
            guard let conversation = loaded else {
                throw DesktopRuntimeError.message("备份期间会话文件已消失，请重新备份。")
            }
            let document = try await storage.exportDocument(conversation)
            var attachments: [DesktopBackupPayload.File] = []
            for entry in try await files.list(conversationID: id) {
                attachments.append(.init(path: entry.id, data: try await files.read(conversationID: id, path: entry.id)))
            }
            value.conversations.append(.init(id: id, document: document,
                insights: try await insights.backupRecord(id), files: attachments,
                pins: artifactShelf.pins(for: id).isEmpty ? nil : artifactShelf.pins(for: id)))
        }
        let directory = knowledge.directory
        value.knowledgeFiles = try await Task.detached { try DesktopBackup.readFiles(in: directory) }.value
        return value
    }

    func restore(_ payload: DesktopBackupPayload) async throws -> DesktopBackupRestoreResult {
        try Task.checkCancellation()
        try DesktopBackup.validate(payload)
        for provider in payload.providers {
            try DesktopSettings.validateEndpoint(provider.baseURL)
            for model in provider.models { _ = try model.validated(for: provider.kind) }
        }
        var prepared: [(DesktopBackupPayload.Conversation, DesktopConversation)] = []
        var mapping: [UUID: UUID] = [:]
        for entry in payload.conversations {
            try Task.checkCancellation()
            if let data = entry.insights { try DesktopConversationInsights.validateBackupRecord(data) }
            var conversation = try await storage.normalizeImport(entry.document)
            guard conversation.id == entry.id else { throw DesktopRuntimeError.message("备份会话标识与完整记录不一致。") }
            conversation.id = UUID()
            for index in conversation.messages.indices where conversation.messages[index].state == .streaming { conversation.messages[index].state = .cancelled }
            mapping[entry.id] = conversation.id
            prepared.append((entry, conversation))
        }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("amber-restore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try JSONEncoder().encode(payload).write(to: stage.appendingPathComponent("payload.json"), options: .atomic)
        var saved: [DesktopConversation] = []
        var importedProviders: [UUID] = []
        var importedMemories: [Int] = []
        var attemptedIDs: [UUID] = []
        var knowledgeOwner: UUID?
        do {
            try Task.checkCancellation()
            importedMemories = try knowledge.mergeRestoredMemories(payload.memories, conversationIDs: mapping)
            let memoryMapping = Dictionary(uniqueKeysWithValues: zip(payload.memories.map(\.id), importedMemories))
            for (entry, proposed) in prepared {
                let conversation = try await storage.remapMemoryCitations(proposed, mapping: memoryMapping)
                try Task.checkCancellation()
                attemptedIDs.append(conversation.id)
                saved.append(try await storage.save(conversation))
                for file in entry.files { _ = try await files.write(conversationID: conversation.id, path: file.path, data: file.data) }
                if let record = entry.insights { try await insights.restoreRecord(record, for: conversation.id) }
                artifactShelf.restore(entry.pins ?? [], for: conversation.id)
            }
            if !payload.knowledgeFiles.isEmpty || !payload.unconfiguredProviders.isEmpty || payload.preferences != nil {
                try Task.checkCancellation()
                let conversation = DesktopConversation(title: "备份恢复资料", messages: [DesktopMessage(role: .assistant,
                    text: "恢复的知识资料保存在此会话的文件中。记忆已合并；技能和 SOUL 请预览后通过知识设置导入启用。现有技能和 SOUL 保持不变。")])
                attemptedIDs.append(conversation.id)
                saved.append(try await storage.save(conversation))
                knowledgeOwner = conversation.id
                for file in payload.knowledgeFiles { _ = try await files.write(conversationID: conversation.id, path: "knowledge/" + file.path, data: file.data) }
                if let preferences = payload.preferences {
                    _ = try await files.write(conversationID: conversation.id, path: "configuration/preferences.json",
                        data: JSONEncoder().encode(preferences))
                }
                if !payload.unconfiguredProviders.isEmpty {
                    _ = try await files.write(conversationID: conversation.id, path: "configuration/unconfigured-providers.json",
                        data: JSONEncoder().encode(payload.unconfiguredProviders))
                }
            }
            try Task.checkCancellation()
            importedProviders = try settings.importProviderCopies(payload.providers)
            try Task.checkCancellation()
            return DesktopBackupRestoreResult(conversations: saved, providerCount: importedProviders.count,
                memoryCount: importedMemories.count, knowledgeConversationID: knowledgeOwner)
        } catch {
            var cleanupFailed = false
            settings.removeImportedProviders(importedProviders)
            do { try knowledge.removeRestoredMemories(ids: importedMemories) } catch { cleanupFailed = true }
            for id in attemptedIDs {
                do { try await storage.delete(id) } catch { cleanupFailed = true }
                do { try await files.removeConversation(id) } catch { cleanupFailed = true }
                insights.remove(id)
                artifactShelf.removeConversation(id)
            }
            await insights.flush()
            if cleanupFailed { throw DesktopRuntimeError.message("恢复未完成，现有内容未更改；部分本次副本清理失败，请检查磁盘权限后重新读取会话列表。") }
            throw error
        }
    }
}
