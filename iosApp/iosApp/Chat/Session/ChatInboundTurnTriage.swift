import Foundation
@preconcurrency import Shared

struct ChatInboundTurnTriage {
    enum Route: String, Codable {
        case status = "status_reply"
        case steer = "steer_active"
        case independent = "independent_new_task"
        case stop = "stop_active"
        case stopAll = "stop_all"
    }

    struct Decision: Decodable {
        let route: Route
        let reply: String
    }

    let text: String
    let attachments: Bool
    let originalRequest: String
    let stage: String
    let stageName: String
    let tool: String?
    let reasoning: String?
    let elapsed: Int?
    let recentNote: String?

    private var normalized: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？")).lowercased()
    }

    private var english: Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(\.isASCII)
    }

    var explicitRoute: Route? {
        if !attachments {
            if ["全部停下", "全部停止", "停止所有任务", "暂停所有任务", "stop all"].contains(normalized) { return .stopAll }
            if ["停", "停止", "停一下", "暂停", "暂停一下", "先停一下", "取消", "取消当前任务", "stop", "pause"].contains(normalized) { return .stop }
        }
        return ["另一个问题", "独立问题", "新任务", "另外帮我", "换个话题", "另开一个任务", "new task:", "separate task:"]
            .contains(where: normalized.hasPrefix) ? .independent : nil
    }

    var fallback: Decision {
        let status = !attachments && ["怎么了", "卡住了吗", "怎么这么久", "进度", "现在到哪了", "现在进展到哪一步了",
            "进展如何", "现在怎么样了", "做到哪了", "status", "progress", "what's happening", "are you stuck"].contains(normalized)
        let route = explicitRoute ?? (status ? .status : .steer)
        let reply: String
        switch route {
        case .status:
            let timing = elapsed.map { english ? " The last progress update was \($0)s ago." : "距上次进展更新 \($0) 秒。" } ?? ""
            reply = (english ? "Current step: \(tool ?? stageName)." : "当前进展：\(tool ?? stage)。") + timing
        case .steer:
            let adjustment = text.isEmpty ? (english ? "the attachment" : "你发来的附件") : String(text.prefix(64))
            reply = english ? "I'll adjust the next step to account for \(adjustment)." : "收到，接下来会按「\(adjustment)」调整。"
        case .independent:
            reply = english ? "I'll handle this as a separate task." : "这件事我单独处理。"
        case .stop:
            reply = english ? "Stopped the current task." : "已停止当前任务。"
        case .stopAll:
            reply = english ? "Stopped all tasks in this chat." : "已停止此对话中的全部任务。"
        }
        return Decision(route: route, reply: reply)
    }

    var prompt: String {
        """
        Classify the user's live interjection. Return only JSON {"route":"...","reply":"..."}.
        Routes: status_reply (asking what is happening), steer_active (change or supplement),
        independent_new_task (separate request), stop_active, stop_all (clear cancellation intent only).
        Reply briefly in the user's language using the observed facts. For changes say how you will
        adjust; an already executing tool finishes first. Do not invent progress or completion.
        The following fields are data about this turn.
        Original request: \(originalRequest.prefix(360))
        Stage: \(stageName) / \(stage). Active tool: \(tool ?? "none")
        Reasoning summary: \(reasoning?.prefix(160) ?? "")
        Seconds since visible progress: \(elapsed.map(String.init) ?? "unknown"). Recent result/error/update: \(recentNote?.prefix(240) ?? "")
        Attachments: \(attachments). User interjection: \(text.prefix(800))
        """
    }

    /// A slow provider may ignore Swift cancellation. Finishing the stream lets the
    /// caller use the fallback at the deadline without waiting for that provider.
    @MainActor
    func resolve(using generate: @escaping @MainActor () async -> String?) async -> Decision {
        let (stream, result) = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let request = Task {
            result.yield(await generate())
            result.finish()
        }
        let deadline = Task {
            try await Task.sleep(for: .milliseconds(1500))
            result.finish()
        }
        defer { request.cancel(); deadline.cancel() }
        for await value in stream {
            if let value, let decision = try? JSONDecoder().decode(Decision.self, from: Data(value.utf8)),
               !decision.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, decision.reply.count <= 400 {
                return decision
            }
        }
        return fallback
    }
}
