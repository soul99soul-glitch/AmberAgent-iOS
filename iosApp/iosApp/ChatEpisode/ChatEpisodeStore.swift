import Foundation
@preconcurrency import Shared

/// Manages Episode topic boundaries, 3-hour idle auto-splits, and sidecar persistence per conversation.
/// In-memory cached on `@MainActor` so timeline projection and prompt assembly never perform disk I/O on render paths;
/// JSON writes happen asynchronously on a dedicated serial background queue (with synchronous flush hook for tests).
@MainActor
final class ChatEpisodeStore {
    static let shared = ChatEpisodeStore()

    private let baseDirectoryURL: URL
    private let ioQueue = DispatchQueue(label: "app.amber.ios.chatEpisodeStore.io", qos: .utility)
    private var cache: [String: ChatEpisodeLedger] = [:]
    private var loadedConversationIds: Set<String> = []
    /// Monotonically incremented whenever any Episode is sealed, updated, or deleted so cached prompt indices can invalidate cheaply.
    private(set) var mutationRevision: UInt64 = 0

    init(baseDirectoryURL: URL? = nil) {
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectoryURL = documents.appendingPathComponent("conversation-episodes", isDirectory: true)
        }
    }

    // MARK: - Querying Episodes & Active Window Boundaries

    func episodes(for conversationId: String?) -> [ChatEpisodeRecord] {
        guard let key = normalizedKey(conversationId) else { return [] }
        return ledger(for: key).episodes
    }

    func episode(id episodeId: String, in conversationId: String?) -> ChatEpisodeRecord? {
        let target = episodeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        return episodes(for: conversationId).first { $0.id.lowercased() == target }
    }

    /// Resolves the anchor message ID of the latest sealed Episode that still exists in `messages`.
    /// If the user deleted the exact `afterMessageId` bubble, falls back to the last surviving message ID of that Episode.
    func activeBoundaryMessageId(for conversationId: String?, in messages: [UIMessage]) -> String? {
        guard let key = normalizedKey(conversationId), !messages.isEmpty else { return nil }
        let storedEpisodes = ledger(for: key).episodes
        guard !storedEpisodes.isEmpty else { return nil }

        let existingIds = Set(messages.map(ChatMessageProjector.messageId(for:)))
        for episode in storedEpisodes.reversed() {
            if existingIds.contains(episode.afterMessageId) {
                return episode.afterMessageId
            }
            if let fallback = episode.messageIds.reversed().first(where: { existingIds.contains($0) }) {
                return fallback
            }
        }
        return nil
    }

    /// Returns non-system messages strictly after the latest valid Episode boundary.
    func unsealedNonSystemMessages(for conversationId: String?, in messages: [UIMessage]) -> [UIMessage] {
        let nonSystem = messages.filter {
            $0.role != MessageRole.system && !IOSOrchestrationConfigurationCodec.isOrchestrationConfigurationMessage($0)
        }
        guard !nonSystem.isEmpty else { return [] }
        guard let anchorId = activeBoundaryMessageId(for: conversationId, in: nonSystem),
              let anchorIndex = nonSystem.lastIndex(where: { ChatMessageProjector.messageId(for: $0) == anchorId }) else {
            return nonSystem
        }
        let nextIndex = nonSystem.index(after: anchorIndex)
        guard nextIndex < nonSystem.endIndex else { return [] }
        return Array(nonSystem[nextIndex...])
    }

    /// True when there are no unsealed visible conversation messages after the latest Episode boundary.
    /// Prevents `✦ 新话题` from inserting duplicate dividers when tapped repeatedly on an empty boundary.
    func isAtEmptyBoundary(conversationId: String?, messages: [UIMessage]) -> Bool {
        let unsealedVisible = unsealedNonSystemMessages(for: conversationId, in: messages)
            .filter(ChatMessageProjector.isVisibleInTimeline)
        return unsealedVisible.isEmpty
    }

    // MARK: - Timestamp Tracking & 3-Hour Gap Detection

    func recordMessageTimestamp(
        conversationId: String?,
        messageId: String,
        timestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000.0)
    ) {
        guard let key = normalizedKey(conversationId), !messageId.isEmpty, timestampMillis > 0 else { return }
        var current = ledger(for: key)
        guard current.messageTimestampsMillis[messageId] != timestampMillis else { return }
        current.messageTimestampsMillis[messageId] = timestampMillis
        // Cap timestamp map size so multi-month streams remain tiny on disk.
        if current.messageTimestampsMillis.count > 600 {
            let sorted = current.messageTimestampsMillis.sorted { $0.value > $1.value }.prefix(400)
            current.messageTimestampsMillis = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
        }
        saveLedger(current)
    }

    func resolvedTimestampMillis(for message: UIMessage, conversationId: String?) -> Int64? {
        let msgId = ChatMessageProjector.messageId(for: message)
        if let key = normalizedKey(conversationId),
           let recorded = ledger(for: key).messageTimestampsMillis[msgId],
           recorded > 0 {
            return recorded
        }
        if let finishedAt = message.finishedAt,
           let millis = ChatEpisodeTextNormalizer.epochMillis(from: finishedAt) {
            return millis
        }
        return ChatEpisodeTextNormalizer.epochMillis(from: message.createdAt)
    }

    /// Checks whether the incoming user message arrives strictly more than 3 hours (`> 10800s`) after
    /// the last message in the current active Episode; if so, seals the prior active Episode first.
    @discardableResult
    func sealIfIdleTimeoutExceeded(
        conversationId: String?,
        existingMessages: [UIMessage],
        incomingMessageTimestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000.0)
    ) -> ChatEpisodeRecord? {
        guard let key = normalizedKey(conversationId) else { return nil }
        let unsealed = unsealedNonSystemMessages(for: key, in: existingMessages)
            .filter(ChatMessageProjector.isVisibleInTimeline)
        guard let lastActiveMessage = unsealed.last,
              let lastMillis = resolvedTimestampMillis(for: lastActiveMessage, conversationId: key) else {
            return nil
        }
        let elapsedMillis = incomingMessageTimestampMillis - lastMillis
        guard elapsedMillis > ChatEpisodeConstants.idleTimeoutMillis else {
            return nil
        }
        return sealCurrentEpisodeIfNeeded(
            conversationId: key,
            messages: existingMessages,
            reason: .idleTimeout,
            nowMillis: incomingMessageTimestampMillis
        )
    }

    // MARK: - Sealing & Updating Episodes

    /// Seals all currently active (unsealed) messages into a new `ChatEpisodeRecord`.
    /// Returns `nil` if the conversation is empty or already at an empty Episode boundary (idempotent).
    @discardableResult
    func sealCurrentEpisodeIfNeeded(
        conversationId: String?,
        messages: [UIMessage],
        reason: ChatEpisodeSealReason,
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000.0)
    ) -> ChatEpisodeRecord? {
        guard let key = normalizedKey(conversationId) else { return nil }
        let activeSlice = unsealedNonSystemMessages(for: key, in: messages)
        let visibleSlice = activeSlice.filter(ChatMessageProjector.isVisibleInTimeline)
        guard let firstVisible = visibleSlice.first,
              let lastVisible = visibleSlice.last else {
            return nil
        }

        var current = ledger(for: key)
        let afterId = ChatMessageProjector.messageId(for: lastVisible)
        if current.episodes.last?.afterMessageId == afterId {
            return nil
        }

        let ordinal = max(current.nextOrdinal, (current.episodes.map(\.ordinal).max() ?? 0) + 1)
        let episodeId = ChatEpisodeRecord.formatEpisodeId(ordinal: ordinal)
        let messageIds = activeSlice.map(ChatMessageProjector.messageId(for:))
        let turns = Self.countEffectiveTurns(in: activeSlice)
        let startedAt = resolvedTimestampMillis(for: firstVisible, conversationId: key) ?? nowMillis
        let lastMessageTime = resolvedTimestampMillis(for: lastVisible, conversationId: key) ?? nowMillis
        let sealedAt = max(lastMessageTime, nowMillis)
        let digest = ChatEpisodeSummarizer.buildDeterministicDigest(from: activeSlice)
        let status: ChatEpisodeDistillationStatus = turns >= ChatEpisodeConstants.minTurnsForBackgroundDistillation
            ? .pending
            : .skippedShort

        let record = ChatEpisodeRecord(
            id: episodeId,
            conversationId: key,
            ordinal: ordinal,
            afterMessageId: afterId,
            startMessageId: ChatMessageProjector.messageId(for: firstVisible),
            endMessageId: afterId,
            messageIds: messageIds,
            turnCount: turns,
            startedAtMillis: startedAt,
            sealedAtMillis: sealedAt,
            sealReason: reason,
            title: digest.title,
            summary: digest.summary,
            distillationStatus: status
        )

        current.nextOrdinal = ordinal + 1
        current.episodes.append(record)
        mutationRevision &+= 1
        saveLedger(current)
        return record
    }

    func updateEpisodeDigest(
        conversationId: String?,
        episodeId: String,
        title: String?,
        summary: String?,
        status: ChatEpisodeDistillationStatus
    ) {
        guard let key = normalizedKey(conversationId) else { return }
        var current = ledger(for: key)
        guard let index = current.episodes.firstIndex(where: { $0.id == episodeId }) else { return }

        var updated = current.episodes[index]
        if let title {
            let cleanedTitle = ChatEpisodeTextNormalizer.singleLine(title, maxChars: ChatEpisodeConstants.maxTitleChars)
            if !cleanedTitle.isEmpty {
                updated.title = cleanedTitle
            }
        }
        if let summary {
            let cleanedSummary = ChatEpisodeTextNormalizer.singleLine(summary, maxChars: 72)
            if !cleanedSummary.isEmpty {
                updated.summary = cleanedSummary
            }
        }
        updated.distillationStatus = status
        guard updated != current.episodes[index] else { return }
        current.episodes[index] = updated
        mutationRevision &+= 1
        saveLedger(current)
    }

    // MARK: - Timeline Boundary Projection

    func timelineBoundaries(conversationId: KotlinUuid?, messages: [UIMessage]) -> [ChatContextCompactBoundary] {
        timelineBoundaries(conversationId: conversationId?.toHexDashString(), messages: messages)
    }

    func timelineBoundaries(conversationId: String?, messages: [UIMessage]) -> [ChatContextCompactBoundary] {
        guard let key = normalizedKey(conversationId), !messages.isEmpty else { return [] }
        let stored = ledger(for: key).episodes
        guard !stored.isEmpty else { return [] }

        let existingIds = Set(messages.map(ChatMessageProjector.messageId(for:)))
        var seenAnchors = Set<String>()
        var boundaries: [ChatContextCompactBoundary] = []

        for episode in stored {
            let resolvedAnchor: String?
            if existingIds.contains(episode.afterMessageId) {
                resolvedAnchor = episode.afterMessageId
            } else {
                resolvedAnchor = episode.messageIds.reversed().first { existingIds.contains($0) }
            }
            guard let anchor = resolvedAnchor, seenAnchors.insert(anchor).inserted else { continue }
            boundaries.append(
                ChatContextCompactBoundary(
                    id: "episode-\(episode.id)",
                    afterMessageId: anchor,
                    coveredMessageIds: [],
                    state: ChatContextCompactState(
                        status: .completed,
                        summary: episode.summary,
                        updatedAt: Date(timeIntervalSince1970: Double(episode.sealedAtMillis) / 1_000.0),
                        customCompletedTitle: episode.sealReason.timelineDividerTitle
                    ),
                    isEpisodeBoundary: true
                )
            )
        }
        return boundaries
    }

    // MARK: - Cleanup & Persistence

    func remove(conversationIds: [String]) {
        let keys = conversationIds.compactMap(normalizedKey)
        guard !keys.isEmpty else { return }
        for key in keys {
            cache[key] = nil
            loadedConversationIds.remove(key)
        }
        mutationRevision &+= 1
        let directory = baseDirectoryURL
        let fileURLs = keys.map { Self.fileURL(for: $0, in: directory) }
        ioQueue.async {
            for url in fileURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Waits for any pending background disk writes to complete (used in deterministic unit tests).
    func flushPendingWritesForTesting() async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume()
            }
        }
    }

    // MARK: - Effective Q&A Turn Counting

    /// Counts substantive user -> assistant exchanges within an Episode slice.
    static func countEffectiveTurns(in messages: [UIMessage]) -> Int {
        var awaitingAssistantForTurn = false
        var completedTurns = 0

        for message in messages {
            if message.role == MessageRole.system
                || IOSOrchestrationConfigurationCodec.isOrchestrationConfigurationMessage(message) {
                continue
            }
            if message.role == MessageRole.user {
                if ChatMessageProjector.isSubAgentResult(message) {
                    continue
                }
                let kind = IosMailboxMessageBridge.shared.kind(message: message)
                if kind == "MESSAGE" {
                    continue
                }
                if hasMeaningfulUserContent(message) {
                    awaitingAssistantForTurn = true
                }
            } else if message.role == MessageRole.assistant, awaitingAssistantForTurn {
                if hasMeaningfulAssistantContent(message) {
                    completedTurns += 1
                    awaitingAssistantForTurn = false
                }
            }
        }
        return completedTurns
    }

    private static func hasMeaningfulUserContent(_ message: UIMessage) -> Bool {
        if !message.toText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return message.parts.contains {
            $0 is UIMessagePart.Image || $0 is UIMessagePart.Audio
                || $0 is UIMessagePart.Video || $0 is UIMessagePart.Document
        }
    }

    private static func hasMeaningfulAssistantContent(_ message: UIMessage) -> Bool {
        for part in message.parts {
            if let text = part as? UIMessagePart.Text,
               !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            if let tool = part as? UIMessagePart.Tool, !tool.output.isEmpty {
                return true
            }
            if part is UIMessagePart.Image {
                return true
            }
        }
        return false
    }

    // MARK: - Internal Storage Helpers

    private func normalizedKey(_ conversationId: String?) -> String? {
        guard let raw = conversationId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func ledger(for key: String) -> ChatEpisodeLedger {
        if let cached = cache[key] {
            return cached
        }
        if loadedConversationIds.contains(key) {
            let empty = ChatEpisodeLedger(conversationId: key)
            cache[key] = empty
            return empty
        }
        loadedConversationIds.insert(key)
        let url = Self.fileURL(for: key, in: baseDirectoryURL)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ChatEpisodeLedger.self, from: data) {
            cache[key] = decoded
            return decoded
        }
        let fresh = ChatEpisodeLedger(conversationId: key)
        cache[key] = fresh
        return fresh
    }

    private func saveLedger(_ ledger: ChatEpisodeLedger) {
        let key = ledger.conversationId
        cache[key] = ledger
        loadedConversationIds.insert(key)
        let directory = baseDirectoryURL
        let url = Self.fileURL(for: key, in: directory)
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(ledger)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[AmberEpisode] Failed to persist episode ledger for %@: %@", key, error.localizedDescription)
            }
        }
    }

    nonisolated private static func fileURL(for key: String, in directory: URL) -> URL {
        let safeName = key.replacingOccurrences(
            of: #"[^a-zA-Z0-9_-]"#,
            with: "_",
            options: .regularExpression
        )
        return directory.appendingPathComponent("\(safeName).json", isDirectory: false)
    }
}
