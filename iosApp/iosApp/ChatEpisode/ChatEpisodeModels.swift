import Foundation
@preconcurrency import Shared

/// Reason why an active single-stream topic window was sealed into an archived Episode.
enum ChatEpisodeSealReason: String, Codable, Equatable, Sendable {
    /// User explicitly tapped `✦ 新话题` to start a clean active context window.
    case manualNewTopic = "manual_new_topic"
    /// User sent a new message more than 3 hours (`10800s`) after the prior message.
    case idleTimeout = "idle_timeout"

    var timelineDividerTitle: String {
        switch self {
        case .manualNewTopic, .idleTimeout:
            return "✦ 新话题 · 前序重点已归档"
        }
    }
}

/// Lifecycle state of the silent background distillation pass for a sealed Episode.
enum ChatEpisodeDistillationStatus: String, Codable, Equatable, Sendable {
    /// Skipped because the Episode had fewer than 2 substantive Q&A turns.
    case skippedShort = "skipped_short"
    /// Eligible (`>= 2` Q&A turns) and queued/running in background.
    case pending = "pending"
    /// Completed using deterministic local extraction / fallback.
    case completedDeterministic = "completed_deterministic"
    /// Completed using lightweight background model refinement + deduplication.
    case completedModel = "completed_model"
}

/// Durable metadata for one archived topic segment (`Episode`) inside a single-stream conversation.
/// Full verbatim `UIMessage` rows remain in `IOSConversationStore` for smooth scrolling and `episode_recall`.
struct ChatEpisodeRecord: Codable, Equatable, Identifiable, Sendable {
    /// Sequential per-conversation identifier (e.g., `ep_0001`, `ep_0012`).
    let id: String
    let conversationId: String
    let ordinal: Int
    /// Last visible timeline message ID covered by this Episode; anchors the lightweight timeline divider.
    var afterMessageId: String
    let startMessageId: String
    let endMessageId: String
    /// Ordered non-system message IDs belonging to this Episode.
    let messageIds: [String]
    /// Number of completed user-assistant Q&A exchanges in this Episode.
    let turnCount: Int
    let startedAtMillis: Int64
    let sealedAtMillis: Int64
    let sealReason: ChatEpisodeSealReason
    /// Short topic title (`<= 18` chars), e.g., `"Santiago 抚养费争点"`.
    var title: String
    /// High-density 1-line digest preserving key entities, numbers, conclusions, and action items.
    var summary: String
    var distillationStatus: ChatEpisodeDistillationStatus

    static func formatEpisodeId(ordinal: Int) -> String {
        String(format: "ep_%04d", max(1, ordinal))
    }

    var minimumSubstantiveTurnsMet: Bool {
        turnCount >= ChatEpisodeConstants.minTurnsForBackgroundDistillation
    }

    /// Formats `MM-dd HH:mm` in local wall-clock time for the `Recent Episodes Index`.
    func formattedTimestamp(calendar: Calendar = .current) -> String {
        let referenceMillis = sealedAtMillis > 0 ? sealedAtMillis : startedAtMillis
        guard referenceMillis > 0 else { return "近期" }
        let date = Date(timeIntervalSince1970: Double(referenceMillis) / 1_000.0)
        let components = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(
            format: "%02d-%02d %02d:%02d",
            components.month ?? 1,
            components.day ?? 1,
            components.hour ?? 0,
            components.minute ?? 0
        )
    }

    /// Single-line index entry: `- [ep_0012 · 11-04 07:25] 标题：摘要`
    func indexLine(maxSummaryChars: Int = ChatEpisodeConstants.defaultIndexSummaryMaxChars) -> String {
        let stamp = formattedTimestamp()
        let cleanTitle = ChatEpisodeTextNormalizer.singleLine(title, maxChars: ChatEpisodeConstants.maxTitleChars)
        let cleanSummary = ChatEpisodeTextNormalizer.singleLine(summary, maxChars: maxSummaryChars)
        let body: String
        if cleanTitle.isEmpty {
            body = cleanSummary.isEmpty ? "已归档历史片段" : cleanSummary
        } else if cleanSummary.isEmpty || cleanSummary == cleanTitle {
            body = cleanTitle
        } else if cleanSummary.hasPrefix(cleanTitle) {
            body = cleanSummary
        } else {
            body = "\(cleanTitle)：\(cleanSummary)"
        }
        return "- [\(id) · \(stamp)] \(body)"
    }
}

/// Per-conversation sidecar ledger persisted under `Documents/conversation-episodes/{conversationId}.json`.
struct ChatEpisodeLedger: Codable, Equatable, Sendable {
    var version: Int = 1
    let conversationId: String
    var nextOrdinal: Int
    var episodes: [ChatEpisodeRecord]
    /// Exact epoch-millisecond timestamps recorded when messages are appended/completed.
    var messageTimestampsMillis: [String: Int64]

    init(
        conversationId: String,
        nextOrdinal: Int = 1,
        episodes: [ChatEpisodeRecord] = [],
        messageTimestampsMillis: [String: Int64] = [:]
    ) {
        self.version = 1
        self.conversationId = conversationId
        self.nextOrdinal = max(1, nextOrdinal)
        self.episodes = episodes
        self.messageTimestampsMillis = messageTimestampsMillis
    }
}

enum ChatEpisodeConstants {
    /// Automatic Episode split threshold: 3 hours (`10800` seconds).
    static let idleTimeoutSeconds: TimeInterval = 3 * 3_600
    static let idleTimeoutMillis: Int64 = Int64(idleTimeoutSeconds * 1_000)
    /// Minimum substantive Q&A exchanges required to trigger background memory distillation.
    static let minTurnsForBackgroundDistillation: Int = 2
    /// Maximum number of most recent sealed Episodes surfaced in the resident system prompt index.
    static let maxRecentEpisodesInIndex: Int = 8
    /// Strict token ceiling for the resident `Recent Episodes Index` block.
    static let maxRecentEpisodesIndexTokens: Int = 300
    static let maxTitleChars: Int = 18
    static let defaultIndexSummaryMaxChars: Int = 56
    static let recallToolName: String = "episode_recall"
}

enum ChatEpisodeTextNormalizer {
    static func singleLine(_ raw: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let redacted = IOSContextCompactionFidelity.redactCredentials(raw)
        let collapsed = redacted
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxChars else { return collapsed }
        if maxChars <= 1 {
            return String(collapsed.prefix(maxChars))
        }
        return String(collapsed.prefix(maxChars - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Converts a KMP `Kotlinx_datetimeLocalDateTime` (stored in local device wall-clock time) to epoch millis.
    static func epochMillis(from localDateTime: Kotlinx_datetimeLocalDateTime, calendar: Calendar = .current) -> Int64? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = Int(localDateTime.year)
        components.month = Int(localDateTime.month.ordinal) + 1
        components.day = Int(localDateTime.day)
        components.hour = Int(localDateTime.hour)
        components.minute = Int(localDateTime.minute)
        components.second = Int(localDateTime.second)
        components.nanosecond = Int(localDateTime.nanosecond)
        guard let date = calendar.date(from: components) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1_000.0)
    }

    static func mailboxBody(of message: UIMessage) -> String? {
        let bridge = IosMailboxMessageBridge.shared
        let rendered = message.parts
            .compactMap { $0 as? UIMessagePart.Text }
            .map { bridge.displayText(part: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return rendered.isEmpty ? nil : rendered
    }

    static func searchTokens(in text: String) -> Set<String> {
        let lowered = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"[a-z0-9_.\-]{2,}|[\u4e00-\u9fff]{2,}"#) else {
            return []
        }
        let nsRange = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        var tokens = Set<String>()
        for match in regex.matches(in: lowered, range: nsRange) {
            guard let range = Range(match.range, in: lowered) else { continue }
            let chunk = String(lowered[range])
            if chunk.unicodeScalars.first.map({ $0.value >= 0x4E00 && $0.value <= 0x9FFF }) == true {
                let chars = Array(chunk)
                if chars.count <= 3 {
                    tokens.insert(chunk)
                } else {
                    for idx in 0..<(chars.count - 1) {
                        tokens.insert(String([chars[idx], chars[idx + 1]]))
                    }
                }
            } else {
                tokens.insert(chunk)
            }
        }
        return tokens
    }
}
