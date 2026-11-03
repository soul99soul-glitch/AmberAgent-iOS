import SwiftUI

@MainActor
@Observable
final class RouterPath {
    private var storedPath: [Route] = []
    /// 宽屏（iPhone Duo 展开 / iPad）双栏时，会话侧栏是否显示。
    var showsSidebar = true

    /// 聊天页在两种布局下都是根视图：单栏是栈底，双栏是详情栏根。
    /// 因此路径里永远不保留开头的 `.chat` / `.chatMessage`，所有
    /// `navigate(to: .chat)` / `path = [.chat, ...]` 调用方无需区分布局，
    /// 其语义统一为「回到根聊天页」。
    private(set) var chatIsRoot = true
    /// 双栏（iPhone Duo 展开 / iPad）：聊天根视图的返回键改为收放会话侧栏。
    var showsSidebarControl = false
    /// 侧栏浮在聊天上（Duo 内屏竖持等较窄的 regular 宽度）：选中会话后收起侧栏。
    var sidebarOverlaysDetail = false
    /// 根聊天页要定位的消息（来自 `.chatMessage` 路由）。
    private(set) var detailChatAnchor: ChatMessageAnchor?

    var path: [Route] {
        get { storedPath }
        set { storedPath = absorbingChatRoot(newValue) }
    }

    /// 当前可见的最上层页面是否为聊天页（含双栏模式的详情栏根）。
    var isShowingChat: Bool {
        switch storedPath.last {
        case nil: return chatIsRoot
        case .chat, .chatMessage(anchor: _): return true
        default: return false
        }
    }

    private func absorbingChatRoot(_ path: [Route]) -> [Route] {
        guard chatIsRoot, let first = path.first else { return path }
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
        if chatIsRoot {
            switch route {
            case .chat, .chatMessage(anchor: _):
                // 根即聊天页：回到根，而不是再压一层聊天。
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
            // 根聊天页没有上一页：双栏下返回键改为切换会话侧栏。
            if showsSidebarControl { showsSidebar.toggle() }
            return
        }
        path.removeLast()
    }

    func reset() {
        path = []
    }
}

enum Route: Hashable {
    /// 旧首页（会话管理页）：启动直达聊天后降级为次级存档入口。
    case home
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
    /// Task board of the paired Mac (scheduled tasks, their runs, Claude Code / Codex sessions).
    case macTasks
    /// Cloud configuration of the paired Mac (provider/model/search, local import).
    case cloudConfig
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
    case toolPermissions
}
