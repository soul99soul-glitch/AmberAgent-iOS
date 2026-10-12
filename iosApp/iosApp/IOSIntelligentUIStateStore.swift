import CryptoKit
import Foundation
import Observation

struct IOSIntelligentUISource: Codable, Hashable, Sendable {
    let conversationID: String
    let messageID: String
    let textPartIndex: Int
    let cardID: String
}

struct IOSIntelligentUIDraft: Codable, Equatable, Sendable {
    var selectedOptionID: String?
    var values: [String: String]
    let definitionFingerprint: String
    let revision: Int
}

private struct IOSIntelligentUIStoredState: Codable, Sendable {
    struct Record: Codable, Sendable {
        let source: IOSIntelligentUISource
        let draft: IOSIntelligentUIDraft
    }

    var revision: Int = 0
    var records: [Record] = []
    var activeSources: [String: IOSIntelligentUISource] = [:]
}

private struct IOSIntelligentUIStorageError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Only this actor performs writes. A queued older snapshot cannot replace newer state.
private actor IOSIntelligentUIStateWriter {
    private let fileURL: URL
    private let loadFailure: String?
    private var writtenRevision: Int

    init(fileURL: URL, writtenRevision: Int, loadFailure: String?) {
        self.fileURL = fileURL
        self.writtenRevision = writtenRevision
        self.loadFailure = loadFailure
    }

    func write(_ state: IOSIntelligentUIStoredState) throws {
        if let loadFailure { throw IOSIntelligentUIStorageError(message: loadFailure) }
        guard state.revision > writtenRevision else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        writtenRevision = state.revision
    }
}

/// App-owned local drafts; submitted snapshots belong to conversation messages.
@MainActor
@Observable
final class IOSIntelligentUIStateStore {
    private(set) var revision = 0
    private(set) var storageError: String?

    private var drafts: [IOSIntelligentUISource: IOSIntelligentUIDraft] = [:]
    private var activeSources: [String: IOSIntelligentUISource] = [:]
    @ObservationIgnored private let writer: IOSIntelligentUIStateWriter?
    private var fingerprints: [IOSIntelligentUISource: (
        definition: IOSIntelligentUICardDefinition, fingerprint: String
    )] = [:]

    /// Loading occurs once when the conversation owner initializes, never in a view body.
    init(fileURL: URL? = nil) {
        guard let fileURL else {
            writer = nil
            return
        }
        var loaded = IOSIntelligentUIStoredState()
        var failure: String?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                loaded = try JSONDecoder().decode(
                    IOSIntelligentUIStoredState.self, from: Data(contentsOf: fileURL)
                )
                var restored: [IOSIntelligentUISource: IOSIntelligentUIDraft] = [:]
                for record in loaded.records {
                    guard restored[record.source] == nil else {
                        throw IOSIntelligentUIStorageError(message: "任务卡草稿包含重复来源。")
                    }
                    restored[record.source] = record.draft
                }
                drafts = restored
                activeSources = loaded.activeSources.filter { conversationID, source in
                    source.conversationID == conversationID && restored[source] != nil
                }
                revision = loaded.revision
            } catch {
                failure = "任务卡草稿无法读取：\(error.localizedDescription) 原文件已保留，当前修改尚未保存。"
                storageError = failure
            }
        }
        writer = IOSIntelligentUIStateWriter(
            fileURL: fileURL, writtenRevision: failure == nil ? loaded.revision : 0, loadFailure: failure
        )
    }

    func draft(
        for source: IOSIntelligentUISource, definition: IOSIntelligentUICardDefinition
    ) -> IOSIntelligentUIDraft {
        let fingerprint = registeredFingerprint(for: source, definition: definition) ?? ""
        if let draft = drafts[source], draft.definitionFingerprint == fingerprint { return draft }
        return IOSIntelligentUIDraft(
            selectedOptionID: nil, values: [:], definitionFingerprint: fingerprint, revision: 0
        )
    }

    func hasDefinitionChanged(
        for source: IOSIntelligentUISource, definition: IOSIntelligentUICardDefinition
    ) -> Bool {
        guard let stored = drafts[source] else { return false }
        guard let fingerprint = registeredFingerprint(for: source, definition: definition) else { return false }
        return stored.definitionFingerprint != fingerprint
    }

    /// Call at the card lifecycle boundary, rather than computing JSON/hash while rendering.
    func register(source: IOSIntelligentUISource, definition: IOSIntelligentUICardDefinition) {
        guard fingerprints[source]?.definition != definition else { return }
        fingerprints[source] = (definition, Self.definitionFingerprint(definition))
    }

    func activeSource(for conversationID: String) -> IOSIntelligentUISource? {
        activeSources[conversationID]
    }

    func update(
        source: IOSIntelligentUISource, definition: IOSIntelligentUICardDefinition,
        selectedOptionID: String?, values: [String: String]
    ) throws {
        guard source.cardID == definition.cardID else {
            throw IOSIntelligentUIProtocolError(reason: "任务卡来源与内容不一致。")
        }
        if let selectedOptionID, !definition.options.contains(where: { $0.id == selectedOptionID }) {
            throw IOSIntelligentUIProtocolError(reason: "所选方案不在当前任务卡中。")
        }
        let fieldIDs = Set(definition.fields.map(\.id))
        var filteredValues = values.filter { fieldIDs.contains($0.key) && !$0.value.isEmpty }
        if definition.kind == "study", let study = definition.study,
           let rawSession = values[IOSIntelligentUIStudySession.storageKey] {
            let session = try IOSIntelligentUIStudySession.restore(rawSession, definition: study)
            filteredValues[IOSIntelligentUIStudySession.storageKey] = try session.encodedValue()
        }
        register(source: source, definition: definition)
        let current = draft(for: source, definition: definition)
        let contentChanged = current.selectedOptionID != selectedOptionID || current.values != filteredValues
        // Merely rendering an empty card must not create a draft or change the active card.
        guard contentChanged || drafts[source] != nil else { return }
        let definitionChanged = hasDefinitionChanged(for: source, definition: definition)
        guard contentChanged || definitionChanged || activeSources[source.conversationID] != source else { return }
        if contentChanged || definitionChanged {
            drafts[source] = IOSIntelligentUIDraft(
                selectedOptionID: selectedOptionID, values: filteredValues,
                definitionFingerprint: current.definitionFingerprint,
                revision: (drafts[source]?.revision ?? 0) + 1
            )
        }
        activeSources[source.conversationID] = source
        commit()
    }

    func removeConversation(_ conversationID: String) {
        removeConversations([conversationID])
    }

    func removeConversations(_ conversationIDs: Set<String>) {
        let nextDrafts = drafts.filter { !conversationIDs.contains($0.key.conversationID) }
        let nextActive = activeSources.filter { !conversationIDs.contains($0.key) }
        guard nextDrafts != drafts || nextActive != activeSources else { return }
        drafts = nextDrafts
        activeSources = nextActive
        fingerprints = fingerprints.filter { !conversationIDs.contains($0.key.conversationID) }
        commit()
    }

    /// Explicit submission/tests can wait for the latest local snapshot without main-thread IO.
    func flush() async throws {
        guard let writer else { return }
        let snapshot = storedState()
        do {
            try await writer.write(snapshot)
            if revision == snapshot.revision { storageError = nil }
        } catch {
            if revision == snapshot.revision { storageError = "任务卡修改尚未保存：\(error.localizedDescription)" }
            throw error
        }
    }

    static func definitionFingerprint(_ definition: IOSIntelligentUICardDefinition) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // The schema contains only finite JSON values (strings, integers, booleans and arrays).
        // Encoding these Codable values cannot fail; keep failure explicit if the schema changes.
        let data: Data
        do { data = try encoder.encode(definition) }
        catch { preconditionFailure("Invalid task-ui Codable schema: \(error)") }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func registeredFingerprint(
        for source: IOSIntelligentUISource, definition: IOSIntelligentUICardDefinition
    ) -> String? {
        if let cached = fingerprints[source], cached.definition == definition { return cached.fingerprint }
        return nil
    }

    private func storedState() -> IOSIntelligentUIStoredState {
        IOSIntelligentUIStoredState(
            revision: revision,
            records: drafts.map { .init(source: $0.key, draft: $0.value) },
            activeSources: activeSources
        )
    }

    private func commit() {
        revision += 1
        guard let writer else { return }
        let snapshot = storedState()
        Task {
            do {
                try await writer.write(snapshot)
                if revision == snapshot.revision { storageError = nil }
            } catch {
                if revision == snapshot.revision { storageError = "任务卡修改尚未保存：\(error.localizedDescription)" }
            }
        }
    }
}
