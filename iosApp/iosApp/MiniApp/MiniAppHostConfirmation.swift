import SwiftUI

enum MiniAppRunnerPrompt: Identifiable, Equatable {
    case host(MiniAppHostConfirmation)
    case grant(MiniAppPermissionGrantPrompt)
    case system(MiniAppSystemConfirmation)

    var id: UUID {
        switch self {
        case .host(let value): value.id
        case .grant(let value): value.id
        case .system(let value): value.id
        }
    }

    var title: String {
        switch self {
        case .host(let value): value.title
        case .grant(let value): value.title
        case .system(let value): value.title
        }
    }

    var message: String {
        switch self {
        case .host(let value): value.message
        case .grant(let value): value.message
        case .system(let value): value.message
        }
    }
}

struct MiniAppSystemConfirmation: Equatable {
    let id = UUID()
    let title: String
    let message: String
}

struct MiniAppHostConfirmation: Equatable {
    let id = UUID()
    let appTitle: String
    let request: IOSMiniAppHostRequest

    var title: String {
        let key: String
        switch request {
        case .getConversationContext:
            key = "允许读取上下文？"
        case .sendToConversation:
            key = "允许写回聊天草稿？"
        case .createArtifact:
            key = "允许创建内容卡片？"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }

    var message: String {
        switch request {
        case .getConversationContext(let request):
            return IOSAppLocalization.formatted(
                "「%@」想读取最小化会话上下文，最多 %lld 字。完整聊天记录、系统提示词、provider 设置、凭证和隐藏工具输出不会暴露。",
                defaultValue: "「%@」想读取最小化会话上下文，最多 %lld 字。完整聊天记录、系统提示词、provider 设置、凭证和隐藏工具输出不会暴露。",
                arguments: [appTitle, Int64(request.maxChars)]
            )
        case .sendToConversation(let request):
            let actionKey = request.mode == "insert"
                ? "追加到当前聊天输入框"
                : "替换当前聊天输入框草稿"
            let action = IOSAppLocalization.string(actionKey, defaultValue: actionKey)
            return IOSAppLocalization.formatted(
                "「%@」想%@：\n\n%@",
                defaultValue: "「%@」想%@：\n\n%@",
                arguments: [appTitle, action, request.text.truncated(to: 300)]
            )
        case .createArtifact(let request):
            return IOSAppLocalization.formatted(
                "%@\n\n%@",
                defaultValue: "%@\n\n%@",
                arguments: [request.title, request.content.truncated(to: 260)]
            )
        }
    }
}

struct MiniAppPermissionGrantPrompt: Equatable {
    let id = UUID()
    let appTitle: String
    let permission: IOSMiniAppPermission

    var title: String {
        let nameKey = Self.displayName(permission)
        let name = IOSAppLocalization.string(nameKey, defaultValue: nameKey)
        return IOSAppLocalization.formatted(
            "允许%@？",
            defaultValue: "允许%@？",
            arguments: [name]
        )
    }

    var message: String {
        let descriptionKey = Self.displayDescription(permission)
        let description = IOSAppLocalization.string(descriptionKey, defaultValue: descriptionKey)
        return IOSAppLocalization.formatted(
            "「%@」首次请求：%@\n允许后可继续使用，拒绝后会记住本次选择。",
            defaultValue: "「%@」首次请求：%@\n允许后可继续使用，拒绝后会记住本次选择。",
            arguments: [appTitle, description]
        )
    }

    private static func displayName(_ permission: IOSMiniAppPermission) -> String {
        switch permission {
        case .storage: "本地存储"
        case .toast: "提示"
        case .theme: "主题"
        case .network: "网络请求"
        case .search: "搜索"
        case .clipboardCopy: "写入剪贴板"
        case .aiGenerate: "调用 AI"
        case .sharedStore: "共享存储"
        case .eventBus: "事件"
        case .hostUpdateBoardSummary: "更新摘要"
        case .hostContext: "读取上下文"
        case .hostSendToConversation: "写回聊天"
        case .hostCreateArtifact: "创建内容卡片"
        case .externalImages: "外链图片"
        case .launch: "打开其他小应用"
        case .sensor: "传感器"
        case .location: "定位"
        case .clipboardRead: "读取剪贴板"
        case .haptics: "振动与触感"
        case .device: "设备与电池信息"
        case .screen: "屏幕控制"
        case .speech: "语音朗读"
        case .share: "系统分享"
        case .openURL: "打开外部链接"
        }
    }

    private static func displayDescription(_ permission: IOSMiniAppPermission) -> String {
        switch permission {
        case .storage: "读写该小应用自己的本地数据"
        case .toast: "显示提示信息"
        case .theme: "读取当前主题色"
        case .network: "访问公开 https 页面"
        case .search: "执行公开网页搜索"
        case .clipboardCopy: "把文本写入剪贴板"
        case .aiGenerate: "调用当前聊天模型生成文本"
        case .sharedStore: "读写自身命名空间的共享数据"
        case .eventBus: "在自身命名空间收发事件"
        case .hostUpdateBoardSummary: "更新该小应用的摘要字段"
        case .hostContext: "读取最小化会话上下文"
        case .hostSendToConversation: "向聊天写入草稿"
        case .hostCreateArtifact: "创建 Workspace 内容卡片"
        case .externalImages: "加载外链图片"
        case .launch: "打开另一个已保存的小应用"
        case .sensor: "订阅设备传感器"
        case .location: "读取当前位置"
        case .clipboardRead: "读取剪贴板文本"
        case .haptics: "播放短暂振动和触感反馈"
        case .device: "读取系统版本、语言、电量和无障碍偏好，不含设备标识"
        case .screen: "临时调整亮度或保持常亮，离开或进入后台时恢复"
        case .speech: "使用系统声音朗读文本，离开或进入后台时停止"
        case .share: "展示系统分享面板，由你选择分享目标并确认"
        case .openURL: "每次确认后打开网页、邮件或拨号链接"
        }
    }
}

@MainActor
final class MiniAppHostConfirmationOwner: ObservableObject {
    private struct GrantTaskEntry {
        let token: UUID
        let task: Task<Bool, Error>
    }

    @Published private(set) var pendingPrompt: MiniAppRunnerPrompt?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var grantInFlight: [String: GrantTaskEntry] = [:]
    private var presentationWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false
    private var lifecycleGeneration = 0

    var hasPendingRequest: Bool { continuation != nil }

    func request(appTitle: String, request: IOSMiniAppHostRequest) async throws -> Bool {
        guard !isClosed else {
            throw MiniAppRunnerHostError.denied("MiniApp runner is closed.")
        }
        return try await withPresentationSlot {
            try await present(.host(MiniAppHostConfirmation(appTitle: appTitle, request: request)))
        }
    }

    func requestPermission(appTitle: String, permission: IOSMiniAppPermission) async throws -> Bool {
        guard !isClosed else {
            throw MiniAppRunnerHostError.denied("MiniApp runner is closed.")
        }
        let key = permission.rawValue
        if let existing = grantInFlight[key] {
            return try await existing.task.value
        }
        let token = UUID()
        let task = Task { @MainActor in
            try await withPresentationSlot {
                try await present(.grant(MiniAppPermissionGrantPrompt(appTitle: appTitle, permission: permission)))
            }
        }
        grantInFlight[key] = GrantTaskEntry(token: token, task: task)
        defer {
            if grantInFlight[key]?.token == token {
                grantInFlight[key] = nil
            }
        }
        return try await task.value
    }

    func requestSystemAction(title: String, message: String) async throws -> Bool {
        guard !isClosed else {
            throw MiniAppRunnerHostError.denied("MiniApp runner is closed.")
        }
        return try await withPresentationSlot {
            try await present(.system(MiniAppSystemConfirmation(title: title, message: message)))
        }
    }

    func reopen() {
        guard continuation == nil else { return }
        isClosed = false
    }

    private func withPresentationSlot<T>(_ work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let requestGeneration = lifecycleGeneration
        guard !isClosed else {
            throw MiniAppRunnerHostError.denied("MiniApp runner is closed.")
        }
        while continuation != nil {
            await withCheckedContinuation { continuation in
                presentationWaiters.append(continuation)
            }
            try Task.checkCancellation()
            guard !isClosed, lifecycleGeneration == requestGeneration else {
                throw MiniAppRunnerHostError.denied("MiniApp runner is closed.")
            }
        }
        let result = try await work()
        try Task.checkCancellation()
        guard !isClosed, lifecycleGeneration == requestGeneration else {
            throw MiniAppRunnerHostError.denied("MiniApp runner is closed.")
        }
        return result
    }

    private func present(_ prompt: MiniAppRunnerPrompt) async throws -> Bool {
        try Task.checkCancellation()
        guard !isClosed else {
            throw MiniAppRunnerHostError.denied("MiniApp runner is closed.")
        }
        guard continuation == nil else {
            throw MiniAppRunnerHostError.denied("Another MiniApp host request is waiting for confirmation.")
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pendingPrompt = prompt
        }
    }

    @discardableResult
    func resolve(allow: Bool) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        pendingPrompt = nil
        continuation.resume(returning: allow)
        let waiters = presentationWaiters
        presentationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return true
    }

    @discardableResult
    func close() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        lifecycleGeneration &+= 1
        grantInFlight.values.forEach { $0.task.cancel() }
        grantInFlight.removeAll()
        return resolve(allow: false)
    }
}

enum MiniAppRunnerHostError: LocalizedError {
    case denied(String)

    var errorDescription: String? {
        if case .denied(let message) = self { return message }
        return nil
    }
}
