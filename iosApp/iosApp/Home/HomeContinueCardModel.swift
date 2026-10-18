import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

struct HomeNovelProjectRef: Equatable {
    let id: NovelProjectID
    let name: String
    let updatedAt: Date
    let isDegraded: Bool
    let isRunning: Bool

    init(
        id: NovelProjectID,
        name: String,
        updatedAt: Date,
        isDegraded: Bool,
        isRunning: Bool = false
    ) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.isDegraded = isDegraded
        self.isRunning = isRunning
    }

    init(_ summary: NovelProjectSummary) {
        id = summary.id
        name = summary.name
        updatedAt = summary.updatedAt
        isDegraded = summary.isDegraded
        isRunning = summary.hasRunningRun
    }
}

struct HomeCouncilTaskRef: Equatable {
    let id: String
    let title: String
    let status: IOSAdvancedTaskStatus
    let updatedAt: Date
    let canContinue: Bool

    init(
        id: String,
        title: String,
        status: IOSAdvancedTaskStatus,
        updatedAt: Date,
        canContinue: Bool
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.canContinue = canContinue
    }

    init(_ context: CouncilHomeResumeContext) {
        id = context.id
        title = context.title
        status = context.status
        updatedAt = context.updatedAt
        canContinue = context.canContinue
    }
}

struct HomeDeepReadTaskRef: Equatable {
    let id: String
    let title: String
    let status: IOSDeepReadTaskStatus
    let updatedAt: Date
    let workspaceSyncFailed: String?

    init(
        id: String,
        title: String,
        status: IOSDeepReadTaskStatus,
        updatedAt: Date,
        workspaceSyncFailed: String?
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.workspaceSyncFailed = workspaceSyncFailed
    }

    init(_ task: IOSDeepReadTask) {
        id = task.id
        title = task.title
        status = task.status
        updatedAt = Date(timeIntervalSince1970: TimeInterval(task.updatedAt) / 1_000)
        workspaceSyncFailed = task.workspaceSyncFailed
    }
}

struct HomeMiniAppRef: Equatable {
    let id: String
    let title: String
    let latestVersionCreatedAt: Date
    let lastRunAt: Date?
}

struct HomeImageGenerationRef: Equatable {
    let id: String
    let conversationID: String
    let messageID: String
    let toolCallID: String
    let prompt: String
    let state: ChatImageGenerationResumeState
    let updatedAt: Date

    init(
        id: String,
        conversationID: String,
        messageID: String,
        toolCallID: String,
        prompt: String,
        state: ChatImageGenerationResumeState,
        updatedAt: Date
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.toolCallID = toolCallID
        self.prompt = prompt
        self.state = state
        self.updatedAt = updatedAt
    }

    init(_ context: ChatImageGenerationResumeContext) {
        id = context.id
        conversationID = context.conversationID
        messageID = context.messageID
        toolCallID = context.toolCallID
        prompt = context.prompt
        state = context.state
        updatedAt = context.updatedAt
    }
}

/// 首页按压态 ButtonStyle：scale 回弹 + 把 isPressed 通过 Binding 回传，
/// 让行内容可以成对切换按压垫底/前景（设计 §5：hover/按压前景背景成对定义）。
struct HomeContinueCardModel: Equatable {
    enum Feature: Equatable {
        case deepRead
        case novel
        case council
        case miniApp
        case imageGeneration

        var icon: HomePhosphor {
            switch self {
            case .deepRead: .bookOpen
            case .novel: .notebook
            case .council: .chatCircleDots
            case .miniApp: .squaresFour
            case .imageGeneration: .imageSquare
            }
        }
    }

    enum Destination: Equatable {
        case openCouncil
        case deepReadTask(String)
        case resumeProject(NovelProjectID)
        case miniAppRunner(String)
        case generatedImage(ChatMessageAnchor)
    }

    private enum Priority: Int {
        case draft = 1
        case readyResult = 2
        case recoverable = 3
        case active = 4
        case actionRequired = 5
    }

    private struct Candidate {
        let stableID: String
        let priority: Priority
        let updatedAt: Date
        let model: HomeContinueCardModel
    }

    let feature: Feature
    let title: String
    let meta: String
    let ctaTitle: String
    let destination: Destination

    static func resolve(
        novelProjects: [HomeNovelProjectRef] = [],
        councilTask: HomeCouncilTaskRef? = nil,
        deepReadTasks: [HomeDeepReadTaskRef] = [],
        miniApps: [HomeMiniAppRef] = [],
        imageGeneration: HomeImageGenerationRef? = nil,
        now: Date = Date()
    ) -> HomeContinueCardModel? {
        let locale = IOSAppLanguagePreference.selected().resolvedLocale()
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated

        var candidates = novelProjects.compactMap { project -> Candidate? in
            guard !project.isDegraded else { return nil }
            let state = project.isRunning ? localized("生成中") : formatter.localizedString(
                for: project.updatedAt,
                relativeTo: now
            )
            return Candidate(
                stableID: "novel:\(project.id)",
                priority: project.isRunning ? .active : .draft,
                updatedAt: project.updatedAt,
                model: .init(
                    feature: .novel,
                    // 书名作首行：功能名已在下方快捷入口出现，这里只作副信息。
                    title: formatted("《%@》", arguments: [project.name]),
                    meta: formatted("%@ · %@", arguments: [localized("小说创作"), state]),
                    ctaTitle: localized(project.isRunning ? "查看" : "继续"),
                    destination: .resumeProject(project.id)
                )
            )
        }

        if let councilTask,
           let priority = councilPriority(for: councilTask) {
            let state = councilStateTitle(for: councilTask)
            candidates.append(Candidate(
                stableID: "council:\(councilTask.id)",
                priority: priority,
                updatedAt: councilTask.updatedAt,
                model: .init(
                    feature: .council,
                    title: localized("模型议会"),
                    meta: formatted("%@ · %@", arguments: [councilTask.title, state]),
                    ctaTitle: localized(
                        priority == .actionRequired ? "处理" : (priority == .active ? "查看" : "继续")
                    ),
                    destination: .openCouncil
                )
            ))
        }

        candidates.append(contentsOf: deepReadTasks.compactMap { task -> Candidate? in
            let priority: Priority
            let state: String
            let ctaTitle: String
            if task.status == .succeeded, task.workspaceSyncFailed != nil {
                priority = .actionRequired
                state = localized("Workspace 同步失败")
                ctaTitle = localized("处理")
            } else {
                switch task.status {
                case .queued, .running:
                    priority = .active
                    state = localized(task.status.title)
                    ctaTitle = localized("查看")
                case .failed, .unsupported:
                    priority = .recoverable
                    state = formatted(
                        "%@ · %@",
                        arguments: [localized(task.status.title), localized("可重试")]
                    )
                    ctaTitle = localized("查看")
                case .succeeded:
                    return nil
                }
            }
            // Primary line is the task topic so the continue card matches what
            // the user just launched — not a generic "深度阅读" label that looks
            // like a different entry after failure.
            let topic = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Candidate(
                stableID: "deep-read:\(task.id)",
                priority: priority,
                updatedAt: task.updatedAt,
                model: .init(
                    feature: .deepRead,
                    title: topic.isEmpty ? localized("深度阅读") : topic,
                    meta: formatted("%@ · %@", arguments: [localized("深度阅读"), state]),
                    ctaTitle: ctaTitle,
                    destination: .deepReadTask(task.id)
                )
            )
        })

        candidates.append(contentsOf: miniApps.compactMap { app -> Candidate? in
            if let lastRunAt = app.lastRunAt,
               app.latestVersionCreatedAt <= lastRunAt {
                return nil
            }
            let state = app.lastRunAt == nil
                ? localized("已生成，尚未打开")
                : localized("新版本尚未打开")
            return Candidate(
                stableID: "mini-app:\(app.id)",
                priority: .draft,
                updatedAt: app.latestVersionCreatedAt,
                model: .init(
                    feature: .miniApp,
                    title: localized("小应用"),
                    meta: formatted("%@ · %@", arguments: ["「\(app.title)」", state]),
                    ctaTitle: localized("打开"),
                    destination: .miniAppRunner(app.id)
                )
            )
        })

        if let imageGeneration {
            let isCompleted = imageGeneration.state == .completed
            let prompt = imageGeneration.prompt.isEmpty ? "未命名图片" : imageGeneration.prompt
            let state = localized(isCompleted ? "图片已生成" : "正在生成图片")
            candidates.append(Candidate(
                stableID: "image:\(imageGeneration.id)",
                priority: isCompleted ? .readyResult : .active,
                updatedAt: imageGeneration.updatedAt,
                model: .init(
                    feature: .imageGeneration,
                    title: localized("AI 生图"),
                    meta: formatted("%@ · %@", arguments: [state, prompt]),
                    ctaTitle: localized(isCompleted ? "查看图片" : "查看"),
                    destination: .generatedImage(
                        ChatMessageAnchor(
                            conversationID: imageGeneration.conversationID,
                            messageID: imageGeneration.messageID,
                            toolCallID: imageGeneration.toolCallID
                        )
                    )
                )
            ))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority.rawValue > rhs.priority.rawValue }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.stableID < rhs.stableID
        }.first?.model
    }

    private static func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }

    private static func formatted(_ key: String, arguments: [CVarArg]) -> String {
        IOSAppLocalization.formatted(key, defaultValue: key, arguments: arguments)
    }

    private static func councilPriority(for task: HomeCouncilTaskRef) -> Priority? {
        switch task.status {
        case .approvalRequired:
            .actionRequired
        case .queued, .running:
            .active
        case .failed, .cancelled, .timedOut, .interrupted:
            task.canContinue ? .recoverable : nil
        case .completed:
            nil
        }
    }

    private static func councilStateTitle(for task: HomeCouncilTaskRef) -> String {
        switch task.status {
        case .failed, .cancelled, .timedOut, .interrupted:
            formatted(
                "%@ · %@",
                arguments: [localized(task.status.title), localized("可继续")]
            )
        default:
            localized(task.status.title)
        }
    }
}
