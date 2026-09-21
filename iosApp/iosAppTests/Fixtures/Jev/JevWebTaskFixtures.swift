import Foundation
@testable import iosApp

// MARK: - Jev 网页循环对照语料（C11 / Phase B 网页侧）
//
// 20 个受控网页任务：每个任务是一个确定性的页面状态机（WebTaskWorld），
// 动作改变页面、revision 递增；完成判定只认页面/业务状态（isComplete），
// 不认任何模型的 DONE 声明。可解任务带 idealPolicy（理想动作序列），
// 用于离线证明语料可解且核验器正确；不可解任务（登录墙/验证码/停滞）
// 用来验证 handback 语义。Key 到位后，同一语料直接驱动
// IOSJevWebMountLoopService 做 baseline/Jev 对照。
//
// 动作词表与真实循环一致（ActionKind raw）：scroll / select / click_nav /
// type_draft / submit_readonly_search。observe 是观察端口不是动作，不在
// allowedActions 内。type_draft 的理想步骤带 value（真实循环缺值不出候选）。
// completionMarker 契约：marker 文本只在完成态页面出现，任何未完成页面
// （url+title+元素 label 拼接）都不得包含它——由语料测试强制。

/// 一步理想动作：action 与目标元素 id（nil = 无目标动作如 scroll）；
/// type_draft 步骤必须带 value。
struct WebTaskIdealStep: Equatable {
    var action: String
    var elementId: String?
    var value: String? = nil
}

/// 页面状态转移：在 fromPage 上执行 action(elementId) → 进入 toPage。
/// requiresTyped 非空时，仅当这些元素已成功 type_draft 过转移才生效
/// （草稿前置条件：未填内容点保存/预览 = 无转移 = failed）。
struct WebTaskTransition: Equatable {
    var action: String
    var elementId: String?
    var fromPage: Int
    var toPage: Int
    var requiresTyped: [String] = []
}

/// 受控网页任务。
struct WebTaskFixture {
    /// 页面：url/title/scrollY/元素列表。
    struct Page: Equatable {
        var url: String
        var title: String
        var scrollY: Int = 0
        var elements: [IOSJevWebMountLoopService.PageElement]
    }

    enum Solvability: Equatable {
        /// 可解：idealPolicy 依次执行后 isComplete 必须为真。
        case solvable([WebTaskIdealStep])
        /// 不可解：任何合法动作序列都不应使 isComplete 为真（期望 handback/交回）。
        case unsolvable
    }

    var id: String
    var goal: String
    /// 完成核验标记（wire 契约层）：只在完成态出现的文本；离线判定用 isComplete。
    var completionMarker: String
    var allowedActions: Set<String>
    var pages: [Page]
    var transitions: [WebTaskTransition]
    var solvability: Solvability
    /// 独立完成核验：只读页面状态（含 scrollY），不读模型结论。
    var isComplete: (Page, Int) -> Bool
}

/// 确定性页面世界：observe 给出当前页快照，execute 查转移表推进。
/// 未登记/前置不满足的动作 → failed；元素不存在 → failed。revision 单调递增。
final class WebTaskWorld {
    typealias Observation = IOSJevWebMountLoopService.PageObservation
    typealias Result = IOSJevWebMountLoopService.ExecutorResult

    let fixture: WebTaskFixture
    private(set) var pageIndex = 0
    private(set) var revision = 1
    private(set) var executedActions: [(action: String, elementId: String?)] = []
    /// 已成功 type_draft 的元素集合（草稿前置条件判据）。
    private(set) var typedElements: Set<String> = []

    init(fixture: WebTaskFixture) {
        self.fixture = fixture
    }

    var currentPage: WebTaskFixture.Page { fixture.pages[pageIndex] }

    var isComplete: Bool { fixture.isComplete(currentPage, revision) }

    func observation() -> Observation {
        let page = currentPage
        return Observation(
            snapshotId: "s\(revision)", revision: revision,
            url: page.url, elements: page.elements,
            scrollY: page.scrollY, title: page.title
        )
    }

    func execute(action: String, elementId: String?) -> Result {
        executedActions.append((action, elementId))
        if let elementId,
           !currentPage.elements.contains(where: { $0.id == elementId }) {
            return .failed(reason: "no_such_element:\(elementId)")
        }
        guard let transition = fixture.transitions.first(where: {
            $0.action == action && $0.elementId == elementId && $0.fromPage == pageIndex
                && $0.requiresTyped.allSatisfy { typedElements.contains($0) }
        }) else {
            return .failed(reason: "unexpected_action:\(action)")
        }
        pageIndex = transition.toPage
        revision += 1
        if action == "type_draft", let elementId { typedElements.insert(elementId) }
        return .applied(newRevision: revision)
    }
}

// MARK: - 语料

enum JevWebTaskCorpus {

    private static func el(_ id: String, _ role: String, _ label: String) -> IOSJevWebMountLoopService.PageElement {
        .init(id: id, role: role, label: label)
    }

    private static func t(
        _ action: String, _ elementId: String?, _ from: Int, _ to: Int,
        requiresTyped: [String] = []
    ) -> WebTaskTransition {
        .init(action: action, elementId: elementId, fromPage: from, toPage: to, requiresTyped: requiresTyped)
    }

    /// 语料只读且从不变异；闭包字段使 fixture 非 Sendable，用 nonisolated(unsafe)
    /// 声明不变量静态属性（测试侧惯例，同 JevStubTransport 的 @unchecked）。
    nonisolated(unsafe) static let all: [WebTaskFixture] = [
        // 1. 搜索：输入关键词 + 提交只读搜索 → 结果页含目标。
        WebTaskFixture(
            id: "search-keyword",
            goal: "搜索“加湿器”并看到结果列表",
            completionMarker: "搜索结果",
            allowedActions: ["type_draft", "submit_readonly_search", "scroll"],
            pages: [
                .init(url: "https://shop.example/", title: "商城首页", elements: [
                    el("q", "searchbox", "搜索商品"), el("nav", "link", "分类"),
                ]),
                .init(url: "https://shop.example/search", title: "搜索结果", elements: [
                    el("r1", "link", "加湿器 家用静音"), el("r2", "link", "除湿机"),
                ]),
            ],
            transitions: [
                t("type_draft", "q", 0, 0),
                t("submit_readonly_search", "q", 0, 1, requiresTyped: ["q"]),
            ],
            solvability: .solvable([.init(action: "type_draft", elementId: "q", value: "加湿器"),
                                    .init(action: "submit_readonly_search", elementId: "q")]),
            isComplete: { page, _ in page.title == "搜索结果" && page.elements.contains { $0.label.contains("加湿器") } }
        ),

        // 2. 搜索并打开条目。
        WebTaskFixture(
            id: "search-then-open",
            goal: "搜索“三体”并打开商品详情页",
            completionMarker: "商品详情",
            allowedActions: ["type_draft", "submit_readonly_search", "click_nav", "scroll"],
            pages: [
                .init(url: "https://shop.example/", title: "商城首页", elements: [el("q", "searchbox", "搜索商品")]),
                .init(url: "https://shop.example/search", title: "搜索结果", elements: [el("item", "link", "三体 典藏版"), el("other", "link", "流浪地球")]),
                .init(url: "https://shop.example/item/42", title: "商品详情", elements: [el("buy", "button", "加入购物车")]),
            ],
            transitions: [
                t("type_draft", "q", 0, 0), t("submit_readonly_search", "q", 0, 1, requiresTyped: ["q"]),
                t("click_nav", "item", 1, 2),
            ],
            solvability: .solvable([.init(action: "type_draft", elementId: "q", value: "三体"),
                                    .init(action: "submit_readonly_search", elementId: "q"),
                                    .init(action: "click_nav", elementId: "item")]),
            isComplete: { page, _ in page.url.hasSuffix("/item/42") && page.title == "商品详情" }
        ),

        // 3. 翻两页才见目标。
        WebTaskFixture(
            id: "paginate-to-target",
            goal: "在列表里找到“二手钢琴”条目",
            completionMarker: "二手钢琴",
            allowedActions: ["click_nav", "scroll"],
            pages: [
                .init(url: "https://list.example/?p=1", title: "列表 第1页", elements: [el("next", "link", "下一页"), el("a1", "link", "书架")]),
                .init(url: "https://list.example/?p=2", title: "列表 第2页", elements: [el("next", "link", "下一页"), el("b1", "link", "台灯")]),
                .init(url: "https://list.example/?p=3", title: "列表 第3页", elements: [el("target", "link", "二手钢琴 九成新")]),
            ],
            transitions: [t("click_nav", "next", 0, 1), t("click_nav", "next", 1, 2)],
            solvability: .solvable([.init(action: "click_nav", elementId: "next"),
                                    .init(action: "click_nav", elementId: "next")]),
            isComplete: { page, _ in page.elements.contains { $0.label.contains("二手钢琴") } }
        ),

        // 4. 选择筛选项。
        WebTaskFixture(
            id: "filter-select",
            goal: "把价格筛选设为“100元以下”并看到筛选结果",
            completionMarker: "已选：100元以下",
            allowedActions: ["select", "scroll"],
            pages: [
                .init(url: "https://shop.example/c", title: "分类页", elements: [el("price", "combobox", "价格筛选"), el("x", "link", "收纳箱")]),
                .init(url: "https://shop.example/c?f=1", title: "分类页（已选：100元以下）", elements: [el("cheap", "link", "化妆棉")]),
            ],
            transitions: [t("select", "price", 0, 1)],
            solvability: .solvable([.init(action: "select", elementId: "price")]),
            isComplete: { page, _ in page.title.contains("已选：100元以下") }
        ),

        // 5. 滚动两次才加载出目标，再点击。
        WebTaskFixture(
            id: "scroll-reveal-click",
            goal: "在信息流里找到并打开“露营攻略”",
            completionMarker: "露营攻略 正文",
            allowedActions: ["scroll", "click_nav"],
            pages: [
                .init(url: "https://feed.example/", title: "信息流", scrollY: 0, elements: [el("f1", "link", "早餐食谱")]),
                .init(url: "https://feed.example/", title: "信息流", scrollY: 800, elements: [el("f1", "link", "早餐食谱"), el("f2", "link", "通勤歌单")]),
                .init(url: "https://feed.example/", title: "信息流", scrollY: 1600, elements: [el("f1", "link", "早餐食谱"), el("f2", "link", "通勤歌单"), el("camp", "link", "露营攻略 2026")]),
                .init(url: "https://feed.example/post/9", title: "露营攻略", elements: [el("body", "article", "露营攻略 正文")]),
            ],
            transitions: [
                t("scroll", nil, 0, 1), t("scroll", nil, 1, 2),
                t("click_nav", "camp", 2, 3),
            ],
            solvability: .solvable([.init(action: "scroll", elementId: nil),
                                    .init(action: "scroll", elementId: nil),
                                    .init(action: "click_nav", elementId: "camp")]),
            isComplete: { page, _ in page.title == "露营攻略" && page.elements.contains { $0.label == "露营攻略 正文" } }
        ),

        // 6. 展开折叠区再点链接。
        WebTaskFixture(
            id: "expand-then-click",
            goal: "展开“更多服务”并打开“发票申请”",
            completionMarker: "申请表单",
            allowedActions: ["click_nav"],
            pages: [
                .init(url: "https://acct.example/", title: "账户", elements: [el("more", "button", "更多服务"), el("p", "link", "个人资料")]),
                .init(url: "https://acct.example/", title: "账户", elements: [el("more", "button", "更多服务"), el("inv", "link", "发票申请")]),
                .init(url: "https://acct.example/invoice", title: "发票申请", elements: [el("form", "form", "申请表单")]),
            ],
            transitions: [t("click_nav", "more", 0, 1), t("click_nav", "inv", 1, 2)],
            solvability: .solvable([.init(action: "click_nav", elementId: "more"),
                                    .init(action: "click_nav", elementId: "inv")]),
            isComplete: { page, _ in page.title == "发票申请" && page.elements.contains { $0.label == "申请表单" } }
        ),

        // 7. 组合：筛选 + 翻页。
        WebTaskFixture(
            id: "filter-and-paginate",
            goal: "筛选“防水”分类后翻到第 2 页找“户外手电”",
            completionMarker: "户外手电",
            allowedActions: ["select", "click_nav", "scroll"],
            pages: [
                .init(url: "https://shop.example/c", title: "分类页", elements: [el("cat", "combobox", "分类筛选")]),
                .init(url: "https://shop.example/c?cat=w", title: "分类页（防水）", elements: [el("next", "link", "下一页"), el("w1", "link", "防水背包")]),
                .init(url: "https://shop.example/c?cat=w&p=2", title: "分类页（防水）第2页", elements: [el("torch", "link", "户外手电 强光")]),
            ],
            transitions: [t("select", "cat", 0, 1), t("click_nav", "next", 1, 2)],
            solvability: .solvable([.init(action: "select", elementId: "cat"),
                                    .init(action: "click_nav", elementId: "next")]),
            isComplete: { page, _ in page.elements.contains { $0.label.contains("户外手电") } }
        ),

        // 8. 草稿输入：写评论草稿并点预览（不提交）；未打字点预览 = failed。
        WebTaskFixture(
            id: "draft-and-preview",
            goal: "把给定评论填入输入框并打开预览（不要发布）",
            completionMarker: "预览区",
            allowedActions: ["type_draft", "click_nav"],
            pages: [
                .init(url: "https://blog.example/post/1", title: "文章", elements: [el("c", "textbox", "写下你的评论"), el("prev", "button", "预览")]),
                .init(url: "https://blog.example/post/1", title: "文章（预览）", elements: [el("c", "textbox", "写下你的评论"), el("pv", "region", "预览区")]),
            ],
            transitions: [
                t("type_draft", "c", 0, 0),
                t("click_nav", "prev", 0, 1, requiresTyped: ["c"]),
            ],
            solvability: .solvable([.init(action: "type_draft", elementId: "c", value: "写得很好"),
                                    .init(action: "click_nav", elementId: "prev")]),
            isComplete: { page, _ in page.title.contains("预览") && page.elements.contains { $0.label == "预览区" } }
        ),

        // 9. 停滞陷阱：滚动永不带来新内容，目标不存在 → 不可解。
        WebTaskFixture(
            id: "stall-trap",
            goal: "找到“绝版邮票”条目",
            completionMarker: "绝版邮票",
            allowedActions: ["scroll", "click_nav"],
            pages: [
                .init(url: "https://feed.example/top", title: "信息流", scrollY: 0, elements: [el("n1", "link", "今日新闻")]),
                .init(url: "https://feed.example/top", title: "信息流", scrollY: 800, elements: [el("n1", "link", "今日新闻")]),
            ],
            transitions: [t("scroll", nil, 0, 1), t("scroll", nil, 1, 1)],
            solvability: .unsolvable,
            isComplete: { page, _ in page.elements.contains { $0.label.contains("绝版邮票") } }
        ),

        // 10. 登录墙：点目标链接进登录页 → 不可解（交回用户）。
        // marker 只描述目标态文本，在任何可达页面都不出现。
        WebTaskFixture(
            id: "login-wall",
            goal: "打开“我的订单”页查看最近订单",
            completionMarker: "最近订单",
            allowedActions: ["click_nav", "scroll"],
            pages: [
                .init(url: "https://acct.example/", title: "账户", elements: [el("orders", "link", "我的订单")]),
                .init(url: "https://acct.example/login", title: "请先登录", elements: [el("u", "textbox", "用户名"), el("p", "textbox", "密码")]),
            ],
            transitions: [t("click_nav", "orders", 0, 1)],
            solvability: .unsolvable,
            isComplete: { page, _ in page.title == "我的订单" }
        ),

        // 11. DONE 误判陷阱：首页标题就含“特卖”字样，但完成要求筛选后出现目标商品。
        WebTaskFixture(
            id: "done-misjudgment-trap",
            goal: "在特卖页筛选出“折叠椅”并看到它出现在结果中",
            completionMarker: "折叠椅",
            allowedActions: ["select", "scroll"],
            pages: [
                .init(url: "https://shop.example/sale", title: "特卖专场", elements: [el("cat", "combobox", "品类"), el("s1", "link", "帐篷")]),
                .init(url: "https://shop.example/sale?c=chair", title: "特卖专场（椅）", elements: [el("chair", "link", "折叠椅 便携")]),
            ],
            transitions: [t("select", "cat", 0, 1)],
            solvability: .solvable([.init(action: "select", elementId: "cat")]),
            isComplete: { page, _ in page.elements.contains { $0.label.contains("折叠椅") } }
        ),

        // 12. 验证码墙 → 不可解。
        WebTaskFixture(
            id: "captcha-wall",
            goal: "打开“优惠券中心”领取今日券",
            completionMarker: "今日券已领取",
            allowedActions: ["click_nav", "scroll"],
            pages: [
                .init(url: "https://shop.example/", title: "商城首页", elements: [el("coupon", "link", "优惠券中心")]),
                .init(url: "https://shop.example/captcha", title: "安全验证", elements: [el("cap", "region", "拖动滑块完成验证")]),
            ],
            transitions: [t("click_nav", "coupon", 0, 1)],
            solvability: .unsolvable,
            isComplete: { page, _ in page.title == "优惠券中心" }
        ),

        // 13. 重名歧义：两个“详情”链接，只有一个是目标（考目标身份）。
        WebTaskFixture(
            id: "ambiguous-labels",
            goal: "打开“降噪耳机”的详情页（不是其他商品）",
            completionMarker: "降噪耳机 详情",
            allowedActions: ["click_nav", "scroll"],
            pages: [
                .init(url: "https://shop.example/l", title: "列表", elements: [el("d-speaker", "link", "音箱 详情"), el("d-headphone", "link", "耳机 详情")]),
                .init(url: "https://shop.example/item/speaker", title: "音箱 详情", elements: []),
                .init(url: "https://shop.example/item/headphone", title: "降噪耳机 详情", elements: []),
            ],
            transitions: [t("click_nav", "d-speaker", 0, 1), t("click_nav", "d-headphone", 0, 2)],
            solvability: .solvable([.init(action: "click_nav", elementId: "d-headphone")]),
            isComplete: { page, _ in page.title == "降噪耳机 详情" }
        ),

        // 14. 元素身份漂移：滚动后同文案元素换新 id（按 id 复用旧目标必然失败）。
        WebTaskFixture(
            id: "identity-churn",
            goal: "滚动加载后打开“登山鞋”条目",
            completionMarker: "登山鞋 商品页",
            allowedActions: ["scroll", "click_nav"],
            pages: [
                .init(url: "https://feed.example/s", title: "户外", scrollY: 0, elements: [el("old-shoe", "link", "登山鞋 预售")]),
                .init(url: "https://feed.example/s", title: "户外", scrollY: 900, elements: [el("new-shoe", "link", "登山鞋 预售"), el("s2", "link", "冲锋衣")]),
                .init(url: "https://feed.example/item/7", title: "登山鞋 商品页", elements: [el("size", "region", "尺码选择")]),
            ],
            transitions: [
                t("scroll", nil, 0, 1),
                // 旧 id 在 page1 已不存在（world 会 failed），只有新 id 能推进。
                t("click_nav", "new-shoe", 1, 2),
            ],
            solvability: .solvable([.init(action: "scroll", elementId: nil),
                                    .init(action: "click_nav", elementId: "new-shoe")]),
            isComplete: { page, _ in page.title == "登山鞋 商品页" }
        ),

        // 15. 多字段草稿：标题+正文都填好后点“存草稿”（缺一 failed）。
        WebTaskFixture(
            id: "multi-field-draft",
            goal: "把给定的标题与正文填入编辑器并保存草稿（不发布）",
            completionMarker: "草稿已保存",
            allowedActions: ["type_draft", "click_nav"],
            pages: [
                .init(url: "https://note.example/new", title: "新建", elements: [el("title", "textbox", "标题"), el("body", "textbox", "正文"), el("save", "button", "存草稿")]),
                .init(url: "https://note.example/new?d=1", title: "新建（草稿已保存）", elements: [el("saved", "region", "草稿已保存")]),
            ],
            transitions: [
                t("type_draft", "title", 0, 0), t("type_draft", "body", 0, 0),
                t("click_nav", "save", 0, 1, requiresTyped: ["title", "body"]),
            ],
            solvability: .solvable([.init(action: "type_draft", elementId: "title", value: "周记"),
                                    .init(action: "type_draft", elementId: "body", value: "正文内容"),
                                    .init(action: "click_nav", elementId: "save")]),
            isComplete: { page, _ in page.title.contains("草稿已保存") }
        ),

        // 16. 最简单情形：目标立即可见，一次点击完成。
        WebTaskFixture(
            id: "direct-link",
            goal: "打开“帮助中心”",
            completionMarker: "常见问题",
            allowedActions: ["click_nav"],
            pages: [
                .init(url: "https://example.com/", title: "首页", elements: [el("help", "link", "帮助中心")]),
                .init(url: "https://example.com/help", title: "帮助中心", elements: [el("faq", "link", "常见问题")]),
            ],
            transitions: [t("click_nav", "help", 0, 1)],
            solvability: .solvable([.init(action: "click_nav", elementId: "help")]),
            isComplete: { page, _ in page.title == "帮助中心" && page.elements.contains { $0.label == "常见问题" } }
        ),

        // 17. 三次滚动到底部。
        WebTaskFixture(
            id: "scroll-to-bottom",
            goal: "滚到页面底部看到“到底啦”提示",
            completionMarker: "到底啦",
            allowedActions: ["scroll"],
            pages: [
                .init(url: "https://read.example/", title: "长文", scrollY: 0, elements: [el("p1", "article", "第一段")]),
                .init(url: "https://read.example/", title: "长文", scrollY: 1000, elements: [el("p2", "article", "中段")]),
                .init(url: "https://read.example/", title: "长文", scrollY: 2000, elements: [el("p3", "article", "后段")]),
                .init(url: "https://read.example/", title: "长文", scrollY: 3000, elements: [el("end", "region", "到底啦")]),
            ],
            transitions: [t("scroll", nil, 0, 1), t("scroll", nil, 1, 2), t("scroll", nil, 2, 3)],
            solvability: .solvable([.init(action: "scroll", elementId: nil),
                                    .init(action: "scroll", elementId: nil),
                                    .init(action: "scroll", elementId: nil)]),
            isComplete: { page, _ in page.elements.contains { $0.label == "到底啦" } }
        ),

        // 18. 先选错筛选再纠正（理想策略含自我修正；world 取首个匹配转移，
        // 从 page0 出发的同键转移只保留 0→1 一条，避免假消歧）。
        WebTaskFixture(
            id: "filter-correct-retry",
            goal: "筛选出“顺丰包邮”的商品",
            completionMarker: "顺丰包邮",
            allowedActions: ["select", "scroll"],
            pages: [
                .init(url: "https://shop.example/l", title: "列表", elements: [el("ship", "combobox", "物流")]),
                .init(url: "https://shop.example/l?s=jd", title: "列表（京东物流）", elements: [el("ship", "combobox", "物流"), el("j1", "link", "京东仓商品")]),
                .init(url: "https://shop.example/l?s=sf", title: "列表（顺丰包邮）", elements: [el("s1", "link", "顺丰包邮 鲜果")]),
            ],
            transitions: [
                t("select", "ship", 0, 1),   // 选错到京东物流页
                t("select", "ship", 1, 2),   // 再选纠正到顺丰页
            ],
            solvability: .solvable([.init(action: "select", elementId: "ship"),
                                    .init(action: "select", elementId: "ship")]),
            isComplete: { page, _ in page.title.contains("顺丰包邮") }
        ),

        // 19. 排序选项。
        WebTaskFixture(
            id: "sort-option",
            goal: "按价格从低到高排序，第一个应是“手机壳”",
            completionMarker: "手机壳",
            allowedActions: ["select", "scroll"],
            pages: [
                .init(url: "https://shop.example/s", title: "搜索结果", elements: [el("sort", "combobox", "排序"), el("x", "link", "无人机")]),
                .init(url: "https://shop.example/s?o=price", title: "搜索结果（价格升序）", elements: [el("first", "link", "手机壳"), el("y", "link", "数据线")]),
            ],
            transitions: [t("select", "sort", 0, 1)],
            solvability: .solvable([.init(action: "select", elementId: "sort")]),
            isComplete: { page, _ in page.elements.first?.label == "手机壳" }
        ),

        // 20. 预填搜索框，仅需提交。
        WebTaskFixture(
            id: "submit-only-search",
            goal: "提交当前搜索框内容查看“机票”结果",
            completionMarker: "机票 搜索结果",
            allowedActions: ["submit_readonly_search", "scroll"],
            pages: [
                .init(url: "https://travel.example/", title: "旅行首页", elements: [el("q", "searchbox", "机票")]),
                .init(url: "https://travel.example/s", title: "机票 搜索结果", elements: [el("f1", "link", "北京-东京")]),
            ],
            transitions: [t("submit_readonly_search", "q", 0, 1)],
            solvability: .solvable([.init(action: "submit_readonly_search", elementId: "q")]),
            isComplete: { page, _ in page.title == "机票 搜索结果" }
        ),
    ]

    static func makeWorld(_ id: String) -> WebTaskWorld {
        guard let fixture = all.first(where: { $0.id == id }) else {
            fatalError("unknown web task fixture: \(id)")
        }
        return WebTaskWorld(fixture: fixture)
    }
}
