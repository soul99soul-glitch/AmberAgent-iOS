import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

/// 会话列表右上角的账户头像:有自定义头像则显示图片,否则显示昵称首字母。
/// 出现时加载,并监听 `.accountAvatarChanged` 在换头像后即时刷新。
private struct HomeAccountAvatar: View {
    let initial: String
    var size: CGFloat = 40
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(initial)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(AmberTheme.avatarIdleInk)
                    .frame(width: size, height: size)
                    .background(AmberTheme.avatarIdle, in: Circle())
            }
        }
        .contentShape(Circle())
        .onAppear { image = AccountAvatarStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: .accountAvatarChanged)) { _ in
            image = AccountAvatarStore.load()
        }
    }
}

enum HomeConversationIcon {
    static let fallback: HomePhosphor = .chatCircle

    /// 给标题 LLM 的短 key 表（稳定英文 slug → 实心字形 + 中文提示）。
    /// 生成标题时让模型选一个 key，列表优先用它，而不是事后猜标题文案。
    static let llmCatalog: [(key: String, icon: HomePhosphor, hint: String)] = [
        ("moon", .moon, "夜晚/梦"),
        ("sun", .sun, "白天/阳光"),
        ("wine", .wine, "酒"),
        ("coffee", .coffee, "咖啡"),
        ("sword", .sword, "武侠/战争"),
        ("crown", .crown, "帝王/王室"),
        ("castle", .castleTurret, "王朝/宫廷"),
        ("list", .list, "清单/顺序"),
        ("checklist", .listChecks, "待办"),
        ("music", .musicNotes, "音乐"),
        ("headphones", .headphones, "播客/耳机"),
        ("map", .mapPin, "地点/旅行"),
        ("globe", .globe, "世界/国际"),
        ("plane", .airplane, "飞机/出行"),
        ("car", .car, "汽车"),
        ("train", .train, "火车/地铁"),
        ("pill", .pill, "医疗/健康"),
        ("heart_pulse", .heartbeat, "心脏/体检"),
        ("scales", .scales, "对比/评价"),
        ("law", .gavel, "法律"),
        ("book", .bookOpen, "小说/阅读"),
        ("books", .books, "历史/典籍"),
        ("notebook", .notebook, "笔记"),
        ("pencil", .pencil, "写作"),
        ("code", .code, "编程/模型"),
        ("robot", .robot, "AI/机器人"),
        ("brain", .brain, "思考/心理"),
        ("idea", .lightbulb, "想法/原理"),
        ("science", .flask, "科学/实验"),
        ("game", .gameController, "游戏"),
        ("trophy", .trophy, "比赛/冠军"),
        ("football", .football, "足球"),
        ("basketball", .basketball, "篮球"),
        ("heart", .heart, "感情/恋爱"),
        ("smile", .smiley, "搞笑/轻松"),
        ("fire", .fire, "热门/燃"),
        ("bolt", .lightning, "速度/性能"),
        ("water", .drop, "水/海洋"),
        ("snow", .snowflake, "雪/冬天"),
        ("mountain", .mountains, "山"),
        ("tree", .tree, "树/自然"),
        ("flower", .flower, "花"),
        ("dog", .dog, "狗"),
        ("cat", .cat, "猫"),
        ("fish", .fish, "鱼/海鲜"),
        ("food", .forkKnife, "美食"),
        ("pizza", .pizza, "披萨"),
        ("burger", .hamburger, "汉堡"),
        ("cake", .cake, "蛋糕/生日"),
        ("home", .house, "家/住房"),
        ("office", .buildings, "公司/都市"),
        ("money", .wallet, "钱/消费"),
        ("finance", .currencyCny, "理财/汇率"),
        ("chart", .chartLineUp, "数据/趋势"),
        ("shop", .shoppingCart, "购物"),
        ("gift", .gift, "礼物"),
        ("calendar", .calendar, "日程"),
        ("clock", .clock, "时间"),
        ("study", .graduationCap, "考试/学习"),
        ("student", .student, "学生/上课"),
        ("camera", .camera, "拍照"),
        ("movie", .filmSlate, "电影/剧"),
        ("video", .videoCamera, "视频/直播"),
        ("phone", .phone, "电话/手机"),
        ("mail", .envelope, "邮件"),
        ("bell", .bell, "提醒"),
        ("lock", .lock, "安全/密码"),
        ("key", .key, "密钥"),
        ("translate", .translate, "翻译/语言"),
        ("quote", .quotes, "名言"),
        ("people", .users, "团队/社交"),
        ("baby", .baby, "育儿"),
        ("rocket", .rocket, "创业/发布"),
        ("work", .briefcase, "职场/面试"),
        ("deal", .handshake, "合作"),
        ("zen", .yinYang, "哲学"),
        ("ghost", .ghost, "灵异"),
        ("alien", .alien, "科幻"),
        ("drama", .maskHappy, "戏剧/角色"),
        ("design", .palette, "设计/配色"),
        ("paint", .paintBrush, "绘画"),
        ("search", .magnifyingGlass, "搜索/研究"),
        ("settings", .gear, "设置"),
        ("chat", .chatCircle, "闲聊/一般"),
    ]

    /// `icon(forTitle:isPinned:preferredKey:)` 的结果缓存。三个入参完全决定输出，
    /// 且调用方（ConversationSummaryRow.body / 单测）只在主线程调用，因此用普通
    /// Dictionary 即可，不需要额外加锁。超过上限直接清空，避免无界增长。
    /// `nonisolated(unsafe)`：`HomeConversationIcon` 本身不是 actor-isolated 类型
    /// （沿用既有调用方，非 @MainActor 的旧测试也直接同步调用），跟本文件其它
    /// 静态缓存（如 IOSGeminiProvider.effortsByBase）同一纪律——手动保证只在主线程写。
    private struct IconCacheKey: Hashable {
        let title: String
        let isPinned: Bool
        let preferredKey: String?
    }
    nonisolated(unsafe) private static var iconCache: [IconCacheKey: HomePhosphor] = [:]
    private static let iconCacheLimit = 500

    /// 按会话标题 / 可选 LLM 图标 key 取 Phosphor fill。
    /// 1) 置顶 → 图钉
    /// 2) 标题 LLM 写入的 preferredKey
    /// 3) 标题关键词表
    /// 4) 中性气泡 fallback
    static func icon(forTitle title: String, isPinned: Bool, preferredKey: String? = nil) -> HomePhosphor {
        let key = IconCacheKey(title: title, isPinned: isPinned, preferredKey: preferredKey)
        if let cached = iconCache[key] {
            return cached
        }
        let resolved = resolveIcon(forTitle: title, isPinned: isPinned, preferredKey: preferredKey)
        if iconCache.count >= iconCacheLimit {
            iconCache.removeAll(keepingCapacity: true)
        }
        iconCache[key] = resolved
        return resolved
    }

    private static func resolveIcon(forTitle title: String, isPinned: Bool, preferredKey: String?) -> HomePhosphor {
        if isPinned { return .pushPin }
        if let preferredKey,
           let icon = resolveLLMKey(preferredKey) {
            return icon
        }
        let normalized = title.lowercased()
        if let mapped = semanticIcon(for: normalized) {
            return mapped
        }
        // 无语义命中时用中性气泡，不再按标题哈希抽取与内容无关的图标。
        return fallback
    }

    /// 只认 `llmCatalog` 里的 slug；返回落盘用的规范化 key。
    static func canonicalLLMKey(_ raw: String) -> String? {
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        guard !key.isEmpty else { return nil }
        return llmCatalog.first(where: { $0.key == key })?.key
    }

    static func resolveLLMKey(_ raw: String) -> HomePhosphor? {
        guard let key = canonicalLLMKey(raw) else { return nil }
        return llmCatalog.first(where: { $0.key == key })?.icon
    }

    /// 塞进标题 prompt 的 icon 说明（短、可解析）。
    static func llmIconInstructionBlock() -> String {
        let keys = llmCatalog.map(\.key).joined(separator: ", ")
        return """

        Also pick ONE icon key that best matches the topic.
        Reply in exactly two lines:
        line1 = the title only (rules above still apply)
        line2 = icon:<key>
        Allowed <key> values: \(keys)
        """
    }

    /// 关键词命中；顺序即优先级（先匹配先生效）。
    private static func semanticIcon(for normalized: String) -> HomePhosphor? {
        let mappings: [(HomePhosphor, [String])] = [
            (.moon, ["月光", "月亮", "夜色", "夜晚", "晚安", "晚上", "星空", "半夜", "晚年", "梦", "失眠"]),
            (.sun, ["白天", "阳光", "日出", "日落", "晴天", "夏天", "夏日"]),
            (.wine, ["酒", "酿", "醉", "干杯", "白酒", "红酒", "啤酒", "威士忌"]),
            (.coffee, ["咖啡", "拿铁", "美式", "espresso", "café"]),
            (.sword, ["剑", "武侠", "江湖", "打仗", "战争", "战役", "战术", "兵法", "武将", "将军", "军队", "项羽", "吕布", "关羽"]),
            (.crown, ["皇帝", "帝王", "王冠", "君主", "国王", "女王", "皇后", "皇室", "王位", "登基", "在位", "宋太祖", "赵匡胤", "天子"]),
            (.castleTurret, ["宫殿", "城堡", "王朝", "帝国", "朝廷"]),
            (.list, ["顺序", "排行", "清单", "列表", "目录", "步骤", "流程", "时间表", "年表"]),
            (.listChecks, ["todo", "待办", "checklist", "勾选", "任务列表"]),
            (.musicNotes, ["音乐", "歌曲", "歌单", "bgm", "配乐", "旋律", "专辑", "歌手", "歌词", "钢琴", "吉他", "rap"]),
            (.headphones, ["耳机", "播客", "podcast", "听歌"]),
            (.mapPin, ["在哪", "哪里", "哪儿", "地址", "地图", "路线", "都城", "城市", "旅行", "旅游", "景点", "定位"]),
            (.globe, ["世界", "国际", "全球", "地球", "国家", "海外", "跨国"]),
            (.airplane, ["飞机", "航班", "机场", "航空", "出差", "飞去"]),
            (.car, ["开车", "汽车", "驾车", "高速", "路况", "停车"]),
            (.train, ["火车", "高铁", "地铁", "动车", "站台"]),
            (.pill, ["药", "症状", "治疗", "医院", "看病", "疾病", "感冒", "发烧", "痛风", "健康", "养生"]),
            (.heartbeat, ["心脏", "血压", "体检", "心率"]),
            (.scales, ["谁", "对比", "比较", "哪个好", "排名", "评价", "厉害", "更强", "哪个厉害"]),
            (.gavel, ["法律", "法院", "律师", "判决", "合同", "合规"]),
            (.bookOpen, ["小说", "读书", "阅读", "章节", "写书", "连载", "故事", "剧本", "剧情"]),
            (.books, ["历史", "史料", "文献", "典籍", "通史"]),
            (.notebook, ["笔记", "备忘", "日记", "手账"]),
            (.pencil, ["写作", "作文", "改写", "润色", "文案", "起草"]),
            (.code, ["代码", "编程", "程序", "bug", "api", "swift", "python", "前端", "后端", "算法", "模型", "训练", "llm", "gpt"]),
            (.robot, ["机器人", "ai", "人工智能", "智能体", "agent"]),
            (.brain, ["思考", "推理", "认知", "心理", "脑"]),
            (.lightbulb, ["想法", "创意", "灵感", "点子", "方案"]),
            (.flask, ["化学", "实验", "科学", "物理", "公式"]),
            (.gameController, ["游戏", "电玩", "通关", "副本", "rpg", "steam"]),
            (.trophy, ["冠军", "夺冠", "奖杯", "比赛", "胜负"]),
            (.football, ["足球", "世界杯", "联赛"]),
            (.basketball, ["篮球", "nba", "扣篮"]),
            (.heart, ["爱情", "恋爱", "喜欢", "表白", "女朋友", "男朋友", "结婚", "暗恋"]),
            (.smiley, ["开心", "搞笑", "笑话", "幽默", "段子"]),
            (.fire, ["火", "热门", "爆", "燃", "热情"]),
            (.lightning, ["闪电", "速度", "性能", "加速"]),
            (.drop, ["水", "下雨", "喝水", "饮水", "海洋"]),
            (.snowflake, ["雪", "冬天", "冰冷", "霜"]),
            (.mountains, ["山", "登山", "爬山", "高原"]),
            (.tree, ["树", "森林", "植物", "环保"]),
            (.flower, ["花", "玫瑰", "花园"]),
            (.dog, ["狗", "犬", "汪"]),
            (.cat, ["猫", "喵"]),
            (.fish, ["鱼", "海鲜", "钓鱼", "三文鱼", "帝王鲑"]),
            (.pizza, ["披萨", "pizza"]),
            (.hamburger, ["汉堡", "快餐"]),
            (.cake, ["蛋糕", "生日", "甜品"]),
            (.forkKnife, ["美食", "餐厅", "做饭", "菜谱", "吃什么", "下厨"]),
            (.house, ["家", "房子", "居住", "装修", "租房"]),
            (.buildings, ["公司", "办公", "写字楼", "都市"]),
            (.wallet, ["钱", "理财", "存款", "消费", "省钱"]),
            (.currencyCny, ["人民币", "汇率", "日元", "美元", "炒股", "股票", "基金"]),
            (.chartLineUp, ["增长", "趋势", "数据", "分析", "报表", "kpi"]),
            (.shoppingCart, ["购物", "网购", "下单", "淘宝", "买东西"]),
            (.gift, ["礼物", "送礼", "红包"]),
            (.calendar, ["日程", "日历", "约会", "会议", "安排"]),
            (.clock, ["时间", "几点", "迟到", "闹钟", "倒计时"]),
            (.graduationCap, ["考试", "高考", "考研", "留学", "大学", "学习", "课程", "作业"]),
            (.student, ["学生", "同学", "老师", "上课"]),
            (.camera, ["拍照", "摄影", "相机", "照片"]),
            (.filmSlate, ["电影", "影视", "剧集", "追剧", "导演"]),
            (.videoCamera, ["视频", "直播", "剪辑"]),
            (.phone, ["电话", "手机", "通话"]),
            (.envelope, ["邮件", "email", "写信"]),
            (.bell, ["提醒", "通知", "闹钟提醒"]),
            (.lock, ["密码", "加密", "隐私", "安全", "登录"]),
            (.key, ["钥匙", "密钥", "token"]),
            (.translate, ["翻译", "英文", "日语", "语法", "单词"]),
            (.quotes, ["名言", "引用", "摘抄"]),
            (.users, ["团队", "同事", "朋友", "群", "社交"]),
            (.baby, ["宝宝", "婴儿", "育儿", "怀孕"]),
            (.rocket, ["创业", "上线", "发布", "起飞", "航天"]),
            (.briefcase, ["工作", "职业", "面试", "简历", "职场"]),
            (.handshake, ["合作", "商务", "谈判", "签约"]),
            (.yinYang, ["哲学", "道家", "阴阳", "禅"]),
            (.ghost, ["鬼", "灵异", "恐怖", "玄学"]),
            (.alien, ["外星", "ufo", "科幻"]),
            (.maskHappy, ["戏剧", "表演", "话剧", "角色", "喜剧"]),
            (.palette, ["设计", "配色", "画画", "美术", "ui"]),
            (.paintBrush, ["绘画", "水彩", "油画"]),
            (.magnifyingGlass, ["搜索", "查找", "检索", "研究"]),
            (.gear, ["设置", "配置", "参数", "系统"]),
            (.lightbulb, ["为什么", "怎么做", "如何", "解释", "原理"]),
        ]
        return mappings.first(where: { _, words in words.contains { normalized.contains($0) } })?.0
    }
}

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
private struct HomePressStateStyle: ButtonStyle {
    @Binding var pressed: Bool
    let scale: CGFloat
    /// E 版会话行 `transform-origin: left center`；其它控件保持中心。
    var scaleAnchor: UnitPoint = .center
    var haptic: AmberHapticEvent? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1, anchor: scaleAnchor)
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                pressed = isPressed
                guard isPressed, let haptic else { return }
                AmberHaptics.trigger(haptic)
            }
            // 行在按压中被回收/重建时，避免 pressed 残留导致按压垫底卡住。
            .onDisappear { pressed = false }
    }
}

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

enum HomeCardSlice: Equatable { case top, middle, bottom, single }

private struct HomeSliceShape: Shape {
    let slice: HomeCardSlice
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = AmberTheme.homeCardRadius
        switch slice {
        case .top: return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius, style: .continuous).path(in: rect)
        case .bottom: return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous).path(in: rect)
        case .single: return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        case .middle: return Rectangle().path(in: rect)
        }
    }
}

/// 会话空态：与列表一体卡同圆角/投影。
private struct HomeEmptyCard: View {
    let title: LocalizedStringKey
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let ambient = AmberTheme.cardShadowAmbientGeometry(for: colorScheme)
        Text(title)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(AmberTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background {
                if AmberThemeRuntime.shared.emptyArt == .character {
                    Group {
                        switch AmberThemeRuntime.shared.canvasStyle {
                        case .lineGrid:
                            // Keep quieter than page gutters; match HomeCardCanvasTexture scale.
                            AmberLineGridOverlay()
                                .opacity(HomeCardCanvasTexture.lineGridOpacity)
                        case .paperGrain:
                            AmberPaperGrainOverlay()
                                .opacity(HomeCardCanvasTexture.paperGrainOpacity)
                        case .dotGrid, .flat:
                            AmberDotGridOverlay()
                                .opacity(HomeCardCanvasTexture.dotGridOpacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AmberTheme.homeCardRadius, style: .continuous))
                }
            }
            .background(HomeSliceShape(slice: .single).fill(AmberTheme.card))
            .overlay { HomeSliceShape(slice: .single).stroke(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth).allowsHitTesting(false) }
            .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
            .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
            .padding(.horizontal, 16)
    }
}

private struct HomeShortcut: View {
    let entry: HomeShortcutEntry
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var shortcutLabelSize: CGFloat = 11
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Icon skin from theme pack; VStack layout frozen.
                HomeShortcutIconView(entry: entry, size: 20)
                Text(
                    verbatim: IOSAppLocalization.string(
                        entry.title,
                        defaultValue: entry.title
                    )
                )
                    // Chrome typeface from theme pack; not chat body IOSChatFont.
                    .font(AmberChromeFont.system(size: shortcutLabelSize, weight: .semibold))
                    .tracking(0.11)
                    .lineLimit(2)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(hovering || pressed ? AmberTheme.foreground : AmberTheme.muted)
            .frame(
                minWidth: dynamicTypeSize.isAccessibilitySize ? 144 : nil,
                maxWidth: dynamicTypeSize.isAccessibilitySize ? 144 : .infinity,
                minHeight: 44
            )
            .background(hovering || pressed ? AmberTheme.press : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomePressStateStyle(pressed: $pressed, scale: 0.92, haptic: .selection))
        .onHover { hovering = $0 }
    }
}

private struct HomeContinueButton: View {
    let model: HomeContinueCardModel
    let action: (HomeContinueCardModel.Destination) -> Void
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var continueTitleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var continueMetaSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var continueCTAFontSize: CGFloat = 13
    var body: some View {
        Button { action(model.destination) } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            featureIcon
                            titleBlock
                        }
                        continueCTA(expands: true)
                    }
                } else {
                    HStack(spacing: 14) {
                        featureIcon
                        titleBlock
                        continueCTA(expands: false)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .background(pressed ? AmberTheme.press : (hovering ? AmberTheme.hoverCard : Color.clear))
        }
        .buttonStyle(HomePressStateStyle(pressed: $pressed, scale: 0.985, haptic: .lightImpact))
        .onHover { hovering = $0 }
        .accessibilityLabel("\(model.title)，\(model.meta)，\(model.ctaTitle)")
    }

    private var featureIcon: some View {
        HomePhosphorIcon(model.feature.icon, size: 22)
            .foregroundStyle(AmberTheme.avatarActiveInk)
            .frame(width: 44, height: 44)
            .background(
                AmberTheme.avatarActive,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.title)
                .font(.system(size: continueTitleSize, weight: .semibold))
                .tracking(0.075)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Text(model.meta)
                .font(.system(size: continueMetaSize, weight: .regular))
                .tracking(0.11)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
        }
        .foregroundStyle(AmberTheme.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func continueCTA(expands: Bool) -> some View {
        // 续接 CTA：浅强调色底 + 主墨字（次级动作）；主强调留给右下「新对话」混色玻璃。
        let label = Text(model.ctaTitle)
            .font(.system(size: continueCTAFontSize, weight: .semibold))
            .tracking(0.26)
            .foregroundStyle(AmberTheme.foreground)
        let fill = hovering || pressed ? AmberTheme.avatarActive : AmberTheme.accentTint
        if expands {
            label
                .padding(.vertical, 7)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(fill, in: Capsule())
        } else {
            label
                .padding(.vertical, 7)
                .padding(.horizontal, 18)
                .frame(minHeight: 32)
                .background(fill, in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct HomeCascade: ViewModifier {
    let delay: Double
    /// false 时跳过动画直接呈现：级联是一次性入场，List 行回收/搜索重建不得重播。
    var enabled: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)
            .onAppear {
                guard !reduceMotion else { appeared = true; return }
                guard enabled else { appeared = true; return }
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.48).delay(delay)) { appeared = true }
            }
    }
}

private extension View {
    func homeCascade(delay: Double, enabled: Bool = true) -> some View { modifier(HomeCascade(delay: delay, enabled: enabled)) }
}

/// 首页展开搜索条的中性玻璃表面；按钮使用原生玻璃按钮样式。
/// iOS 26+：原生 Liquid Glass（skill: 真 `glassEffect`，轻垫底保证暖灰画布上可读，不做假 solid chip）。
/// 更早系统：ultraThinMaterial + E 版描边/投影回退。
private struct HomeGlassControlModifier: ViewModifier {
    let cornerRadius: CGFloat
    var interactive: Bool = true

    private var padOpacity: Double {
        switch AmberThemeRuntime.shared.glassChrome {
        case .standard: 0.28
        case .quieter: 0.18
        case .solid: 0.52
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let control = content
            .contentShape(shape)
        if #available(iOS 26.0, *) {
            // 垫底极轻：帮助折射；强度由主题 glassChrome 弱控。
            control
                .background(AmberTheme.homeGlassTop.opacity(padOpacity), in: shape)
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
        } else {
            control
                .background(.ultraThinMaterial, in: shape)
                .background(
                    LinearGradient(
                        colors: [
                            AmberTheme.homeGlassTop.opacity(padOpacity / 0.28),
                            AmberTheme.homeGlassBottom.opacity(padOpacity / 0.28),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: shape
                )
                .overlay { shape.strokeBorder(AmberTheme.homeGlassEdge, lineWidth: 0.5) }
                .overlay(alignment: .top) {
                    shape.strokeBorder(AmberTheme.homeGlassHighlight, lineWidth: 0.5)
                        .frame(height: 1)
                        .clipShape(shape)
                }
                .shadow(color: AmberTheme.homeGlassShadowAmbient, radius: 14, y: 10)
                .shadow(color: AmberTheme.homeGlassShadowContact, radius: 4, y: 2)
        }
    }
}

private extension View {
    func homeGlassControl(cornerRadius: CGFloat, interactive: Bool = true) -> some View {
        modifier(HomeGlassControlModifier(cornerRadius: AmberTheme.controlRadius(cornerRadius), interactive: interactive))
            .overlay { RoundedRectangle(cornerRadius: AmberTheme.controlRadius(cornerRadius)).strokeBorder(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth).allowsHitTesting(false) }
    }

    /// iOS 26 原生 glass morph 标记；旧系统 no-op。
    @ViewBuilder
    func homeGlassEffectID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// 首页齿轮钮保持原生圆形轮廓，主题圆角不参与系统按钮的按压形变。
private struct HomeGlassCircleButton: View {
    let icon: HomePhosphor
    let accessibilityLabel: String
    var size: CGFloat = 38
    var iconSize: CGFloat = 20
    var tint: Color = AmberTheme.muted
    var glassNamespace: Namespace.ID? = nil
    var glassEffectID: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            AmberHaptics.trigger(.lightImpact)
            action()
        } label: {
            HomePhosphorIcon(icon, size: iconSize)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .amberGlassButton(cornerRadius: size / 2, borderShape: .circle, sizing: .fitted)
        .controlSize(.mini)
        .frame(width: size, height: size)
        .modifier(HomeOptionalGlassEffectID(id: glassEffectID, namespace: glassNamespace))
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct HomeOptionalGlassEffectID: ViewModifier {
    let id: String?
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let id, let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

struct ConversationsView: View {
    let sharedSettings: IOSSharedSettingsStore
    let chatViewModel: ChatViewModel
    let councilChatViewModel: CouncilChatViewModel
    let novelCreationViewModel: NovelCreationViewModel?

    @Environment(RouterPath.self) private var router
    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery: String = ""
    /// Liquid Glass morph namespace（skill: glassEffectID + hierarchy change）。
    @Namespace private var homeSearchNamespace
    @State private var deepReadStore = IOSDeepReadStore.shared
    @State private var miniAppRepository = IOSMiniAppRepository.shared
    @State private var renamingConversationId: KotlinUuid?
    @State private var renameDraft: String = ""
    @State private var deletingConversationId: KotlinUuid?
    @State private var backgroundGenerationRevision = 0
    @State private var homeImageGenerationContext: ChatImageGenerationResumeContext?
    @State private var homeContinueError: String?
    @State private var isSearchExpanded = false
    @State private var conversationNavigationTask: Task<Void, Never>?
    @AppStorage(ChatImageGenerationResumeConsumption.viewedCompletionIDKey)
    private var viewedImageGenerationID = ""
    @FocusState private var searchFocused: Bool
    /// 展开后是否已真正拿到焦点；避免 expand 后 170ms 内 focused==false 误触发点外收起。
    @State private var searchHadFocus = false
    @AccessibilityFocusState private var deepReadShortcutFocused: Bool
    /// 展开搜索后的延迟聚焦任务：取消/离场必须可撤销，否则 170ms 内收起会残留 FocusState。
    @State private var searchFocusTask: Task<Void, Never>?
    /// 入场级联只播放一次：最晚一级 delay .22 + 时长 .48，0.9s 后全部按已入场处理。
    @State private var cascadeComplete = false
    @ScaledMetric(relativeTo: .subheadline) private var sectionLabelSize: CGFloat = 15

    /// 本地标题过滤后的会话摘要（summaries 已按 updateAt 倒序/置顶优先）。
    private var filteredSummaries: [ConversationSummary] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return conversationStore.summaries }
        return conversationStore.summaries.filter { summary in
            // 空标题会话用占位串参与匹配，避免搜索框里全是空白行。
            let title = summary.title.isEmpty ? "新对话" : summary.title
            return title.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var homeImageGenerationScanSignature: Int {
        var hasher = Hasher()
        hasher.combine(conversationStore.backgroundContentRevision)
        hasher.combine(backgroundGenerationRevision)
        hasher.combine(chatViewModel.isLoading)
        for summary in conversationStore.summaries {
            hasher.combine(summary.id.toHexDashString())
            hasher.combine(summary.updateAt.toEpochMilliseconds())
        }
        return hasher.finalize()
    }

    var body: some View {
        // snapshot 为 @ObservationIgnored；读 revision 才能在改昵称后刷新头像首字。
        let _ = sharedSettings.revision
        let visibleSummaries = filteredSummaries
        GeometryReader { geometry in
        ZStack(alignment: .bottomTrailing) {
            // Canvas layer (color + optional texture). List structure unchanged.
            AmberCanvasBackground()

            // 用原生 List 承载整屏，会话行才能挂 .swipeActions(Apple Music 同款左右滑动)。
            // 顶部 header/搜索/快捷区作为清空背景的 List 行铺在上面，玻璃风格不受影响:
            // .scrollContentBackground(.hidden) + 每行 .listRowBackground(.clear) 让 List 自身
            // 不画任何底色，保留 AmberTheme.background。
            // 新建：右下拇指区真浮层胶囊（非顶栏、非圆 FAB、非 safeAreaInset 假底栏）。
            List {
                header.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden).homeCascade(delay: 0.06, enabled: !cascadeComplete)
                // 搜索条单独成行：顶栏行高恒定，键盘收起/搜索折叠时 AMBER 与齿轮不随行高动画跳动。
                if isSearchExpanded {
                    expandedSearchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 15)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                controlCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .homeCascade(delay: 0.10, enabled: !cascadeComplete)
                    .simultaneousGesture(dismissSearchOutsideTap)
                Text("会话")
                    // Section chrome from theme pack; list row layout frozen; chat body font independent.
                    .font(AmberChromeFont.system(size: sectionLabelSize, weight: .semibold))
                    .foregroundStyle(AmberTheme.section)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 12)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden).homeCascade(delay: 0.14, enabled: !cascadeComplete)
                    .contentShape(Rectangle())
                    .simultaneousGesture(dismissSearchOutsideTap)

                if visibleSummaries.isEmpty {
                    HomeEmptyCard(title: searchQuery.isEmpty ? "还没有会话" : "没有匹配的会话")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .homeCascade(delay: 0.18, enabled: !cascadeComplete)
                        .simultaneousGesture(dismissSearchOutsideTap)
                } else {
                    conversationList(visibleSummaries)
                }

                // 滚到底时末行让过右下胶囊（仅 scroll 留白，无实色底栏）。
                Color.clear
                    .frame(height: homeNewChatCapsuleListClearance)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .simultaneousGesture(dismissSearchOutsideTap)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 有点阵/方格时底部 soft 会把会话外框下沿「透」成雾面；改 hard 保住卡壳不透明。
            .scrollEdgeEffectStyle(
                AmberThemeRuntime.shared.canvasStyle.hasTexture ? .hard : .soft,
                for: .bottom
            )
            // 点到非搜索区导致失焦时收起（与 Esc/取消一致）。
            .onChange(of: searchFocused) { _, focused in
                if focused {
                    searchHadFocus = true
                } else if searchHadFocus, isSearchExpanded {
                    collapseSearch()
                }
            }

            // 右下拇指区：内容贴合胶囊浮在内容上（局部琥珀；非满幅条）。
            // trailing 28（非卡边 16）：相对会话外框内缩 12pt，避免胶囊右缘与卡边相切。
            // 视觉位置不变：外扩的热区从 inset 里扣回。
            homeNewChatCapsule
                .padding(.trailing, homeNewChatCapsuleTrailingInset - homeNewChatCapsuleHitSlop)
                .padding(
                    .bottom,
                    (dynamicTypeSize.isAccessibilitySize
                        ? 12
                        : max(homeNewChatCapsuleBottomInset - geometry.safeAreaInsets.bottom, 12))
                        - homeNewChatCapsuleHitSlop
                )
                .homeCascade(delay: 0.22, enabled: !cascadeComplete)
        }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: .amberChatBackgroundJobDidTerminate)) { _ in
            backgroundGenerationRevision &+= 1
        }
        .onAppear {
            Task { await novelCreationViewModel?.loadProjects(restoresSelection: false) }
            guard !cascadeComplete else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { cascadeComplete = true }
        }
        .task(id: homeImageGenerationScanSignature) {
            let context = await chatViewModel.latestImageGenerationResumeContext()
            guard !Task.isCancelled else { return }
            homeImageGenerationContext = context
        }
        .onChange(of: homeContinueModel) { oldValue, newValue in
            announceHomeContinueChange(from: oldValue, to: newValue)
        }
        .onChange(of: router.path) { _, path in
            if !path.isEmpty {
                conversationNavigationTask?.cancel()
            }
        }
        .onDisappear {
            searchFocusTask?.cancel()
            conversationNavigationTask?.cancel()
        }
        .alert("无法打开任务", isPresented: Binding(
            get: { homeContinueError != nil },
            set: { if !$0 { homeContinueError = nil } }
        )) {
            Button("好") { homeContinueError = nil }
        } message: {
            Text(homeContinueError ?? "图片所在会话暂不可用。")
        }
        .alert("重命名会话", isPresented: Binding(
            get: { renamingConversationId != nil },
            set: { if !$0 { renamingConversationId = nil } }
        )) {
            TextField("会话标题", text: $renameDraft)
            Button("取消", role: .cancel) { renamingConversationId = nil }
            Button("保存") {
                if let id = renamingConversationId {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Task { @MainActor in
                            await conversationStore.renameConversation(id: id, title: trimmed)
                        }
                    }
                }
                renamingConversationId = nil
            }
        }
        .alert("删除会话？", isPresented: Binding(
            get: { deletingConversationId != nil },
            set: { if !$0 { deletingConversationId = nil } }
        )) {
            Button("取消", role: .cancel) { deletingConversationId = nil }
            Button("删除", role: .destructive) {
                if let id = deletingConversationId {
                    Task { @MainActor in
                        await conversationStore.deleteConversation(id: id) { affectedIDs in
                            affectedIDs.forEach(chatViewModel.prepareForConversationDeletion)
                        }
                    }
                }
                deletingConversationId = nil
            }
        } message: {
            Text("此操作不可撤销，会话内的全部消息将被删除。关联子任务会停止，子会话记录保留在“对话存储”中。")
        }
    }

    private var accountInitial: String {
        let trimmed = sharedSettings.displaySetting.userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "A" : trimmed).prefix(1)).uppercased()
    }

    /// Continue 显隐：0.30s 与搜索 expand 同曲线族；Reduce Motion 缩短。
    private var homeContinuePresenceMotion: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.15)
        }
        return .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.30)
    }

    /// 右下新建胶囊：略小于搜索 38 的「宽版」控制，仍 ≥ 拇指舒适区。
    private var homeNewChatCapsuleHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 48 : 42
    }

    /// 相对屏右 inset：大于会话卡 16，使胶囊相对外框内缩约 12pt。
    private var homeNewChatCapsuleTrailingInset: CGFloat { 28 }

    /// 相对屏底 inset（拇指区）。
    private var homeNewChatCapsuleBottomInset: CGFloat { 52 }

    /// 胶囊四周额外触控热区；玻璃外观不变，只扩大可点范围（贴角浮层易点偏）。
    private var homeNewChatCapsuleHitSlop: CGFloat { 10 }

    /// 列表底留白：胶囊高 + 余量（只滚空白，不铺实色栏）。
    private var homeNewChatCapsuleListClearance: CGFloat {
        homeNewChatCapsuleHeight + 36
    }

    /// 首页右下「新对话」浮层胶囊。
    /// skill 门禁：
    /// - taste：主强调动作；强调色混色玻璃 + on-accent 墨，压过 Continue 浅色 CTA
    /// - liquid glass：原生 prominent 按钮统一处理强调色、玻璃与按压形变
    /// - ui-patterns：拇指区 bottomTrailing 真浮层；非 top 难够、非 inset 假底栏
    private var homeNewChatCapsule: some View {
        let height = homeNewChatCapsuleHeight
        return Button(action: triggerHomeNewChat) {
            HStack(spacing: 6) {
                HomePhosphorIcon(.pencil, size: 14)
                    .foregroundStyle(AmberTheme.fabInk)
                Text("新对话")
                    .font(AmberChromeFont.system(size: 14, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(AmberTheme.fabInk)
            }
            .frame(maxHeight: .infinity)
        }
        .amberGlassButton(
            cornerRadius: height / 2, prominent: true, tint: AmberTheme.accent,
            borderShape: .capsule, sizing: .fitted
        )
        .controlSize(.regular)
        .frame(height: height)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("新建聊天")
        .accessibilityAddTraits(.isButton)
        // 胶囊外的一圈透明热区：点在玻璃边缘外侧也能新建；玻璃内仍由按钮自身处理按压形变。
        .padding(homeNewChatCapsuleHitSlop)
        .contentShape(Capsule())
        .onTapGesture(perform: triggerHomeNewChat)
    }

    private func triggerHomeNewChat() {
        AmberHaptics.trigger(.lightImpact)
        startNewConversation()
    }

    /// E 版 + Liquid Glass skill：
    /// - 玻璃只上控制层（搜索/齿轮 + 展开条 + 右下新建胶囊）
    /// - 展开条在独立 List 行（顶栏行高恒定），胶囊与条之间不再跨行 morph
    /// - 关闭相邻玻璃的融合距离；搜索与齿轮留出 18pt，按压不再膨胀黏连
    /// - 展开 0.32s 对齐原型 cubic-bezier(0.2,.8,.2,1)；Reduce Motion 缩短
    private var header: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    homeHeaderStack(useGlassEffectID: true)
                }
            } else {
                homeHeaderStack(useGlassEffectID: false)
            }
        }
        .animation(homeSearchMotion, value: isSearchExpanded)
    }

    private func homeHeaderStack(useGlassEffectID: Bool) -> some View {
        HStack(spacing: 10) {
            // Brand mark layer — HStack chrome layout frozen.
            AmberBrandMarkView()
                .layoutPriority(1)

            Spacer(minLength: 8)

            if !isSearchExpanded {
                homeSearchCapsuleButton
                    .modifier(HomeOptionalGlassEffectID(
                        id: useGlassEffectID ? "homeSearch" : nil,
                        namespace: useGlassEffectID ? homeSearchNamespace : nil
                    ))
                    .padding(.trailing, 8)
            }

            homeSettingsGlassButton
                .modifier(HomeOptionalGlassEffectID(
                    id: useGlassEffectID ? "homeSettings" : nil,
                    namespace: useGlassEffectID ? homeSearchNamespace : nil
                ))

            Button {
                collapseSearchIfNeeded()
                router.navigate(to: .account)
            } label: {
                // 与搜索 38 / 齿轮 38 同高，顶栏控制簇尺度一致。
                HomeAccountAvatar(initial: accountInitial, size: 38)
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.92, haptic: .lightImpact))
            .accessibilityLabel("我的账户")
        }
        .frame(minHeight: 38)
        .padding(.horizontal, 16)
    }

    private var homeSearchCapsuleButton: some View {
        Button {
            AmberHaptics.trigger(.lightImpact)
            expandSearch()
        } label: {
            HStack(spacing: 6) {
                HomePhosphorIcon(.magnifyingGlass, size: 14)
                Text("搜索")
                    .font(AmberChromeFont.system(size: 13, weight: .semibold))
                    .tracking(0.26)
            }
            .foregroundStyle(AmberTheme.muted)
            .frame(maxHeight: .infinity)
        }
        .amberGlassButton(cornerRadius: 19, borderShape: .capsule, sizing: .fitted)
        .controlSize(.mini)
        .frame(minWidth: 78)
        .frame(height: 38)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("搜索")
        .accessibilityAddTraits(.isButton)
    }

    private var homeSettingsGlassButton: some View {
        HomeGlassCircleButton(
            icon: .gear,
            accessibilityLabel: "设置",
            size: 38,
            iconSize: 20,
            tint: AmberTheme.fab
        ) {
            collapseSearchIfNeeded()
            router.navigate(to: .settings)
        }
    }

    /// 展开后的全宽玻璃条：高 41、圆角 14（E 版实测）；独立 List 行，不改变顶栏行高。
    private var expandedSearchBar: some View {
        HStack(spacing: 14) {
            HomePhosphorIcon(.magnifyingGlass, size: 14)
                .foregroundStyle(AmberTheme.muted2)
            TextField("搜索会话", text: $searchQuery)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(AmberTheme.foreground)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { router.navigate(to: .search(initialQuery: searchQuery)) }
            Button("取消", action: collapseSearch)
                .font(AmberChromeFont.system(size: 13, weight: .semibold))
                .tracking(0.26)
                .foregroundStyle(AmberTheme.muted)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 41)
        .homeGlassControl(cornerRadius: 14, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.controlRadius(14), style: .continuous)
                .strokeBorder(AmberTheme.focusRing, lineWidth: 1.5)
                .opacity(searchFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onKeyPress(.escape) {
            collapseSearch()
            return .handled
        }
    }

    /// 原型 expand 0.32s；Reduce Motion 用短 ease，避免 glass morph 晃眼。
    private var homeSearchMotion: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.15)
        }
        // E 版 searchslot：cubic-bezier(0.2, 0.8, 0.2, 1) 0.32s
        return .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
    }

    /// 点控制卡 / 会话区 / 空白留白时收起（不抢子按钮点击，用 simultaneousGesture）。
    private var dismissSearchOutsideTap: some Gesture {
        TapGesture().onEnded { collapseSearchIfNeeded() }
    }

    private func expandSearch() {
        searchHadFocus = false
        // skill: hierarchy 变化时 withAnimation，才能触发 glass morph
        withAnimation(homeSearchMotion) {
            isSearchExpanded = true
        }
        searchFocusTask?.cancel()
        searchFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            // 170ms 内取消/收起/离场都会取消本任务，不会再写 FocusState。
            guard !Task.isCancelled, isSearchExpanded else { return }
            searchFocused = true
        }
    }

    private func collapseSearchIfNeeded() {
        guard isSearchExpanded else { return }
        collapseSearch()
    }

    private func collapseSearch() {
        searchFocusTask?.cancel()
        searchFocusTask = nil
        searchQuery = ""
        searchFocused = false
        searchHadFocus = false
        withAnimation(homeSearchMotion) {
            isSearchExpanded = false
        }
    }

    private func conversationList(_ visibleSummaries: [ConversationSummary]) -> some View {
        // `isLoading` is the observable foreground transition; background jobs
        // publish their terminal transition through `backgroundGenerationRevision`.
        // Reading both here keeps each row derived from the current owners rather
        // than preserving the off-screen NavigationStack snapshot.
        _ = chatViewModel.isLoading
        _ = backgroundGenerationRevision
        // 观察浓缩预览字典，生成完成后 meta 第二态能刷新到首页。
        _ = conversationStore.listPreviewsByConversationId
        _ = conversationStore.listIconsByConversationId
        let count = visibleSummaries.count
        return ForEach(Array(visibleSummaries.enumerated()), id: \.element.id) { index, summary in
            let isLast = index == count - 1
            ConversationSummaryRow(
                summary: summary,
                isCurrent: conversationStore.currentConversation?.id == summary.id,
                isGenerating: chatViewModel.isGenerationActive(conversationId: summary.id),
                listPreview: conversationStore.listPreview(for: summary.id),
                listIconKey: conversationStore.listIconKey(for: summary.id),
                slice: homeSlice(index: index, count: count),
                // 一体卡内：末行无底线；当前行与下一行若为当前则让 hairline 让位，避免与 accent 色带打架。
                hidesSeparator: isLast
                    || conversationStore.currentConversation?.id == summary.id
                    || (index + 1 < count
                        && conversationStore.currentConversation?.id == visibleSummaries[index + 1].id),
                onTap: {
                    openConversation(summary.id)
                },
                onRename: {
                    renameDraft = summary.title
                    renamingConversationId = summary.id
                },
                onTogglePin: {
                    Task { @MainActor in
                        await conversationStore.togglePin(id: summary.id)
                    }
                },
                onDelete: {
                    deletingConversationId = summary.id
                },
                onExport: { format in
                    exportConversation(id: summary.id, title: summary.title, format: format)
                }
            )
            .equatable()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .homeCascade(delay: 0.18, enabled: !cascadeComplete)
        }
    }

    private func homeSlice(index: Int, count: Int) -> HomeCardSlice {
        if count == 1 { return .single }
        if index == 0 { return .top }
        return index == count - 1 ? .bottom : .middle
    }

    private var homeContinueModel: HomeContinueCardModel? {
        let novelProjects = novelCreationViewModel?.projects.map(HomeNovelProjectRef.init) ?? []
        let councilTask = councilChatViewModel.homeResumeContext.map(HomeCouncilTaskRef.init)
        let deepReadTasks = deepReadStore.history.map(HomeDeepReadTaskRef.init)
        let imageGeneration = homeImageGenerationContext.flatMap { context -> HomeImageGenerationRef? in
            if context.state == .completed, context.id == viewedImageGenerationID {
                return nil
            }
            return HomeImageGenerationRef(context)
        }
        let miniApps = miniAppRepository.apps.compactMap { app -> HomeMiniAppRef? in
            guard let latestVersion = miniAppRepository.versions(appId: app.id).first else { return nil }
            return HomeMiniAppRef(
                id: app.id,
                title: app.title,
                latestVersionCreatedAt: Date(
                    timeIntervalSince1970: TimeInterval(latestVersion.createdAt) / 1_000
                ),
                lastRunAt: app.lastRunAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
                }
            )
        }

        return HomeContinueCardModel.resolve(
            novelProjects: novelProjects,
            councilTask: councilTask,
            deepReadTasks: deepReadTasks,
            miniApps: miniApps,
            imageGeneration: imageGeneration
        )
    }

    private var controlCard: some View {
        let ambient = AmberTheme.cardShadowAmbientGeometry(for: colorScheme)
        return VStack(spacing: 0) {
            if let model = homeContinueModel {
                VStack(spacing: 0) {
                    HomeContinueButton(model: model) { destination in
                        switch destination {
                        case .openCouncil: router.navigate(to: .council)
                        case .deepReadTask(let id): router.navigate(to: .deepReadTask(id: id))
                        case .resumeProject(let id): router.navigate(to: .novelProject(id: id))
                        case .miniAppRunner(let id): router.navigate(to: .miniAppRunner(appId: id))
                        case .generatedImage(let anchor):
                            openGeneratedImage(anchor)
                        }
                    }
                    Rectangle().fill(AmberTheme.separator).frame(height: 1 / displayScale).padding(.horizontal, 16)
                        .accessibilityHidden(true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            shortcutRow
        }
        // Continue 候选出现/消失：高度随 VStack 收放 + opacity（taste：离散状态 0.3s，非 spring 列表）。
        .animation(homeContinuePresenceMotion, value: homeContinueModel)
        .background {
            ZStack {
                AmberTheme.card
                // Pi/sit：卡内淡网格，避免只有露边画布有纹理、卡面一片板。
                HomeCardCanvasTexture()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AmberTheme.homeCardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: AmberTheme.homeCardRadius).strokeBorder(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth).allowsHitTesting(false) }
        .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
        .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
        .padding(.horizontal, 16).padding(.top, 20)
    }

    @ViewBuilder
    private var shortcutRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal) {
                HStack(spacing: 0) { shortcutButtons }
                    .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .padding(.vertical, 9)
            .padding(.bottom, 2)
        } else {
            HStack(spacing: 0) { shortcutButtons }
                .padding(.vertical, 9)
                .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        HomeShortcut(entry: .deepRead) { router.navigate(to: .board) }
            .accessibilityFocused($deepReadShortcutFocused)
        HomeShortcut(entry: .novel) { router.navigate(to: .novelCreation) }
        HomeShortcut(entry: .council) { router.navigate(to: .council) }
        HomeShortcut(entry: .miniApps) { router.navigate(to: .miniApps) }
        HomeShortcut(entry: .webMount) { router.navigate(to: .webMount) }
    }

    private func announceHomeContinueChange(
        from oldValue: HomeContinueCardModel?,
        to newValue: HomeContinueCardModel?
    ) {
        guard router.path.isEmpty,
              UIAccessibility.isVoiceOverRunning,
              oldValue != newValue else { return }
        if newValue == nil {
            deepReadShortcutFocused = true
        }
        let announcement = newValue.map {
            IOSAppLocalization.formatted(
                "待继续任务更新：%@，%@，%@",
                defaultValue: "待继续任务更新：%@，%@，%@",
                arguments: [$0.title, $0.meta, $0.ctaTitle]
            )
        } ?? IOSAppLocalization.string("没有待继续任务", defaultValue: "没有待继续任务")
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func openGeneratedImage(_ anchor: ChatMessageAnchor) {
        guard let conversationID = conversationStore.summaries.first(where: {
            $0.id.toHexDashString() == anchor.conversationID
        })?.id else {
            homeImageGenerationContext = nil
            homeContinueError = "图片所在会话已不存在。"
            return
        }
        conversationNavigationTask?.cancel()
        conversationNavigationTask = Task { @MainActor in
            guard chatViewModel.prepareForConversationChange(to: conversationID) else {
                homeContinueError = "当前生成任务暂时无法切换会话，请稍后重试。"
                return
            }
            if conversationStore.currentConversation?.id != conversationID {
                guard await conversationStore.selectConversationIfAvailable(
                    id: conversationID,
                    commitIf: { !Task.isCancelled }
                ) else {
                    guard !Task.isCancelled else { return }
                    homeImageGenerationContext = nil
                    homeContinueError = "图片所在会话已不存在。"
                    return
                }
            }
            guard !Task.isCancelled,
                  conversationStore.currentConversation?.id == conversationID,
                  let toolCallID = anchor.toolCallID else {
                homeContinueError = "无法切换到图片所在会话。"
                return
            }

            guard let context = ChatImageGenerationResumeProjection.matching(
                in: conversationStore.currentMessages,
                conversationID: anchor.conversationID,
                messageID: anchor.messageID,
                toolCallID: toolCallID,
                isGenerationActive: chatViewModel.isGenerationActive(conversationId: conversationID)
            ) else {
                homeImageGenerationContext = nil
                homeContinueError = "图片记录已不存在或生成没有成功。"
                return
            }

            router.navigate(to: .chatMessage(anchor: ChatMessageAnchor(
                conversationID: context.conversationID,
                messageID: context.messageID,
                toolCallID: context.toolCallID
            )))
        }
    }

    private func exportConversation(id: KotlinUuid, title: String, format: IOSConversationExportFormat) {
        Task { @MainActor in
            await IOSConversationExporter.share(format: format, title: title) {
                // 存储层的错误弹窗只挂在聊天页，会话列表上看不到，所以这里始终由浮层给出提示。
                guard let messages = await conversationStore.messages(for: id) else {
                    return .failed("无法读取这段对话，可能已被删除或读取失败。")
                }
                return .loaded(messages)
            }
        }
    }

    private func openConversation(_ conversationID: KotlinUuid) {
        collapseSearchIfNeeded()
        conversationNavigationTask?.cancel()
        conversationNavigationTask = Task { @MainActor in
            guard chatViewModel.prepareForConversationChange(to: conversationID) else { return }
            if conversationStore.currentConversation?.id != conversationID {
                guard await conversationStore.selectConversationIfAvailable(
                    id: conversationID,
                    commitIf: { !Task.isCancelled }
                ) else {
                    guard !Task.isCancelled else { return }
                    homeContinueError = "该会话暂时无法打开。"
                    return
                }
            }
            guard !Task.isCancelled,
                  conversationStore.currentConversation?.id == conversationID else { return }
            router.navigate(to: .chat)
        }
    }

    private func startNewConversation() {
        collapseSearchIfNeeded()
        conversationNavigationTask?.cancel()
        conversationNavigationTask = Task { @MainActor in
            guard await chatViewModel.startNewConversation(
                commitIf: { !Task.isCancelled }
            ) else { return }
            guard !Task.isCancelled else { return }
            router.navigate(to: .chat)
        }
    }
}

/// 真实会话摘要行：切片一体卡（外框 + 顶/底投影），激活行 accent 色带，行间 hairline。
/// 非 private（原为 private struct）：只放宽到 internal，方便 HomeDesignContractTests
/// 用 @testable import 直接构造实例验证 `==`；仍是模块内部类型，不对外暴露。
struct ConversationSummaryRow: View, Equatable {
    let summary: ConversationSummary
    let isCurrent: Bool
    let isGenerating: Bool
    /// LLM 浓缩预览；空则 meta 只显示时间·条数（不交错）。
    let listPreview: String
    /// 标题 LLM 选出的图标 key；nil 则回退标题关键词 / 哈希。
    var listIconKey: String? = nil
    let slice: HomeCardSlice
    let hidesSeparator: Bool
    let onTap: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// 与 onRename 同理：只捕获 `summary.id` 与已参与比较的 `summary.title`。
    var onExport: (IOSConversationExportFormat) -> Void = { _ in }
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    /// true = 显示浓缩预览；false = 时间·条数。仅 isCurrent 且有 preview 时轮播。
    @State private var showingListPreview = false
    @State private var metaOpacity: Double = 1
    @State private var metaCycleTask: Task<Void, Never>?
    @ScaledMetric(relativeTo: .body) private var conversationTitleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var conversationMetadataSize: CGFloat = 11

    /// 供 `.equatable()` 用：只比较 body 实际读取、决定渲染结果的字段。
    /// `summary` 是 KMP `data class`（结构相等），但这里不比较整个对象——只挑 body 里
    /// 真正用到的四个字段（title/isPinned/messageCount/updateAt），忽略
    /// assistantId/createAt/memoryMode 等本行不读的字段，命中率更高。
    ///
    /// 闭包（onTap/onRename/onTogglePin/onDelete）故意不参与比较：
    /// - onTap/onDelete/onTogglePin 只捕获 `summary.id`（同一行 id 恒定不变）和
    ///   引用类型 owner（conversationStore/chatViewModel/router，@State 写入路径也是
    ///   共享存储，与具体是哪一份 self 快照无关），跟“这份闭包是不是本帧新建的”无关。
    /// - onRename 额外捕获 `summary.title` 写进 renameDraft；但 title 已经是本 == 的
    ///   比较字段之一——只要 title 变了这一行就判定不相等、body 会重新求值并换上带新
    ///   title 的闭包，所以点击时拿到的必然是当前 title，不存在“旧闭包捕获旧标题”的
    ///   过期风险，不需要额外改成点击时按 id 现查。
    nonisolated static func == (lhs: ConversationSummaryRow, rhs: ConversationSummaryRow) -> Bool {
        lhs.summary.id == rhs.summary.id
            && lhs.summary.title == rhs.summary.title
            && lhs.summary.isPinned == rhs.summary.isPinned
            && lhs.summary.messageCount == rhs.summary.messageCount
            && lhs.summary.updateAt == rhs.summary.updateAt
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isGenerating == rhs.isGenerating
            && lhs.listPreview == rhs.listPreview
            && lhs.listIconKey == rhs.listIconKey
            && lhs.slice == rhs.slice
            && lhs.hidesSeparator == rhs.hidesSeparator
    }

    var body: some View {
        let ambient = AmberTheme.cardShadowAmbientGeometry(for: colorScheme)
        Button(action: onTap) {
            HStack(spacing: 13) {
                iconView

                VStack(alignment: .leading, spacing: 7) {
                    Text(displayTitle)
                        .font(.system(size: conversationTitleSize, weight: .semibold))
                        .tracking(-0.08)
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(2)
                    metaLine
                        .opacity(metaOpacity)
                        .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 28 : 0)
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .frame(minHeight: 72)
            .padding(.leading, 17).padding(.trailing, 16)
            .background {
                // 卡面实色 +（纹理主题）卡内淡网格 + 当前行浅染。
                // 网格叠在实色上、选中晕之下，字仍坐在不透明面上，但 session 框内有方格/点阵感。
                let fill = ZStack {
                    HomeSliceShape(slice: slice).fill(AmberTheme.card)
                    HomeCardCanvasTexture()
                        .clipShape(HomeSliceShape(slice: slice))
                    HomeSliceShape(slice: slice)
                        .fill(isCurrent ? AmberTheme.activeCard : Color.clear)
                        .animation(homeCurrentBandMotion, value: isCurrent)
                }
                // 一体卡投影：仅 top/bottom/single 携带，middle 无影防接缝。
                switch slice {
                case .single:
                    fill
                        .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
                        .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
                case .bottom:
                    fill
                        .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
                        .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
                        .mask(
                            Rectangle()
                                .padding(.horizontal, -48)
                                .padding(.bottom, -48)
                                .padding(.top, 0)
                        )
                case .top:
                    fill
                        .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
                        .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
                        .mask(
                            Rectangle()
                                .padding(.horizontal, -48)
                                .padding(.top, -48)
                                .padding(.bottom, 0)
                        )
                case .middle:
                    fill
                }
            }
            .overlay {
                if pressed {
                    HomeSliceShape(slice: slice)
                        .fill(AmberTheme.press)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if !hidesSeparator {
                    // 卡内 hairline：略强于旧 sep token，仍左缩进对齐标题。
                    Rectangle()
                        .fill(AmberTheme.foreground.opacity(0.08))
                        .frame(height: max(1 / displayScale, 0.5))
                        .padding(.leading, 70)
                        .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomePressStateStyle(pressed: $pressed, scale: 0.98, scaleAnchor: .leading))
        .accessibilityLabel(accessibilityRowLabel)
        // 主操作:Apple Music 同款左右滑动(原生 List swipeActions，iOS 26 自带 Liquid Glass 渲染)。
        // 右滑→删除(整行划到底触发确认) / 重命名;左滑→置顶切换。删除只打开二次确认，真正删在 alert 确认后。
        // 故意不用 role: .destructive：List 会把它当“立即删除”先把行动画移走，数据还在时确认弹窗下就会闪一下又弹回。
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // 危险色靠显式 .tint(.red)；不用 role: .destructive（见上）。未设 tint 时会继承 AppShell 强调色。
            Button(action: onDelete) {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
            Button(action: onRename) {
                Label("重命名", systemImage: "pencil")
            }
            .tint(AmberTheme.muted2)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: onTogglePin) {
                Label(summary.isPinned ? "取消置顶" : "置顶",
                      systemImage: summary.isPinned ? "pin.slash" : "pin")
            }
            .tint(AmberTheme.muted2)
        }
        // 次操作:保留长按上下文菜单(与 Apple Music 一致，两种入口并存)。
        .contextMenu {
            Button {
                onTogglePin()
            } label: {
                Label(summary.isPinned ? "取消置顶" : "置顶",
                      systemImage: summary.isPinned ? "pin.slash" : "pin")
            }
            Button {
                onRename()
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Menu {
                ForEach(IOSConversationExportFormat.allCases) { format in
                    Button(format.title, systemImage: format.systemImage) {
                        onExport(format)
                    }
                }
            } label: {
                Label("导出对话", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .onAppear { restartMetaCycleIfNeeded() }
        .onChange(of: isCurrent) { _, _ in restartMetaCycleIfNeeded() }
        .onChange(of: listPreview) { _, _ in restartMetaCycleIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in restartMetaCycleIfNeeded() }
        .onDisappear {
            metaCycleTask?.cancel()
            metaCycleTask = nil
        }
    }

    private var accessibilityRowLabel: String {
        var label = IOSAppLocalization.formatted(
            "会话 %@，%@ 条消息",
            defaultValue: "会话 %@，%@ 条消息",
            arguments: [displayTitle, String(summary.messageCount)]
        )
        if summary.isPinned {
            label += "，" + IOSAppLocalization.string("已置顶", defaultValue: "已置顶")
        }
        if isGenerating {
            label += "，" + IOSAppLocalization.string("正在生成", defaultValue: "正在生成")
        }
        // 不跟 4.2s 轮播抢读：有浓缩预览时固定附带一句，避免动态切换。
        if isCurrent, !listPreview.isEmpty { label += "，\(listPreview)" }
        return label
    }

    @ViewBuilder
    private var metaLine: some View {
        if showingListPreview, !listPreview.isEmpty, isCurrent {
            Text(listPreview)
                .font(.system(size: conversationMetadataSize, weight: .regular))
                .tracking(0.11)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                Text(relativeTime)
                    .font(.system(size: conversationMetadataSize, weight: .regular)).tracking(0.11)
                    .foregroundStyle(AmberTheme.muted)
                Text("·")
                    .font(.system(size: conversationMetadataSize, weight: .regular))
                    .foregroundStyle(AmberTheme.muted2)
                Text(
                    IOSAppLocalization.formatted(
                        "%d 条",
                        defaultValue: "%d 条",
                        arguments: [Int32(summary.messageCount)]
                    )
                )
                    .font(.system(size: conversationMetadataSize, weight: .regular)).tracking(0.11)
                    .foregroundStyle(AmberTheme.muted)
            }
            .monospacedDigit()
        }
    }

    /// 当前行色带 / 头像色切换：短 ease，不 spring。
    private var homeCurrentBandMotion: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    private var iconView: some View {
        ZStack {
            Circle()
                .fill(isCurrent ? AmberTheme.avatarActive : AmberTheme.avatarIdle)
                .animation(homeCurrentBandMotion, value: isCurrent)
            if summary.isPinned {
                HomePhosphorIcon(.pushPin, size: 20)
                    .foregroundStyle(isCurrent ? AmberTheme.avatarActiveInk : AmberTheme.avatarIdleInk)
                    .animation(homeCurrentBandMotion, value: isCurrent)
            } else {
                HomePhosphorIcon(
                    HomeConversationIcon.icon(
                        forTitle: displayTitle,
                        isPinned: false,
                        preferredKey: listIconKey
                    ),
                    size: 20
                )
                    .foregroundStyle(isCurrent ? AmberTheme.avatarActiveInk : AmberTheme.avatarIdleInk)
                    .animation(homeCurrentBandMotion, value: isCurrent)
                    .animation(homeCurrentBandMotion, value: listIconKey)
            }
            if isGenerating {
                ConversationGeneratingRing()
            }
        }
        .frame(width: 40, height: 40)
        // 光晕在 background 且自裁 64pt：余光可见，仍尽量少渗邻行。
        .background {
            if isCurrent {
                CurrentConversationAvatarGlow()
                    .frame(
                        width: HomeCurrentAvatarBreath.clipSize,
                        height: HomeCurrentAvatarBreath.clipSize
                    )
                    .clipped()
            }
        }
    }

    /// 空标题统一走「新对话」占位语义：行文本、搜索匹配与图标映射同一输入。
    private var displayTitle: String {
        summary.title.isEmpty
            ? IOSAppLocalization.string("新对话", defaultValue: "新对话")
            : summary.title
    }

    /// 相对时间：updateAt -> "刚刚 / N分钟前 / N小时前 / 昨天 / M月D日"。
    private var relativeTime: String {
        let ms = summary.updateAt.toEpochMilliseconds()
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// E 版 meta 淡切：~4.2s 一轮，0.4s 淡出换文；仅当前会话且有浓缩预览时启用。
    private func restartMetaCycleIfNeeded() {
        metaCycleTask?.cancel()
        metaCycleTask = nil
        showingListPreview = false
        metaOpacity = 1
        guard isCurrent, !listPreview.isEmpty, !reduceMotion else { return }
        metaCycleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_200_000_000)
                guard !Task.isCancelled else { return }
                // 与 E 版 `.hm-m` 0.4s ease 淡切对齐
                withAnimation(.easeInOut(duration: 0.4)) { metaOpacity = 0 }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                showingListPreview.toggle()
                withAnimation(.easeInOut(duration: 0.4)) { metaOpacity = 1 }
            }
        }
    }
}

private struct ConversationGeneratingRing: View {
    @State private var isRotating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            ring.rotationEffect(.degrees(-90))
        } else {
            ring
                .rotationEffect(.degrees(isRotating ? 270 : -90))
                .animation(
                    .linear(duration: 0.9).repeatForever(autoreverses: false),
                    value: isRotating
                )
                .onAppear { isRotating = true }
                .onDisappear {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isRotating = false }
                }
        }
    }

    private var ring: some View {
        Circle()
            .trim(from: 0.0, to: 0.78)
            .stroke(
                AmberTheme.foreground2,
                style: StrokeStyle(lineWidth: 1.05, lineCap: .round)
            )
            .accessibilityHidden(true)
    }
}

/// E 版原型 `hm-breathe`：当前会话头像光晕呼吸（已压低，避免 accent 下过曝）。
/// 时序仍 1.6s delay / 3.4s period；视觉只做轻余光。
enum HomeCurrentAvatarBreath {
    static let delaySeconds: TimeInterval = 1.6
    static let periodSeconds: TimeInterval = 3.4
    static let blurRadius: CGFloat = 5
    /// 相对 40pt 头像外扩（收紧，少渗邻行）。
    static let spread: CGFloat = 2
    static let clipSize: CGFloat = 52
    /// 峰值再压一层，强度曲线仍 0…1。
    static let peakOpacity: Double = 0.55

    /// Core Animation 按同一余弦曲线采样，避免 SwiftUI 每帧重算模糊视图。
    static let opacityKeyframes: [NSNumber] = (0...60).map { index in
        let elapsed = delaySeconds + Double(index) / 60 * periodSeconds
        return NSNumber(value: intensity(elapsed: elapsed, reduceMotion: false) * peakOpacity)
    }
    static let opacityKeyTimes: [NSNumber] = (0...60).map { NSNumber(value: Double($0) / 60) }

    /// 0…1。Reduce Motion 时恒为 0。
    static func intensity(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0 }
        guard elapsed >= delaySeconds else { return 0 }
        let phase = ((elapsed - delaySeconds) / periodSeconds)
            .truncatingRemainder(dividingBy: 1)
        return 0.5 - 0.5 * cos(phase * 2 * .pi)
    }
}

/// 仅挂在 `isCurrent` 会话头像后：轻量外溢光晕，不参与布局命中。
private struct CurrentConversationAvatarGlow: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 显式观察主题输入；UIColor 动态颜色闭包本身不会触发 SwiftUI Observation。
        let accentHex = AmberThemeRuntime.shared.accentHex
        let paper = AmberThemeRuntime.shared.paper
        AvatarGlowOpacityHost(
            start: start,
            reduceMotion: reduceMotion,
            accentHex: accentHex,
            paper: paper
        ) {
            let diameter = 40 + HomeCurrentAvatarBreath.spread * 2
            // 单环 soft blur，去掉双层叠晕（叠晕在 accent 下易过曝）。
            Circle()
                .fill(AmberTheme.activeAvatarGlow)
                .frame(width: diameter, height: diameter)
                .blur(radius: HomeCurrentAvatarBreath.blurRadius)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 用宿主 layer 驱动静态光晕的透明度，保留 SwiftUI 主题颜色和模糊效果。
private struct AvatarGlowOpacityHost<Content: View>: UIViewControllerRepresentable {
    let start: Date
    let reduceMotion: Bool
    let accentHex: UInt32
    let paper: AmberThemeRuntime.Paper
    let content: Content

    init(
        start: Date,
        reduceMotion: Bool,
        accentHex: UInt32,
        paper: AmberThemeRuntime.Paper,
        @ViewBuilder content: () -> Content
    ) {
        self.start = start
        self.reduceMotion = reduceMotion
        self.accentHex = accentHex
        self.paper = paper
        self.content = content()
    }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        updateOpacityAnimation(on: controller.view.layer)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content
        updateOpacityAnimation(on: controller.view.layer)
    }

    static func dismantleUIViewController(_ controller: UIHostingController<Content>, coordinator: ()) {
        controller.view.layer.removeAnimation(forKey: "homeAvatarGlowBreath")
    }

    private func updateOpacityAnimation(on layer: CALayer) {
        layer.removeAnimation(forKey: "homeAvatarGlowBreath")
        layer.opacity = 0
        guard !reduceMotion else { return }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = HomeCurrentAvatarBreath.opacityKeyframes
        animation.keyTimes = HomeCurrentAvatarBreath.opacityKeyTimes
        animation.calculationMode = .linear
        animation.duration = HomeCurrentAvatarBreath.periodSeconds
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            + HomeCurrentAvatarBreath.delaySeconds
            - Date().timeIntervalSince(start)
        animation.repeatCount = .infinity
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "homeAvatarGlowBreath")
    }
}

struct SearchView: View {
    @Environment(RouterPath.self) private var router
    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(ChatViewModel.self) private var chatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var selectedFilter: SearchFilter = .all
    @State private var results: [IOSConversationSearchResult] = []
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    init(initialQuery: String = "") {
        self._query = State(initialValue: initialQuery)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleResults: [IOSConversationSearchResult] {
        guard !trimmedQuery.isEmpty else { return [] }
        return results.filter { selectedFilter.includes($0.kind) }
    }

    private var recentSummaries: [ConversationSummary] {
        Array(conversationStore.summaries.prefix(8))
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                searchNavigation
                filterStrip

                if trimmedQuery.isEmpty {
                    recentConversationList
                } else {
                    resultList
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            searchFocused = true
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 220_000_000)
            if !Task.isCancelled {
                await performSearch()
            }
        }
    }

    private var searchNavigation: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AmberTheme.muted)

                TextField("搜索会话与消息", text: $query)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .tint(AmberTheme.accent)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        Task { @MainActor in
                            await performSearch()
                        }
                    }

                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(AmberTheme.muted2, in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(query.isEmpty ? 0 : 1)
                .accessibilityLabel("清空搜索")
            }
            .frame(height: 38)
            .padding(.horizontal, 12)
            .amberGlass(cornerRadius: 12)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
            }

            Button("取消") {
                dismiss()
            }
            .font(.body)
            .foregroundStyle(AmberTheme.accent)
            .buttonStyle(.plain)
            .accessibilityLabel("取消搜索")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal) {
            AmberGlassGroup(spacing: 8) {
                HStack(spacing: 12) {
                    ForEach(SearchFilter.allCases) { filter in
                        Button {
                            selectedFilter = filter
                        } label: {
                            AmberGlassTextChip(
                                title: IOSAppLocalization.string(
                                    filter.title,
                                    defaultValue: filter.title
                                ),
                                isSelected: selectedFilter == filter,
                                height: 30,
                                horizontalPadding: 13,
                                font: .system(size: 13.5, weight: .medium)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 10)
    }

    private var recentConversationList: some View {
        ScrollView {
            VStack(spacing: 0) {
                AmberSectionLabel(text: "最近会话")
                    .padding(.top, -8)

                if recentSummaries.isEmpty {
                    ContentUnavailableView("还没有会话", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(AmberTheme.muted)
                        .padding(.top, 72)
                } else {
                    AmberFormGroup {
                        ForEach(Array(recentSummaries.enumerated()), id: \.element.id) { index, summary in
                            RecentConversationSearchRow(summary: summary) {
                                openConversation(summary.id)
                            }

                            if index < recentSummaries.count - 1 {
                                Divider()
                                    .overlay(AmberTheme.borderSoft)
                                    .padding(.leading, 66)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    private var resultList: some View {
        ScrollView {
            if isSearching {
                ProgressView()
                    .tint(AmberTheme.accent)
                    .padding(.top, 72)
            } else if visibleResults.isEmpty {
                ContentUnavailableView("没有结果", systemImage: "magnifyingglass", description: Text("换个关键词或筛选范围再试一次"))
                    .foregroundStyle(AmberTheme.muted)
                    .padding(.top, 72)
            } else {
                VStack(spacing: 0) {
                    ForEach(groupedResults, id: \.group) { group in
                        SearchResultGroup(title: group.group, rows: group.rows) { result in
                            openConversation(result.conversationId)
                        }
                    }
                }
                .padding(.bottom, 36)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var groupedResults: [(group: String, rows: [IOSConversationSearchResult])] {
        SearchFilter.resultGroups.compactMap { kind in
            let rows = visibleResults.filter { $0.kind == kind }
            return rows.isEmpty ? nil : (kind.title, rows)
        }
    }

    @MainActor
    private func performSearch() async {
        let searchQuery = trimmedQuery
        guard !searchQuery.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let nextResults = await conversationStore.searchConversations(query: searchQuery)
        if !Task.isCancelled, trimmedQuery == searchQuery {
            results = nextResults
            isSearching = false
        }
    }

    private func openConversation(_ id: KotlinUuid) {
        Task { @MainActor in
            let isAlreadyCurrent = conversationStore.currentConversation?.id == id
            guard chatViewModel.prepareForConversationChange(to: id) else { return }
            if !isAlreadyCurrent {
                await conversationStore.selectConversation(id: id)
            }
            router.navigate(to: .chat)
        }
    }
}

private enum SearchFilter: String, CaseIterable, Identifiable {
    case all
    case conversation
    case message

    static let resultGroups: [IOSConversationSearchResult.Kind] = [.conversation, .message]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .conversation: "会话"
        case .message: "消息"
        }
    }

    func includes(_ kind: IOSConversationSearchResult.Kind) -> Bool {
        switch self {
        case .all:
            true
        case .conversation:
            kind == .conversation
        case .message:
            kind == .message
        }
    }
}

private struct RecentConversationSearchRow: View {
    let summary: ConversationSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SearchRowChrome(
                systemImage: summary.isPinned ? "pin.fill" : "bubble.left.fill",
                color: AmberTheme.accent,
                title: summary.title.isEmpty
                    ? IOSAppLocalization.string("新对话", defaultValue: "新对话")
                    : summary.title,
                preview: IOSAppLocalization.formatted(
                    "%@ 条消息",
                    defaultValue: "%@ 条消息",
                    arguments: [String(summary.messageCount)]
                ),
                highlight: "",
                time: relativeTime(ms: summary.updateAt.toEpochMilliseconds())
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SearchResultGroup: View {
    let title: String
    let rows: [IOSConversationSearchResult]
    let action: (IOSConversationSearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(
                verbatim: IOSAppLocalization.string(title, defaultValue: title)
            )
                .padding(.top, -8)

            AmberFormGroup {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    SearchResultRow(row: row) {
                        action(row)
                    }

                    if index < rows.count - 1 {
                        Divider()
                            .overlay(AmberTheme.borderSoft)
                            .padding(.leading, 66)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }
}

private struct SearchResultRow: View {
    let row: IOSConversationSearchResult
    let action: () -> Void

    private var systemImage: String {
        row.kind == .conversation ? "bubble.left.fill" : "text.bubble.fill"
    }

    private var color: Color {
        row.kind == .conversation ? AmberTheme.accent : AmberTheme.accentCyan
    }

    var body: some View {
        Button(action: action) {
            SearchRowChrome(
                systemImage: systemImage,
                color: color,
                title: row.title,
                preview: row.preview,
                highlight: row.highlight,
                time: relativeTime(ms: row.updateAt)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SearchRowChrome: View {
    let systemImage: String
    let color: Color
    let title: String
    let preview: String
    let highlight: String
    let time: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)

                HighlightedPreview(text: preview, highlight: highlight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(time)
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                .padding(.top, 1)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct HighlightedPreview: View {
    let text: String
    let highlight: String

    var body: some View {
        if let range = text.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]), !highlight.isEmpty {
            HStack(spacing: 0) {
                Text(String(text[..<range.lowerBound]))
                Text(String(text[range]))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 2)
                    .background(AmberTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(String(text[range.upperBound...]))
            }
            .font(.subheadline)
            .foregroundStyle(AmberTheme.muted)
            .lineLimit(1)
        } else {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(1)
        }
    }
}

private func relativeTime(ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

struct SettingsHomeView: View {
    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore

    @Environment(RouterPath.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage(IOSAppearancePreferenceKeys.mode) private var appearanceMode = IOSAppearanceMode.system.rawValue
    @AppStorage(IOSAppLanguagePreference.defaultsKey) private var appLanguage = IOSAppLanguage.system.rawValue

    // 方案 B：全表统一 accent 图标 + accentTint 浅底，取消彩虹 per-row 色。
    private var generalEntries: [SettingsHomeEntry] {
        [
            .init(title: "外观", value: appearanceModeTitle, systemImage: "circle.lefthalf.filled", route: .appearance),
            .init(
                title: IOSAppLocalization.string("language.title", language: selectedLanguage),
                value: languageTitle,
                systemImage: "globe",
                route: .language
            ),
            .init(title: "显示与字体", systemImage: "slider.horizontal.3", route: .displayFont),
            .init(title: "Apple Watch", systemImage: "applewatch", route: .appleWatch),
            .init(title: "Mac Gateway", systemImage: "desktopcomputer", route: .macGateway)
        ]
    }

    private var agentEntries: [SettingsHomeEntry] {
        [
            .init(title: "灵魂与记忆", systemImage: "cylinder.split.1x2", route: .memory),
            .init(title: "运行环境", systemImage: "terminal", route: .execution),
            .init(title: "技能", systemImage: "wrench.and.screwdriver", route: .skills),
            .init(title: "权限与批准", systemImage: "shield", route: .toolPermissions)
        ]
    }

    private var modelServiceEntries: [SettingsHomeEntry] {
        [
            .init(title: "服务商", systemImage: "server.rack", route: .providers),
            .init(title: "模型与提示词", systemImage: "cpu", route: .modelDefaults),
            .init(title: "搜索服务", systemImage: "magnifyingglass", route: .searchServices),
            .init(title: "语音服务", systemImage: "speaker.wave.2", route: .ttsSettings)
        ]
    }

    private var advancedFeatureEntries: [SettingsHomeEntry] {
        [
            .init(title: "WebMount", systemImage: "globe", route: .webMount),
            .init(title: "子代理", systemImage: "person.2", route: .subagents),
            .init(title: "模型议会", systemImage: "bubble.left.and.bubble.right", route: .council),
            .init(title: "小应用", systemImage: "square.grid.2x2", route: .miniApps),
            .init(title: "小说创作", systemImage: "text.book.closed", route: .novelCreation),
            .init(title: "深度阅读", systemImage: "book.pages", route: .board)
        ]
    }

    private var dataEntries: [SettingsHomeEntry] {
        [
            .init(title: "Amber Pro", subtitle: "订阅与恢复购买", systemImage: "checkmark.seal", route: .subscription),
            .init(title: "Workspace", systemImage: "folder.badge.gearshape", route: .workspace),
            .init(title: "同步备份", systemImage: "icloud", route: .syncBackup),
            .init(title: "对话存储", systemImage: "tray.full", route: .conversationStorage)
        ]
    }

    private var appearanceModeTitle: String {
        let title = (IOSAppearanceMode(rawValue: appearanceMode) ?? .light).title
        return IOSAppLocalization.string(title, defaultValue: title)
    }

    private var selectedLanguage: IOSAppLanguage {
        IOSAppLanguage(storedValue: appLanguage)
    }

    private var languageTitle: String {
        if selectedLanguage == .system {
            return IOSAppLocalization.string("language.follow_system", language: .system)
        }
        return selectedLanguage.nativeDisplayName
    }

    /// 与首页顶栏账户入口同源：昵称首字，空昵称回落 "A"。
    private var accountInitial: String {
        let trimmed = sharedSettings.displaySetting.userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "A" : trimmed).prefix(1)).uppercased()
    }

    var body: some View {
        // snapshot 为 @ObservationIgnored；读 revision 才能在改昵称后刷新头像首字。
        let _ = sharedSettings.revision
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    settingsSection("通用设置", entries: generalEntries)
                    settingsSection("Agent 设置", entries: agentEntries)
                    settingsSection("模型与服务", entries: modelServiceEntries)
                    settingsSection("高级功能", entries: advancedFeatureEntries)
                    settingsSection("数据设置", entries: dataEntries)
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            Text("设置")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            // 右上点缀：与首页头像同组件、同 .account 路由；44 占位与返回钮对称，头像本体 38。
            Button {
                router.navigate(to: .account)
            } label: {
                HomeAccountAvatar(initial: accountInitial, size: 38)
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.92, haptic: .lightImpact))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("我的账户")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private func settingsSection(_ title: LocalizedStringKey, entries: [SettingsHomeEntry]) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: title)
            AmberFormGroup {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    AmberFormRow(
                        systemImage: entry.systemImage,
                        iconColor: AmberTheme.accent,
                        iconUsesAccentPlate: true,
                        title: entry.title,
                        subtitle: entry.subtitle,
                        trailing: entry.value,
                        showsChevron: true
                    ) {
                        router.navigate(to: entry.route)
                    }

                    if index < entries.count - 1 {
                        Divider()
                            .overlay(AmberTheme.borderSoft)
                            // 与行内文字起点对齐：hPad 14 + icon 28 + spacing 12
                            .padding(.leading, 54)
                    }
                }
            }
        }
    }

    private func placeholder(_ title: String, _ subtitle: String, _ systemImage: String) -> Route {
        .settingsPlaceholder(title: title, subtitle: subtitle, systemImage: systemImage)
    }
}

private struct SettingsHomeEntry: Identifiable {
    var id: Route { route }
    let title: String
    let subtitle: String?
    let value: String?
    let systemImage: String
    let route: Route

    init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        systemImage: String,
        route: Route
    ) {
        self.title = IOSAppLocalization.string(title, defaultValue: title)
        self.subtitle = subtitle.map {
            IOSAppLocalization.string($0, defaultValue: $0)
        }
        self.value = value
        self.systemImage = systemImage
        self.route = route
    }
}

struct WorkspaceView: View {
    @Bindable var workspaceStore: IOSWorkspaceStore
    let focusedItemId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var isImportingFile = false
    @State private var selectedFile: IOSWorkspaceFileRecord?
    @State private var selectedArtifact: IOSWorkspaceArtifactRecord?
    @State private var alertMessage: String?

    init(workspaceStore: IOSWorkspaceStore = .shared, focusedItemId: String? = nil) {
        self.workspaceStore = workspaceStore
        self.focusedItemId = focusedItemId
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    workspaceStats
                    filesSection
                    artifactsSection
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(item: $selectedFile) { record in
            WorkspaceFileDetailSheet(
                record: record,
                store: workspaceStore,
                onReparse: {
                    Task { await reparse(record) }
                },
                onRemove: {
                    removeFile(record)
                }
            )
        }
        .sheet(item: $selectedArtifact) { record in
            WorkspaceArtifactDetailSheet(
                record: record,
                store: workspaceStore,
                onDelete: {
                    deleteArtifact(record)
                }
            )
        }
        .alert("Workspace", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear {
            focusInitialItem()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Workspace")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                Text("文件上下文与生成结果")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }

            Spacer()

            Button {
                isImportingFile = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(AmberTheme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导入文件")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var workspaceStats: some View {
        HStack(spacing: 10) {
            WorkspaceMetricCard(
                title: "文件",
                value: "\(workspaceStore.files.count)",
                systemImage: "doc.text",
                color: AmberTheme.accentIndigo
            )
            WorkspaceMetricCard(
                title: "Artifacts",
                value: "\(workspaceStore.artifacts.count)",
                systemImage: "sparkles.rectangle.stack",
                color: AmberTheme.accentAmber
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var filesSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "文件")
            if workspaceStore.recentFiles.isEmpty {
                WorkspaceEmptyState(
                    systemImage: "doc.badge.plus",
                    title: "还没有导入文件",
                    subtitle: "通过 Files 选择的文件会复制进 AmberAgent 的本地 Workspace，不会自动扫描用户目录。"
                )
            } else {
                AmberFormGroup {
                    ForEach(Array(workspaceStore.recentFiles.enumerated()), id: \.element.id) { index, file in
                        WorkspaceFileRow(record: file) {
                            selectedFile = workspaceStore.fileRecord(idOrPath: file.id) ?? file
                        }
                        if index < workspaceStore.recentFiles.count - 1 {
                            Divider()
                                .overlay(AmberTheme.borderSoft)
                                .padding(.leading, 58)
                        }
                    }
                }
            }
        }
    }

    private var artifactsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "Artifacts")
            if workspaceStore.recentArtifacts.isEmpty {
                WorkspaceEmptyState(
                    systemImage: "tray",
                    title: "还没有保存的 Artifact",
                    subtitle: "聊天、MiniApp、Deep Read 或工具输出可以保存到这里统一管理。"
                )
            } else {
                AmberFormGroup {
                    ForEach(Array(workspaceStore.recentArtifacts.enumerated()), id: \.element.id) { index, artifact in
                        WorkspaceArtifactRow(record: artifact) {
                            selectedArtifact = workspaceStore.artifacts.first { $0.id == artifact.id } ?? artifact
                        }
                        if index < workspaceStore.recentArtifacts.count - 1 {
                            Divider()
                                .overlay(AmberTheme.borderSoft)
                                .padding(.leading, 58)
                        }
                    }
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                alertMessage = "没有选择文件。"
                return
            }
            Task {
                do {
                    let record = try await workspaceStore.importFile(url: url, source: "workspace_picker")
                    selectedFile = record
                } catch {
                    alertMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            alertMessage = "文件选择失败：\(error.localizedDescription)"
        }
    }

    private func reparse(_ record: IOSWorkspaceFileRecord) async {
        do {
            selectedFile = try await workspaceStore.reparseFile(id: record.id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func removeFile(_ record: IOSWorkspaceFileRecord) {
        do {
            try workspaceStore.removeFile(id: record.id)
            selectedFile = nil
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func deleteArtifact(_ record: IOSWorkspaceArtifactRecord) {
        do {
            try workspaceStore.deleteArtifact(id: record.id)
            selectedArtifact = nil
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func focusInitialItem() {
        guard let focusedItemId else { return }
        if let file = workspaceStore.fileRecord(idOrPath: focusedItemId) {
            selectedFile = file
            return
        }
        if let artifact = workspaceStore.artifacts.first(where: { $0.id == focusedItemId }) {
            selectedArtifact = artifact
        }
    }
}

struct AssistantsView: View {
    var body: some View {
        PlaceholderDetailView(
            title: "Amber Assistant",
            subtitle: "iOS 只保留一个 Amber Assistant；模型、记忆与工具在设置中管理。",
            systemImage: "sparkles"
        )
    }
}

private struct WorkspaceMetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AmberTheme.foreground)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }
}

private struct WorkspaceEmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AmberTheme.muted2)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
    }
}

private struct WorkspaceFileRow: View {
    let record: IOSWorkspaceFileRecord
    let action: () -> Void

    var body: some View {
        AmberFormRow(
            systemImage: statusIcon,
            iconColor: statusColor,
            title: record.displayName,
            subtitle: "\(record.byteSummary) · \(record.status.title) · /workspace/\(record.workspacePath)",
            trailing: WorkspaceDateFormat.short(record.updatedAtMillis),
            showsChevron: true,
            action: action
        )
    }

    private var statusIcon: String {
        switch record.status {
        case .ready: "doc.text"
        case .missing: "doc.badge.exclamationmark"
        case .parseFailed: "exclamationmark.triangle"
        case .unsupported: "nosign"
        case .tooLarge: "externaldrive.badge.exclamationmark"
        case .needsReauthorization: "lock.open"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .ready: AmberTheme.accentIndigo
        case .unsupported, .needsReauthorization: AmberTheme.accentAmber
        case .missing, .parseFailed, .tooLarge: AmberTheme.accentRed
        }
    }
}

private struct WorkspaceArtifactRow: View {
    let record: IOSWorkspaceArtifactRecord
    let action: () -> Void

    var body: some View {
        AmberFormRow(
            systemImage: "sparkles.rectangle.stack",
            iconColor: AmberTheme.accentAmber,
            title: record.title,
            subtitle: "\(record.type.title) · \(DocumentAccessStore.formatBytes(record.contentBytes))",
            trailing: WorkspaceDateFormat.short(record.updatedAtMillis),
            showsChevron: true,
            action: action
        )
    }
}

private struct WorkspaceFileDetailSheet: View {
    let record: IOSWorkspaceFileRecord
    @Bindable var store: IOSWorkspaceStore
    let onReparse: () -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkspaceDetailHeader(
                        systemImage: "doc.text",
                        title: record.displayName,
                        subtitle: "/workspace/\(record.workspacePath)"
                    )

                    WorkspaceInfoGrid(rows: [
                        ("状态", record.status.title),
                        ("大小", record.byteSummary),
                        ("类型", record.mimeType),
                        ("字符", "\(record.characterCount)"),
                        ("来源", record.source),
                        ("更新", WorkspaceDateFormat.long(record.updatedAtMillis))
                    ])

                    if !record.statusMessage.isEmpty {
                        WorkspaceStatusBanner(status: record.status, message: record.statusMessage)
                    }

                    WorkspacePreviewBlock(text: record.preview, emptyText: previewEmptyText)
                }
                .padding(16)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        onReparse()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新解析")

                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("移除文件")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var previewEmptyText: String {
        let key: String
        switch record.status {
        case .ready:
            key = "没有可预览文本。"
        case .missing:
            key = "文件副本丢失，请重新导入。"
        case .unsupported:
            key = "此格式暂不支持文本预览。"
        case .tooLarge:
            key = "文件超过本地解析上限。"
        case .needsReauthorization:
            key = "需要从 Files 重新选择文件。"
        case .parseFailed:
            key = "解析失败，可尝试重新解析。"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }
}

private struct WorkspaceArtifactDetailSheet: View {
    let record: IOSWorkspaceArtifactRecord
    @Bindable var store: IOSWorkspaceStore
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var content: String {
        (try? store.artifactContent(id: record.id)) ?? IOSAppLocalization.string(
            "Artifact 内容丢失或读取失败。",
            defaultValue: "Artifact 内容丢失或读取失败。"
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkspaceDetailHeader(
                        systemImage: "sparkles.rectangle.stack",
                        title: record.title,
                        subtitle: record.type.title
                    )
                    WorkspaceInfoGrid(rows: [
                        ("大小", DocumentAccessStore.formatBytes(record.contentBytes)),
                        ("来源", record.sourceKind),
                        ("创建", WorkspaceDateFormat.long(record.createdAtMillis)),
                        ("更新", WorkspaceDateFormat.long(record.updatedAtMillis))
                    ])
                    WorkspacePreviewBlock(
                        text: content,
                        emptyText: IOSAppLocalization.string(
                            "Artifact 内容为空。",
                            defaultValue: "Artifact 内容为空。"
                        )
                    )
                }
                .padding(16)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("删除 Artifact")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct WorkspaceDetailHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 42, height: 42)
                .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(3)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct WorkspaceInfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top) {
                    Text(verbatim: IOSAppLocalization.string(row.0, defaultValue: row.0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.muted)
                        .frame(width: 56, alignment: .leading)
                    Text(row.1)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 8)
                if index < rows.count - 1 {
                    Divider().overlay(AmberTheme.borderSoft)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
    }
}

private struct WorkspaceStatusBanner: View {
    let status: IOSWorkspaceFileStatus
    let message: String

    var body: some View {
        Label(message, systemImage: status == .ready ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(status == .ready ? AmberTheme.accentGreen : AmberTheme.accentAmber)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((status == .ready ? AmberTheme.accentGreen : AmberTheme.accentAmber).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct WorkspacePreviewBlock: View {
    let text: String
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: IOSAppLocalization.string("预览", defaultValue: "预览"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
                .textCase(.uppercase)
            Text(text.isEmpty ? emptyText : text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(text.isEmpty ? AmberTheme.muted : AmberTheme.foreground2)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        }
    }
}

private enum WorkspaceDateFormat {
    static func short(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func long(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let formatter = DateFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct PlaceholderListView: View {

    let title: String
    let systemImage: String
    let rows: [String]

    var body: some View {
        List {
            Section {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                ForEach(rows, id: \.self) { row in
                    Text(row)
                }
            }
        }
        .navigationTitle(title)
    }
}

struct PlaceholderDetailView: View {

    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(subtitle))
            .navigationTitle(title)
    }
}

struct CapabilityGateLockedView: View {
    let gate: IOSCapabilityGate

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentAmber)
                    .frame(width: 58, height: 58)
                    .background(AmberTheme.accentAmber.opacity(0.12), in: Circle())

                Text(gate.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)

                Text(gate.disabledReason)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 28)

                Text("这是 AmberAgent 的受控能力。默认关闭用于保护工具执行、外部连接和远程操作；可在设置页对应行开启。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 28)
            }
            .padding(.horizontal, 18)
        }
        .navigationBarBackButtonHidden(false)
    }
}
