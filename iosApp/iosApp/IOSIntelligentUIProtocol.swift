import Foundation

/// Preflight for the append-only stream. NSString keeps KMP's UTF16-backed
/// text addressable without repeatedly walking/transcoding its UTF8 prefix.
/// Fence validation and JSON decoding remain in the protocol parser.
struct IOSIntelligentUIPayloadDetector {
    private(set) var mayContainPayload = false

    private static let marker = "task-ui"
    private static let checkpointLength = 24
    private var processedUTF16Count = 0
    private var checkpoint: [UInt16] = []

    init(text: String = "") {
        if !text.isEmpty { update(with: text) }
    }

    mutating func update(with text: String) {
        let string = text as NSString
        let count = string.length
        let matches = checkpointMatches(in: string)
        guard count != processedUTF16Count || !matches else { return }
        if count < processedUTF16Count || !matches { reset() }

        if !mayContainPayload {
            let start = max(0, processedUTF16Count - 6)
            mayContainPayload = string.range(
                of: Self.marker,
                options: .literal,
                range: NSRange(location: start, length: count - start)
            ).location != NSNotFound
        }
        processedUTF16Count = count
        let length = min(count, Self.checkpointLength)
        checkpoint = Self.codeUnits(in: string, range: NSRange(location: count - length, length: length))
    }

    /// Final/frozen snapshots can replace a prefix outside the checkpoint.
    mutating func reconcileFinalText(_ text: String) {
        reset()
        update(with: text)
    }

    private mutating func reset() {
        mayContainPayload = false
        processedUTF16Count = 0
        checkpoint.removeAll(keepingCapacity: true)
    }

    private func checkpointMatches(in string: NSString) -> Bool {
        guard processedUTF16Count > 0 else { return true }
        guard processedUTF16Count <= string.length else { return false }
        return Self.codeUnits(
            in: string,
            range: NSRange(location: processedUTF16Count - checkpoint.count, length: checkpoint.count)
        ) == checkpoint
    }

    /// Compare exact code units even when the checkpoint splits a surrogate pair.
    private static func codeUnits(in string: NSString, range: NSRange) -> [UInt16] {
        var units = [UInt16](repeating: 0, count: range.length)
        if !units.isEmpty {
            units.withUnsafeMutableBufferPointer { buffer in
                string.getCharacters(buffer.baseAddress!, range: range)
            }
        }
        return units
    }
}

struct IOSIntelligentUICardDefinition: Codable, Equatable, Sendable, Identifiable {
    struct Option: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let summary: String
        let tradeoffs: [String]?
        let recommended: Bool?
    }

    struct Field: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let required: Bool
        let placeholder: String?
        /// Unbound fields remain text. Native components own the bound value semantics.
        let type: String?
    }

    struct Submit: Codable, Equatable, Sendable {
        let label: String
        let intent: String
    }

    let version: Int
    let cardID: String
    let kind: String
    let goal: String
    let question: String
    let options: [Option]
    let fields: [Field]
    let submit: Submit
    let components: [IOSIntelligentUIComponent]
    let study: IOSIntelligentUIStudyDefinition?

    var id: String { cardID }

    enum CodingKeys: String, CodingKey {
        case version, cardID = "card_id", kind, goal, question, options, fields, submit, components, study
    }

    init(version: Int = 1, cardID: String, kind: String = "decision", goal: String,
         question: String = "", options: [Option] = [], fields: [Field] = [], submit: Submit,
         components: [IOSIntelligentUIComponent] = [], study: IOSIntelligentUIStudyDefinition? = nil) {
        self.version = version
        self.cardID = cardID
        self.kind = kind
        self.goal = goal
        self.question = question
        self.options = options
        self.fields = fields
        self.submit = submit
        self.components = components
        self.study = study
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        cardID = try values.decode(String.self, forKey: .cardID)
        kind = try values.decode(String.self, forKey: .kind)
        goal = try values.decode(String.self, forKey: .goal)
        question = try values.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try values.decodeIfPresent([Option].self, forKey: .options) ?? []
        fields = try values.decodeIfPresent([Field].self, forKey: .fields) ?? []
        submit = try values.decode(Submit.self, forKey: .submit)
        components = try values.decodeIfPresent([IOSIntelligentUIComponent].self, forKey: .components) ?? []
        study = try values.decodeIfPresent(IOSIntelligentUIStudyDefinition.self, forKey: .study)
    }

    func boundComponent(for fieldID: String) -> IOSIntelligentUIComponent? {
        func find(in nodes: [IOSIntelligentUIComponent]) -> IOSIntelligentUIComponent? {
            for node in nodes {
                if node.kind.requiresField && node.fieldID == fieldID { return node }
                if let match = find(in: node.children ?? []) { return match }
            }
            return nil
        }
        return find(in: components)
    }

    var presentationFieldIDs: Set<String> {
        Set(fields.compactMap { field in boundComponent(for: field.id)?.kind.isPresentationField == true ? field.id : nil })
    }

    var submissionFields: [Field] { fields.filter { !presentationFieldIDs.contains($0.id) } }

    func fieldValueSummary(_ value: String, for field: Field) -> String {
        guard let component = boundComponent(for: field.id) else { return value }
        return IOSIntelligentUIComponentValues.summary(value, for: component)
    }

    func requiredFieldHasValue(_ field: Field, values: [String: String]) -> Bool {
        let value = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if let component = boundComponent(for: field.id), [.multiChoice, .checklist].contains(component.kind) {
            return !IOSIntelligentUIComponentValues.decodeSelection(value).isEmpty
        }
        return true
    }

}

enum IOSIntelligentUISegment: Equatable, Sendable {
    case text(String)
    case card(IOSIntelligentUICardDefinition)
    case loading
    case invalid(raw: String, reason: String)
}

struct IOSIntelligentUIProtocolError: Error, LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

enum IOSIntelligentUIProtocol {
    static let exampleJSON = #"""
    {
      "version": 1,
      "card_id": "implementation-path",
      "kind": "decision",
      "goal": "确定智能 UI 的实现路径",
      "question": "你希望沿哪个方案继续？",
      "options": [
        {"id": "native", "title": "原生任务卡", "summary": "复用原生控件与现有聊天入口。", "tradeoffs": ["原生组件需要宿主支持相应交互。"], "recommended": true},
        {"id": "web", "title": "网页任务界面", "summary": "通过网页提供自由布局。", "tradeoffs": ["需要另行连接网页状态与任务来源。"]}
      ],
      "fields": [{"id": "constraints", "label": "补充约束", "required": false, "placeholder": "例如必须保留的能力", "type": "text"}],
      "submit": {"label": "基于选择继续", "intent": "continue"}
    }
    """#

    static let studyExampleJSON = #"""
    {
      "version": 1,
      "card_id": "ming-emperors-study",
      "kind": "study",
      "goal": "通过翻卡和选择题记住明朝皇帝与年号",
      "study": {"items": [
        {"id": "hongwu", "prompt": "洪武对应哪位皇帝？", "answer": "明太祖朱元璋", "detail": "洪武是明朝第一个年号。", "options": [{"id": "yuanzhang", "label": "朱元璋"}, {"id": "di", "label": "朱棣"}], "correct_option_id": "yuanzhang"},
        {"id": "yongle", "prompt": "永乐对应哪位皇帝？", "answer": "明成祖朱棣", "detail": "永乐时期郑和开始下西洋。", "options": [{"id": "di", "label": "朱棣"}, {"id": "yunwen", "label": "朱允炆"}], "correct_option_id": "di"}
      ]},
      "submit": {"label": "根据练习结果继续", "intent": "continue"}
    }
    """#

    static let formExampleJSON = #"""
    {"version":1,"card_id":"trip-preferences","kind":"form","goal":"补充行程偏好",
     "fields":[
       {"id":"preferences","label":"补充偏好","required":false,"type":"text"},
       {"id":"pace","label":"行程节奏","required":true,"type":"choice"},
       {"id":"activities","label":"感兴趣的活动","required":false,"type":"multiChoice"}],
     "components":[
       {"id":"preferences-input","kind":"textArea","field_id":"preferences","title":"补充偏好"},
       {"id":"pace-input","kind":"segmented","field_id":"pace","title":"行程节奏",
        "options":[{"id":"relaxed","label":"轻松游览"},{"id":"compact","label":"紧凑充实"}]},
       {"id":"activities-input","kind":"checklist","field_id":"activities","title":"感兴趣的活动",
        "options":[{"id":"walk","label":"城市漫步"},{"id":"food","label":"品尝美食"}]}],
     "submit":{"label":"按偏好安排","intent":"continue"}}
    """#

    static let exploreExampleJSON = #"""
    {"version":1,"card_id":"storage-guide","kind":"explore","goal":"浏览两种存储方式的特点",
     "fields":[{"id":"section","label":"浏览章节","required":false,"type":"presentation"}],
     "components":[{"id":"sections","kind":"tabs","field_id":"section","children":[
       {"id":"local","kind":"column","title":"本地","children":[
         {"id":"local-feature","kind":"keyValue","title":"主要特点","text":"离线可用；跨设备同步需要另行配置。"},
         {"id":"local-steps","kind":"steps","title":"使用步骤","rows":[
           {"label":"选定目录","detail":"明确笔记保存在设备上的位置。"},
           {"label":"开始记录","detail":"在本地读写；同步另行配置。"}]}]},
       {"id":"cloud","kind":"column","title":"云端","children":[
         {"id":"cloud-feature","kind":"keyValue","title":"主要特点","text":"便于跨设备使用；需评估网络与隐私要求。"},
         {"id":"storage-comparison","kind":"comparison","title":"特点对照","options":[
           {"id":"local-option","label":"本地","detail":"离线读写；同步另行配置。"},
           {"id":"cloud-option","label":"云端","detail":"便于同步；依赖服务与网络。"}]},
         {"id":"sync-timeline","kind":"timeline","title":"同步过程","rows":[
           {"label":"设备记录","detail":"先保留本次笔记。"},
           {"label":"同步完成","detail":"完成同步后其他设备才能读取更新。"}]},
         {"id":"storage-table","kind":"table","title":"使用条件","items":["方式","使用条件"],"rows":[
           {"label":"本地","cells":["本地","设备内读写"]},
           {"label":"云端","cells":["云端","服务与网络"]}]}]}]}],
     "submit":{"label":"结合我的需求继续比较","intent":"continue"}}
    """#

    static let numericExploreExampleJSON = #"""
    {"version":1,"card_id":"reading-progress","kind":"explore","goal":"调整完成章节数，观察阅读进度",
     "fields":[{"id":"chapters","label":"已完成章节","required":true,"type":"number"}],
     "components":[
       {"id":"chapter-input","kind":"stepper","title":"已完成章节","field_id":"chapters","min":0,"max":4,"step":1,"value":1},
       {"id":"chapter-metric","kind":"metric","title":"已完成章节","value_field_id":"chapters"},
       {"id":"chapter-progress","kind":"progress","title":"完成比例","value_field_id":"chapters","max":4},
       {"id":"chapter-steps","kind":"stepProgress","title":"章节进度","value_field_id":"chapters","items":["引言","基础","实践","复盘"]},
       {"id":"chapter-chart","kind":"barChart","title":"完成数量与总量","rows":[{"label":"已完成","value_field_id":"chapters"},{"label":"总章节","value":4}]}],
     "submit":{"label":"根据进度安排下一步","intent":"continue"}}
    """#

    static let capabilityPrompt = """
    【聊天内智能 UI：task-ui v1】
    你应根据任务主动判断界面是否有帮助，用户无需点名“智能 UI”、协议或组件。对于学习记忆与练习、反复浏览内容、比较方案、填写多个信息项或探索参数，优先使用能直接在消息内操作的原生 task-ui；不要只给文字介绍或 HTML 封面，再让用户打开 Live 演示。
    简单事实、解释和一句话能解决的问题直接用文字；用户明确要求纯文字时不用卡片。已授权且信息充分的执行任务直接推进，不为使用 UI 增加决策或确认步骤。先调查事实，界面必须包含当前任务的真实内容，不能用通用示例或占位内容替代结果。
    task-ui 是固定 JSON 数据协议，不是 HTML、SwiftUI 或 JSON Schema。先选一种 kind，照最接近的完整示例组织真实内容，再添加必要组件；不要根据常见表单格式自行扩展字段。
    根据当前操作选择 kind，不要把所有任务都包装成“选两个方案”：
    - decision：比较真正不同的 2–8 个方案，由用户选择；根 options 必须包含 id/title/summary，可有 tradeoffs 和一个 recommended，推荐不自动选择。
    - form：填写当前任务需要的信息。使用 fields 和原生输入组件，不需要根 options，也不要虚构方案。只有填写能帮助下一步时才生成。
    - explore：分组浏览、展开、分页及选择参数。用 tabs/accordion/disclosure/列表/表格/已有输入组件组织内容，无根 options。
      展开/分页和数字字段到指标、进度、图表的直接引用在本地响应；用 value_field_id 让图形随参数操作更新。宿主不执行任意公式或脚本，需要新的计算或工具结果时显式提交给 agent。
    - study：翻卡复习和可选的选择题抽考，直接展示在消息内。study.items 为 2–40 个真实学习项目，每项有稳定 id、prompt、answer，可选 detail。
      需要测验时，为项目加 2–8 个 options（id/label）及引用其中 id 的 correct_option_id；没有选择题时省略 options 和 correct_option_id。
      模型负责题目、答案和解释；翻卡、选择、判分、切题、重练和进度保存由本地完成，不需要生成 JS。用户要求完整知识集合时覆盖全部项目，不以两个示例代替。study 不需要根 options 或人为声明学习进度字段。
    每条助手消息最多一个独立的 ```task-ui JSON 代码块。所有类型都有 version=1、稳定 ASCII card_id、kind、goal 和 submit（label 为具体的继续动作、intent=continue）。
    question 可选，decision 必须有问题；fields/components 可选。非 decision 省略根 options。study 类型必须有 study，其余类型不能有 study。
    【字段层级：只使用当前对象允许的键】
    - 根对象只允许 version/card_id/kind/goal/question/options/fields/submit/components/study；不要增加 layout/theme/state 等自定义键。
    - fields[] 只允许 id/label/required/placeholder/type。fields[] 禁止 options/items/value/default/min/max/step；字段只声明输入契约，不描述控件和选择项。
    - 根 options[] 仅用于 decision，每项必填 id/title/summary，可选 tradeoffs/recommended；不要用 label 代替 title/summary。
    - components[].options[] 每项必填 id/label，可选 detail/color；输入选项必须放在绑定 field_id 的选择控件内，不能放进 fields[]。非 decision 的单选/多选也使用这里。
    - study.items[].options[] 是测验答案选项，每项只允许 id/label，correct_option_id 放在对应题目内；不能套用决策方案或组件选项的其他键。
    - submit 只允许 label/intent；study 只允许 items；study.items[] 只允许 id/prompt/answer/detail/options/correct_option_id。
    未列出的键不要生成，不适用的可选属性直接省略，不用 null、占位字段或自创枚举补齐结构。
    用户操作和练习状态在本地保存；只有显式提交或用户通过聊天引用后才进入下一轮。卡片不能声明工具、权限、宿主回调或执行代码。收到交互结果后，依据实际选择、输入和学习进度继续；用户只要求文字反馈时不要再生成一张卡。保持已有工具与审批流程。
    task-ui 与 show-widget 用途不同：SVG、Three.js、HTML、图表、slides 是视觉产物或独立展示。用户明确要这些产物、独立 MiniApp，或任务确实需要原生组件没有的能力时才用对应路径；普通学习卡、原生表单和内容浏览优先 task-ui。
    不要把学习/输入仅封装到 full_html 的静态封面后。图片与三维效果本身不构成智能 UI。
    fields 最多 16 项，每项 id/label/required，type 可省略为 text，或 text/number/bool/date/time/choice/multiChoice/presentation。
    非 text 需要对应原生组件，组件绑定已经声明的 field_id；纯展开/分页用 presentation、required=false，不进入提交。不要声明内部学习进度字段。省略 components 时展示普通输入；components 可组合以下原生能力，不要求凑组件数量。
    \(IOSIntelligentUIComponentCatalog.capabilityPrompt)
    以下只是结构示例，实际内容应符合用户任务：
    决策：
    \(exampleJSON)
    填写（单选和多选的 options 在 components 内，fields 只声明类型）：
    \(formExampleJSON)
    浏览（纵向 column、键值 title/text、比较 options、流程 rows、表格 cells）：
    \(exploreExampleJSON)
    参数与图形联动：
    \(numericExploreExampleJSON)
    学习：
    \(studyExampleJSON)
    【输出前静默自检，不展示检查过程】
    1. JSON 完整且可解析：双引号键名和字符串，required/recommended 用布尔值；没有注释、尾逗号、说明里的可选标记或省略号。
    2. 逐层核对键名，尤其 fields[] 没有 options、非 decision 没有根 options；三种 options 的对象结构不混用。
    3. field_id 引用已声明的字段，field.type 与控件对应；value_field_id 引用本卡有数字输入的 number 字段；correct_option_id 引用本题选项。id 唯一且使用稳定 ASCII 标识。
    4. 核对组件内容形状：所有 value（含 rows[].value）都是 JSON 数字；keyValue 用 title/text，comparison 用 options，timeline/steps/list 用 rows；纵向内容用 column，table.cells 包含完整展示列。不要写会被该组件忽略的属性，也不宣称偏好选择会改变布局或主题。
    5. 只输出一张完整卡片，优先用能满足任务的简单组合。不确定某个写法时改用已知合法组件保留真实内容，不发明字段、公式、脚本或回调。生成 JSON 不等于设备验证，不声称交互已测试。
    """

    static func decode(_ json: String) throws -> IOSIntelligentUICardDefinition {
        guard json.utf8.count <= 131_072 else { throw issue("任务卡内容过长。") }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw issue("任务卡 JSON 格式不完整或不是对象。")
        }
        try checkKeys(root, allowed: ["version", "card_id", "kind", "goal", "question", "options", "fields", "submit", "components", "study"])
        if let version = root["version"] as? NSNumber, version.intValue != 1 {
            throw issue("当前版本不支持 task-ui v\(version)。")
        }
        if let options = root["options"] as? [[String: Any]] {
            for option in options {
                try checkKeys(option, allowed: ["id", "title", "summary", "tradeoffs", "recommended"])
            }
        }
        if let fields = root["fields"] as? [[String: Any]] {
            for field in fields {
                try checkKeys(field, allowed: ["id", "label", "required", "placeholder", "type"])
            }
        }
        if let submit = root["submit"] as? [String: Any] {
            try checkKeys(submit, allowed: ["label", "intent"])
        }
        if let rawComponents = root["components"], !(rawComponents is NSNull) {
            guard let components = rawComponents as? [[String: Any]] else { throw issue("components 必须为组件对象数组。") }
            var componentCount = 0
            for component in components { try checkComponentKeys(component, depth: 1, count: &componentCount) }
        }
        if let rawStudy = root["study"], !(rawStudy is NSNull) {
            guard let study = rawStudy as? [String: Any], let items = study["items"] as? [[String: Any]] else {
                throw issue("study 必须包含学习项目数组 items。")
            }
            try checkKeys(study, allowed: ["items"])
            for item in items {
                try checkKeys(item, allowed: ["id", "prompt", "answer", "detail", "options", "correct_option_id"])
                for option in item["options"] as? [[String: Any]] ?? [] {
                    try checkKeys(option, allowed: ["id", "label"])
                }
            }
        }
        let definition: IOSIntelligentUICardDefinition
        do { definition = try JSONDecoder().decode(IOSIntelligentUICardDefinition.self, from: data) }
        catch { throw issue("任务卡缺少必要字段，或字段类型不符合 task-ui v1。") }
        try validate(definition)
        return definition
    }

    static func decodePreviewComponent(_ json: String, allowedFieldIDs: Set<String>) throws -> IOSIntelligentUIComponent {
        guard json.utf8.count <= 131_072,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw issue("组件 JSON 格式不完整或不是对象。")
        }
        var componentCount = 0
        try checkComponentKeys(object, depth: 1, count: &componentCount)
        let component = try JSONDecoder().decode(IOSIntelligentUIComponent.self, from: data)
        try IOSIntelligentUIComponentCatalog.validate([component], allowedFieldIDs: allowedFieldIDs)
        return component
    }

    static func validate(_ card: IOSIntelligentUICardDefinition) throws {
        guard card.version == 1 else { throw issue("当前版本不支持 task-ui v\(card.version)。") }
        guard ["decision", "form", "explore", "study"].contains(card.kind) else { throw issue("任务卡类型必须为 decision、form、explore 或 study。") }
        try validateID(card.cardID)
        try validateText(card.goal, name: "目标", maximum: 500)
        if card.kind == "decision" {
            try validateText(card.question, name: "问题", maximum: 300)
            guard (2...8).contains(card.options.count) else { throw issue("方案数量必须为 2 至 8 个。") }
        } else {
            guard card.question.count <= 300 else { throw issue("问题过长（最多 300 个字符）。") }
            guard card.options.isEmpty else { throw issue("非决策任务卡不使用根方案选项；请使用字段组件或学习题目选项。") }
        }
        if card.kind == "study" {
            guard let study = card.study else { throw issue("学习任务卡需要 study.items。") }
            try study.validate()
        } else if card.study != nil {
            throw issue("只有 study 任务卡可以声明学习项目。")
        }
        guard card.fields.count <= 16 else { throw issue("补充字段最多为 16 个。") }
        guard Set(card.options.map(\.id)).count == card.options.count,
              Set(card.fields.map(\.id)).count == card.fields.count else {
            throw issue("方案或字段的 id 重复。")
        }
        guard card.options.filter({ $0.recommended == true }).count <= 1 else {
            throw issue("最多只能标记一个推荐方案。")
        }
        for option in card.options {
            try validateID(option.id)
            try validateText(option.title, name: "方案标题", maximum: 100)
            try validateText(option.summary, name: "方案摘要", maximum: 1_000)
            guard (option.tradeoffs?.count ?? 0) <= 4 else { throw issue("每个方案最多包含 4 条取舍。") }
            for tradeoff in option.tradeoffs ?? [] {
                try validateText(tradeoff, name: "方案取舍", maximum: 500)
            }
        }
        do { try IOSIntelligentUIComponentCatalog.validate(card.components, allowedFieldIDs: Set(card.fields.map(\.id))) }
        catch { throw issue(error.localizedDescription) }
        var bindingSemantics: [String: String] = [:]
        func validateBindingSemantics(_ nodes: [IOSIntelligentUIComponent]) throws {
            for node in nodes {
                if node.kind.requiresField, let fieldID = node.fieldID, let semantics = node.kind.valueSemantics {
                    let contract = "\(node.kind.isPresentationField):\(semantics)"
                    if let existing = bindingSemantics[fieldID], existing != contract {
                        throw issue("同一字段不能绑定值语义不同的组件。")
                    }
                    bindingSemantics[fieldID] = contract
                }
                try validateBindingSemantics(node.children ?? [])
            }
        }
        try validateBindingSemantics(card.components)
        for field in card.fields {
            guard field.id != IOSIntelligentUIStudySession.storageKey else { throw issue("字段 id 与学习状态保留字段冲突。") }
            try validateID(field.id)
            let fieldType = field.type ?? "text"
            guard ["text", "number", "bool", "date", "time", "choice", "multiChoice", "presentation"].contains(fieldType) else { throw issue("字段类型不在当前原生能力范围内。") }
            let component = card.boundComponent(for: field.id)
            if fieldType != "text" {
                guard let component, type(for: component.kind) == fieldType else { throw issue("字段类型与原生输入组件不匹配。") }
            }
            if component?.kind.isPresentationField == true && field.required { throw issue("展开和分页字段不能设为必填。") }
            try validateText(field.label, name: "字段标签", maximum: 100)
            if let placeholder = field.placeholder {
                try validateText(placeholder, name: "输入提示", maximum: 200)
            }
        }
        do {
            try IOSIntelligentUIComponentCatalog.validateValueReferences(
                card.components,
                numberFieldIDs: Set(card.fields.filter { $0.type == "number" }.map(\.id)),
                inputComponents: card.components
            )
        } catch { throw issue(error.localizedDescription) }
        guard card.submit.intent == "continue" else { throw issue("任务卡仅支持继续对话。") }
        try validateText(card.submit.label, name: "提交标签", maximum: 80)
    }

    /// Preserve ordinary Markdown byte-for-byte and only recognize standalone fences.
    /// A task-ui example inside another fenced block remains ordinary text.
    static func parse(_ text: String, isStreaming: Bool) -> [IOSIntelligentUISegment] {
        guard text.contains("task-ui") else { return text.isEmpty ? [] : [.text(text)] }
        var segments: [IOSIntelligentUISegment] = []
        var cursor = text.startIndex
        var plainStart = cursor
        var ordinaryFence: (character: Character, count: Int)?
        var cardSeen = false
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            let nextLine = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            let line = String(text[cursor..<lineEnd]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if let fence = ordinaryFence {
                if isClosing(line, character: fence.character, count: fence.count) { ordinaryFence = nil }
                cursor = nextLine
                continue
            }
            guard let opening = openingFence(line) else { cursor = nextLine; continue }
            guard opening.info == "task-ui", opening.character == "`" else {
                ordinaryFence = (opening.character, opening.count)
                cursor = nextLine
                continue
            }
            if plainStart < cursor { segments.append(.text(String(text[plainStart..<cursor]))) }
            let blockStart = cursor
            let payloadStart = nextLine
            var closingStart: String.Index?
            cursor = nextLine
            while cursor < text.endIndex {
                let end = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
                let following = end < text.endIndex ? text.index(after: end) : text.endIndex
                if isClosing(String(text[cursor..<end]), character: "`", count: opening.count) {
                    closingStart = cursor
                    cursor = following
                    break
                }
                cursor = following
            }
            let raw = String(text[blockStart..<cursor])
            if let closingStart {
                do {
                    let card = try decode(String(text[payloadStart..<closingStart]))
                    if cardSeen {
                        segments.append(.invalid(raw: raw, reason: "一条回复只支持一张任务卡；请使用前一张有效卡片。"))
                    } else {
                        segments.append(.card(card))
                        cardSeen = true
                    }
                } catch {
                    segments.append(.invalid(raw: raw, reason: error.localizedDescription))
                }
            } else if isStreaming {
                segments.append(.loading)
            } else {
                segments.append(.invalid(raw: raw, reason: "任务卡代码块未完整结束，请重新生成。"))
            }
            plainStart = cursor
        }
        if plainStart < text.endIndex { segments.append(.text(String(text[plainStart...]))) }
        return segments
    }

    private static func openingFence(_ line: String) -> (character: Character, count: Int, info: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let body = line.dropFirst(indentation)
        guard let character = body.first, character == "`" || character == "~" else { return nil }
        let count = body.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        let info = body.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (character, count, info)
    }

    private static func isClosing(_ line: String, character: Character, count: Int) -> Bool {
        guard let fence = openingFence(line) else { return false }
        return fence.character == character && fence.count >= count && fence.info.isEmpty
    }

    private static func checkComponentKeys(_ object: [String: Any], depth: Int, count: inout Int) throws {
        count += 1
        guard depth <= IOSIntelligentUIComponentCatalog.maximumDepth,
              count <= IOSIntelligentUIComponentCatalog.maximumNodes else {
            throw issue("组件层级最多 8 层，单张卡片最多 160 个组件。")
        }
        try checkKeys(object, allowed: [
            "id", "kind", "title", "text", "children", "items", "options", "field_id", "value", "value_field_id",
            "min", "max", "step", "columns", "rows", "symbol", "url", "action", "style"
        ])
        for option in object["options"] as? [[String: Any]] ?? [] { try checkKeys(option, allowed: ["id", "label", "detail", "color"]) }
        for row in object["rows"] as? [[String: Any]] ?? [] { try checkKeys(row, allowed: ["label", "value", "value_field_id", "detail", "cells"]) }
        if let style = object["style"] as? [String: Any] { try checkKeys(style, allowed: ["tone", "emphasis", "density", "alignment", "spacing", "padding"]) }
        if let rawChildren = object["children"], !(rawChildren is NSNull) {
            guard let children = rawChildren as? [[String: Any]] else { throw issue("children 必须为组件对象数组。") }
            for child in children { try checkComponentKeys(child, depth: depth + 1, count: &count) }
        }
    }

    private static func type(for kind: IOSIntelligentUIComponent.Kind) -> String? {
        switch kind {
        case .textField, .textArea: "text"
        case .numberField, .slider, .stepper, .rating: "number"
        case .toggle: "bool"
        case .datePicker: "date"
        case .timePicker: "time"
        case .singleChoice, .segmented, .picker, .colorChoice, .menu: "choice"
        case .multiChoice, .checklist: "multiChoice"
        case .disclosure, .tabs, .accordion: "presentation"
        default: nil
        }
    }

    private static func checkKeys(_ object: [String: Any], allowed: Set<String>) throws {
        if let key = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw issue("任务卡包含不支持的字段：\(key)。")
        }
    }

    private static func validateID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 80,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw issue("任务卡 id 必须为 1 至 80 个英文字母、数字、连字符或下划线。")
        }
    }

    private static func validateText(_ value: String, name: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw issue("\(name)不能为空。") }
        guard value.count <= maximum else { throw issue("\(name)过长（最多 \(maximum) 个字符）。") }
    }

    private static func issue(_ reason: String) -> IOSIntelligentUIProtocolError {
        IOSIntelligentUIProtocolError(reason: reason)
    }
}
