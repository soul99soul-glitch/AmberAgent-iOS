import SwiftUI

@MainActor
@Observable
final class RouterPath {
    private var storedPath: [Route] = []
    var presentedSheet: SheetDestination?
    /// 宽屏（iPhone Duo 展开 / iPad）双栏时，会话侧栏是否显示。
    var showsSidebar = true
    /// 侧栏浮在聊天上（Duo 内屏竖持等较窄的 regular 宽度）：选中会话后收起侧栏。
    var sidebarOverlaysDetail = false
    /// 双栏时详情栏根聊天页要定位的消息（来自 `.chatMessage` 路由）。
    private(set) var detailChatAnchor: ChatMessageAnchor?

    /// 双栏布局下聊天是详情栏根视图，路径里不再保留开头的 `.chat` / `.chatMessage`。
    /// 所有 `navigate(to: .chat)` / `path = [.chat, ...]` 调用方无需区分布局。
    var chatIsDetailRoot = false {
        didSet {
            guard chatIsDetailRoot != oldValue else { return }
            if chatIsDetailRoot {
                storedPath = absorbingChatRoot(storedPath)
            } else {
                // 合上屏幕回到单栏：把展开时可见的聊天页放回栈底，保持当前会话。
                switch storedPath.first {
                case .chat, .chatMessage(anchor: _): break
                default: storedPath.insert(detailChatAnchor.map { .chatMessage(anchor: $0) } ?? .chat, at: 0)
                }
            }
        }
    }

    var path: [Route] {
        get { storedPath }
        set { storedPath = absorbingChatRoot(newValue) }
    }

    /// 当前可见的最上层页面是否为聊天页（含双栏模式的详情栏根）。
    var isShowingChat: Bool {
        switch storedPath.last {
        case nil: return chatIsDetailRoot
        case .chat, .chatMessage(anchor: _): return true
        default: return false
        }
    }

    private func absorbingChatRoot(_ path: [Route]) -> [Route] {
        guard chatIsDetailRoot, let first = path.first else { return path }
        switch first {
        case .chat:
            detailChatAnchor = nil
        case .chatMessage(let anchor):
            detailChatAnchor = anchor
        default:
            return path
        }
        // 深链 / 合上→展开时直接落到聊天：浮层侧栏会挡住聊天，收起它。
        if sidebarOverlaysDetail { showsSidebar = false }
        return Array(path.dropFirst())
    }

    func navigate(to route: Route) {
        if chatIsDetailRoot {
            switch route {
            case .chat, .chatMessage(anchor: _):
                // 详情栏根即聊天页：回到根，而不是再压一层聊天。
                storedPath = absorbingChatRoot([route])
                return
            default:
                break
            }
        }
        // 防止快速连点堆叠重复页面
        guard path.last != route else { return }
        path.append(route)
    }

    func goBack() {
        guard !path.isEmpty else {
            // 双栏详情栏根（聊天页）没有上一页：返回键改为切换会话侧栏。
            if chatIsDetailRoot { showsSidebar.toggle() }
            return
        }
        path.removeLast()
    }

    func reset() {
        path = []
        presentedSheet = nil
    }
}

enum Route: Hashable {
    case chat
    case chatMessage(anchor: ChatMessageAnchor)
    case search(initialQuery: String)
    case account
    case settings
    case appearance
    case language
    case displayFont
    case conversationStorage
    case syncBackup
    case healthSummary
    case weather
    case appleIntegrations
    case appleWatch
    case macGateway
    case subscription
    case capabilities
    case memoryEdit(recordId: Int?, text: String, scope: String, pinned: Bool)
    case memoryDocument(relativePath: String, title: String)
    case memoryRecords
    case memoryPollutedConversations
    case skills
    case skillAdd
    case mcpServers
    case mcpImport
    case mcpAdd
    case skillDetail(name: String, dirName: String?)
    case recipes
    case recipeDetail(name: String)
    case plugins
    case pluginDetail(id: String)
    case execution
    case phoneControl
    case phoneSavedTasks
    case executionTask(id: String)
    case providers
    case providerAdd
    case providerDetail(id: String)
    case modelDefaults
    case searchServices
    case searchProvider
    case ttsSettings
    case board
    case boardSettings
    case deepReadTask(id: String)
    case miniApps
    case miniAppSettings
    case miniAppRunner(appId: String)
    case novelCreation
    case novelCreationSettings
    case novelProject(id: NovelProjectID)
    case webMount
    case webMountSite(site: WebMountSiteRoute)
    case workspace
    case memory
    case council
    case councilSettings
    case seatEditor
    case subagents
    case subAgentRole(name: String, roleId: String)
    case subAgentConversation(id: String)
    case sandbox
    case conversation(id: String)
    case assistant(id: String)
    case workspaceItem(id: String)
    case settingsPlaceholder(title: String, subtitle: String, systemImage: String)
    case toolPermissions
    case promptInjection
}

enum SheetDestination: Identifiable, Hashable {
    case modelPicker
    case toolPermissions

    var id: String {
        switch self {
        case .modelPicker: "model-picker"
        case .toolPermissions: "tool-permissions"
        }
    }
}
