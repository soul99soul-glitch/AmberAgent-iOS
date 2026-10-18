import Foundation
@preconcurrency import Shared

enum IOSCouncilRoomRunMode: String, Codable, Equatable {
    case freeChat = "free_chat"
    case debate
}

enum IOSCouncilResearchConsent: String, Codable, Equatable {
    case allowed
    case denied
    case unavailable
}

struct IOSCouncilRoomSpeaker: Equatable, Identifiable {
    let id: String
    let name: String
    let rolePrompt: String
    let modelId: String
    let providerId: String?
    let reasoning: IOSCouncilReasoningPreset
    let prompt: String
    let isHost: Bool

    init(
        id: String,
        name: String,
        rolePrompt: String,
        modelId: String,
        providerId: String? = nil,
        reasoning: IOSCouncilReasoningPreset,
        prompt: String,
        isHost: Bool
    ) {
        self.id = id
        self.name = name
        self.rolePrompt = rolePrompt
        self.modelId = modelId
        self.providerId = providerId?.trimmedNilIfBlank
        self.reasoning = reasoning
        self.prompt = prompt
        self.isHost = isHost
    }

    var shortLens: String {
        rolePrompt.components(separatedBy: "，").first?.trimmedNilIfBlank ?? rolePrompt
    }
}

struct IOSCouncilModelRouteDescriptor: Equatable {
    let providerId: String
    let modelId: String
}

enum IOSCouncilRoomMessageKind: Equatable {
    case host
    case seat
    case system
    case divider
}

enum IOSCouncilRoomMessageStatus: Equatable {
    case speaking
    case completed
    case failed
}

struct IOSCouncilRoomMessageEvent: Equatable, Identifiable {
    let id: UUID
    let kind: IOSCouncilRoomMessageKind
    let speakerId: String?
    let author: String
    let body: String
    let subtitle: String?
    let status: IOSCouncilRoomMessageStatus
}

enum IOSCouncilRoomEvent: Equatable {
    case taskStarted(String)
    case state(String)
    case roster([IOSCouncilRoomSpeaker], activeSpeakerId: String?, failedSpeakerIds: Set<String>)
    case append(IOSCouncilRoomMessageEvent)
    /// `lagAllowance`：流式拍恒为 1；终态排空拍随剩余积压连续衰减到 0。
    /// 视图层据此提交 `streamContentGrew(lagAllowance:)`（同 Chat/小说语义）。
    case updateMessage(id: UUID, body: String, status: IOSCouncilRoomMessageStatus, lagAllowance: CGFloat)
}

struct IOSCouncilRoomContinuation {
    let taskId: String
    let originalObjective: String
    let finalTopic: String
    let priorTranscript: String
    let speakers: [IOSCouncilRoomSpeaker]
    let nextRound: Int
}

struct IOSCouncilRoomRunRequest {
    var taskId: String? = nil
    let objective: String
    let mode: IOSCouncilRoomRunMode
    let settings: IOSCouncilRoomSettings
    let currentModelId: String
    var currentModel: Model? = nil
    var baseParams: TextGenerationParams? = nil
    let providerSetting: ProviderSetting
    var providerSettings: [ProviderSetting] = []
    let searchSettings: Settings?
    let researchConsent: IOSCouncilResearchConsent
    /// 开:主持人按议题自由动态生成席位;关:只用 settings.seats 里已添加的席位。
    var dynamicSeatGeneration: Bool = false
    /// 开:每位席位发言前先联网查证一轮,把材料注入其发言 prompt(治 grok 等模型
    /// 「想搜却无工具」而幻觉出 web_search 文本);关:席位纯推理。仍需 researchConsent
    /// 为 allowed(全局联网开关)才真正联网,且追问(continuation)不查以控成本。
    var seatWebSearch: Bool = false
    /// 非 nil 时沿用同一议会任务、席位与既有转录，只追加一轮追问讨论。
    var continuation: IOSCouncilRoomContinuation? = nil
    /// 用户上传文件/图片解析后的文本材料（仅首轮议题完善使用；追问不重复注入）。
    var sourceMaterials: String? = nil
    /// 联网调研用的议题文案；缺省时回退 `objective`。可含材料摘要以提升检索相关性。
    var researchObjective: String? = nil
}

struct IOSCouncilRoomRunSummary: Equatable {
    let taskId: String
    let status: IOSAdvancedTaskStatus
    let finalTopic: String
    let finalAnswer: String
    let failureReason: String?
    let seatNames: [String]
    let failedSeats: [String]
    let transcript: String
}

struct IOSCouncilScrapedPage: Equatable {
    let url: String
    let content: String
}

struct IOSCouncilResearchBundle: Equatable {
    var searches: [IOSSearchExecution]
    var scrapedPages: [IOSCouncilScrapedPage]
    var failures: [String]

    static func == (lhs: IOSCouncilResearchBundle, rhs: IOSCouncilResearchBundle) -> Bool {
        lhs.searches == rhs.searches
            && lhs.scrapedPages.map { [$0.url, $0.content] } == rhs.scrapedPages.map { [$0.url, $0.content] }
            && lhs.failures == rhs.failures
    }

    var isEmpty: Bool {
        searches.isEmpty && scrapedPages.isEmpty && failures.isEmpty
    }

    var summaryText: String {
        var lines: [String] = []
        for execution in searches {
            lines.append("Search: \(execution.request.query)")
            for result in execution.results.prefix(5) {
                lines.append("- \(result.title): \(result.url)\n  \(result.snippet)")
            }
        }
        for page in scrapedPages {
            lines.append("Scrape: \(page.url)\n\(page.content)")
        }
        if !failures.isEmpty {
            lines.append("Research failures:\n" + failures.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n\n")
    }
}

private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    var trimmedNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

