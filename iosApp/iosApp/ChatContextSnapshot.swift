import Foundation
@preconcurrency import Shared

struct ChatContextUsageMetrics: Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var cachedTokens: Int = 0
    var currentContextTokens: Int = 0
    var tokensPerSecond: Double?

    /// Last completed assistant turn. Occupancy for the ring is computed separately.
    static func lastAssistantTurn(in messages: [UIMessage]) -> ChatContextUsageMetrics {
        guard let message = messages.last(where: { message in
            guard message.role == MessageRole.assistant, let usage = message.usage else {
                return false
            }
            return usage.promptTokens > 0 || usage.completionTokens > 0 || usage.cachedTokens > 0
        }), let usage = message.usage else {
            return ChatContextUsageMetrics()
        }

        let prompt = Int(usage.promptTokens)
        let completion = Int(usage.completionTokens)
        let decodeSeconds: TimeInterval?
        if usage.generationDurationMs > 0 {
            decodeSeconds = Double(usage.generationDurationMs) / 1000.0
        } else {
            decodeSeconds = ChatContextSnapshot.durationSeconds(from: message.createdAt, to: message.finishedAt)
        }
        return ChatContextUsageMetrics(
            promptTokens: prompt,
            completionTokens: completion,
            cachedTokens: Int(usage.cachedTokens),
            currentContextTokens: prompt,
            tokensPerSecond: {
                guard let decodeSeconds, decodeSeconds > 0, completion > 0 else { return nil }
                return Double(completion) / decodeSeconds
            }()
        )
    }
}

struct ChatContextSnapshot {
    let messageCount: Int
    let modelId: String
    let supportsReasoning: Bool
    let pendingSelectedFileName: String?
    let pendingSelectedFileBytesText: String?
    /// Last assistant turn. 0 when no usage has been recorded yet.
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int
    let tokensPerSecond: Double?
    /// Resolved context window: explicit model setting, then ModelRegistry.
    let contextWindowTokens: Int?
    /// Next-turn load estimate: last fresh prompt+completion, or a compact-aware
    /// estimate plus the current draft/attachments.
    let currentContextTokens: Int
}

enum ChatContextCompactStatus: Equatable {
    case idle
    case planning
    case compacting
    case completed
    case failed
}

struct ChatContextCompactState: Equatable {
    var status: ChatContextCompactStatus
    var summary: String
    var updatedAt: Date

    static let idle = ChatContextCompactState(status: .idle, summary: "", updatedAt: Date.distantPast)

    var isActive: Bool {
        status == .planning || status == .compacting
    }

    var isVisible: Bool {
        isActive || status == .completed || status == .failed
    }
}

struct ChatContextCompactBoundary: Equatable, Identifiable {
    let id: String
    let afterMessageId: String
    let coveredMessageIds: Set<String>
    let state: ChatContextCompactState
}

extension ChatContextSnapshot {
    /// Fallback only when the model and registry both omit a window.
    static let defaultContextWindowTokens: Double = 200_000

    /// 上下文用量比例 [0,1]。分子是下一轮预计装载量。
    var contextFillFraction: CGFloat {
        let ceiling = Double(resolvedWindowTokens)
        guard ceiling > 0 else { return 0 }
        return min(CGFloat(Double(max(currentContextTokens, 0)) / ceiling), 1.0)
    }

    var occupancyText: String {
        "\(Self.formatTokenCount(currentContextTokens)) / \(Self.formatTokenCount(resolvedWindowTokens))"
    }

    var cacheHitRateText: String {
        guard promptTokens > 0, cachedTokens > 0 else { return "—" }
        let percent = (Double(cachedTokens) / Double(promptTokens) * 100).rounded()
        return "\(Int(min(max(percent, 0), 100)))%"
    }

    var speedText: String {
        guard let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond > 0 else {
            return "暂无"
        }
        return String(format: "%.1f token/s", tokensPerSecond)
    }

    var resolvedWindowTokens: Int {
        contextWindowTokens.flatMap { $0 > 0 ? $0 : nil } ?? Int(Self.defaultContextWindowTokens)
    }

    static func formatTokenCount(_ tokens: Int) -> String {
        ComposerProviderGroup.formatContextWindow(max(tokens, 0))
    }

    static func resolvedContextWindowTokens(modelWindow: Int?, modelId: String) -> Int? {
        if let modelWindow, modelWindow > 0 {
            return modelWindow
        }
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let data = ModelRegistry.shared.MODEL_CONTEXT_WINDOW.getData(modelId: trimmed)
        if let value = data as? KotlinInt {
            let tokens = Int(truncating: value)
            return tokens > 0 ? tokens : nil
        }
        if let value = data as? Int, value > 0 {
            return value
        }
        if let value = data as? NSNumber {
            let tokens = value.intValue
            return tokens > 0 ? tokens : nil
        }
        return nil
    }

    static func epochMillis(from localDateTime: Kotlinx_datetimeLocalDateTime) -> Int64? {
        guard let date = date(from: localDateTime) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    static func durationSeconds(
        from start: Kotlinx_datetimeLocalDateTime,
        to end: Kotlinx_datetimeLocalDateTime?
    ) -> TimeInterval? {
        guard let end,
              let startDate = date(from: start),
              let endDate = date(from: end) else {
            return nil
        }
        let duration = endDate.timeIntervalSince(startDate)
        return duration > 0 ? duration : nil
    }

    private static func date(from localDateTime: Kotlinx_datetimeLocalDateTime) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = Int(localDateTime.year)
        components.month = Int(localDateTime.month.ordinal) + 1
        components.day = Int(localDateTime.day)
        components.hour = Int(localDateTime.hour)
        components.minute = Int(localDateTime.minute)
        components.second = Int(localDateTime.second)
        components.nanosecond = Int(localDateTime.nanosecond)
        return components.date
    }
}
