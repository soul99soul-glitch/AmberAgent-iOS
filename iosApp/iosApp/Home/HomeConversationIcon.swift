import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

/// 会话列表右上角的账户头像:有自定义头像则显示图片,否则显示昵称首字母。
/// 出现时加载,并监听 `.accountAvatarChanged` 在换头像后即时刷新。
struct HomeAccountAvatar: View {
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
