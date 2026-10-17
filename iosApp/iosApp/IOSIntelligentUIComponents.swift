import Foundation

/// Finite native components. The payload describes content and binding; it never contains code.
struct IOSIntelligentUIComponent: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case stack, column, row, grid, card, panel, group, inset, divider, spacer
        case title, subtitle, body, caption, callout, quote, inlineCode, bulletList, numberedList, keyValue, footnote, highlight
        case badge, chip, tag, statusDot, progress, stepProgress, skeleton, emptyState, notice, alert
        case singleChoice, multiChoice, segmented, picker, toggle, textField, textArea, numberField, slider, stepper, datePicker, timePicker, rating, colorChoice
        case metric, metricGrid, table, list, comparison, timeline, steps, checklist, barChart, lineChart
        case image, imageGrid, avatar, icon, linkCard, fileCard, codeBlock, diagram
        case goal, context, source, reason, tradeoff, result, assumptions, decisionSummary
        case button, buttonGroup, submitButton, resetButton, disclosure, tabs, accordion, menu

        var family: String {
            switch self {
            case .stack, .column, .row, .grid, .card, .panel, .group, .inset, .divider, .spacer: return "layout"
            case .title, .subtitle, .body, .caption, .callout, .quote, .inlineCode, .bulletList, .numberedList, .keyValue, .footnote, .highlight: return "text"
            case .badge, .chip, .tag, .statusDot, .progress, .stepProgress, .skeleton, .emptyState, .notice, .alert: return "status"
            case .singleChoice, .multiChoice, .segmented, .picker, .toggle, .textField, .textArea, .numberField, .slider, .stepper, .datePicker, .timePicker, .rating, .colorChoice: return "input"
            case .metric, .metricGrid, .table, .list, .comparison, .timeline, .steps, .checklist, .barChart, .lineChart: return "data"
            case .image, .imageGrid, .avatar, .icon, .linkCard, .fileCard, .codeBlock, .diagram: return "media"
            case .goal, .context, .source, .reason, .tradeoff, .result, .assumptions, .decisionSummary: return "task"
            case .button, .buttonGroup, .submitButton, .resetButton, .disclosure, .tabs, .accordion, .menu: return "action"
            }
        }

        var requiresField: Bool {
            family == "input" || [.checklist, .disclosure, .tabs, .accordion, .menu].contains(self)
        }

        var isPresentationField: Bool { [.disclosure, .tabs, .accordion].contains(self) }
        var isNumericInput: Bool { [.numberField, .slider, .stepper, .rating].contains(self) }

        var valueSemantics: String? {
            switch self {
            case .toggle, .disclosure: "boolean string: true/false"
            case .multiChoice, .checklist, .accordion: "JSON array of selected ids"
            case .singleChoice, .segmented, .picker, .colorChoice, .menu: "selected option id"
            case .tabs: "selected child id"
            case .numberField, .slider, .stepper, .rating: "finite decimal string"
            case .datePicker: "yyyy-MM-dd"
            case .timePicker: "HH:mm"
            case .textField, .textArea: "plain text"
            default: nil
            }
        }

        var allowsChildren: Bool {
            [.stack, .column, .row, .grid, .card, .panel, .group, .inset, .metricGrid,
             .imageGrid, .buttonGroup, .disclosure, .tabs, .accordion].contains(self)
        }
    }

    struct Option: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        var detail: String? = nil
        /// colorChoice accepts these native color names, rather than generated style code.
        var color: String? = nil
    }

    struct Row: Codable, Equatable, Sendable {
        let label: String
        var value: Double? = nil
        var valueFieldID: String? = nil
        var detail: String? = nil
        var cells: [String]? = nil

        enum CodingKeys: String, CodingKey {
            case label, value, valueFieldID = "value_field_id", detail, cells
        }
    }

    enum Action: String, Codable, Sendable { case `continue`, reset }
    struct Style: Codable, Equatable, Sendable {
        enum Tone: String, Codable, CaseIterable, Sendable { case neutral, accent, success, warning, danger }
        enum Emphasis: String, Codable, CaseIterable, Sendable { case plain, soft, outlined, filled }
        enum Density: String, Codable, CaseIterable, Sendable { case compact, comfortable }
        enum Alignment: String, Codable, CaseIterable, Sendable { case leading, center }
        enum Space: String, Codable, CaseIterable, Sendable {
            case none, small, medium, large
            var points: Double { switch self { case .none: 0; case .small: 6; case .medium: 12; case .large: 20 } }
        }
        var tone: Tone? = nil
        var emphasis: Emphasis? = nil
        var density: Density? = nil
        var alignment: Alignment? = nil
        var spacing: Space? = nil
        var padding: Space? = nil
    }

    let id: String
    let kind: Kind
    var title: String? = nil
    var text: String? = nil
    var children: [Self]? = nil
    var items: [String]? = nil
    var options: [Option]? = nil
    var fieldID: String? = nil
    var value: Double? = nil
    var valueFieldID: String? = nil
    var min: Double? = nil
    var max: Double? = nil
    var step: Double? = nil
    var columns: Int? = nil
    var rows: [Row]? = nil
    var symbol: String? = nil
    var url: String? = nil
    var action: Action? = nil
    var style: Style? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, title, text, children, items, options, fieldID = "field_id"
        case value, valueFieldID = "value_field_id", min, max, step, columns, rows, symbol, url, action, style
    }

    var numericRange: ClosedRange<Double> { (min ?? 0)...(max ?? 100) }
    var numericStep: Double { step ?? 1 }

    static let colorNames = ["accent", "red", "orange", "yellow", "green", "cyan", "blue", "indigo", "purple", "pink", "gray"]
}

struct IOSIntelligentUIComponentError: Error, LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

enum IOSIntelligentUIComponentCatalog {
    static let maximumDepth = 8
    static let maximumNodes = 160

    /// Mobile task cards have a finite content budget; this is not an arbitrary UI runtime.
    static func validate(_ components: [IOSIntelligentUIComponent], allowedFieldIDs: Set<String>) throws {
        var ids = Set<String>()
        var count = 0
        for component in components {
            try validate(component, depth: 1, ids: &ids, count: &count, fields: allowedFieldIDs)
        }
    }

    private static func validate(_ node: IOSIntelligentUIComponent, depth: Int,
                                 ids: inout Set<String>, count: inout Int, fields: Set<String>) throws {
        count += 1
        guard depth <= maximumDepth, count <= maximumNodes else {
            throw issue("组件层级最多 8 层，单张卡片最多 160 个组件。")
        }
        guard !node.id.isEmpty, node.id.count <= 80, ids.insert(node.id).inserted else {
            throw issue("组件 id 必须非空、唯一且不超过 80 个字符。")
        }
        guard (node.title?.count ?? 0) <= 300, (node.text?.count ?? 0) <= 8_000,
              (node.items?.count ?? 0) <= 40, (node.options?.count ?? 0) <= 20,
              (node.rows?.count ?? 0) <= 40 else { throw issue("组件内容超出任务卡的展示范围。") }
        if let fieldID = node.fieldID {
            guard fields.contains(fieldID) else { throw issue("组件引用了未声明的字段：\(fieldID)。") }
        }
        if node.kind.requiresField, node.fieldID == nil {
            throw issue("\(node.kind.rawValue) 组件必须绑定 field_id。")
        }
        if let reference = node.valueFieldID {
            guard [.metric, .progress, .stepProgress].contains(node.kind), fields.contains(reference), node.value == nil else {
                throw issue("value_field_id 只能用于指标和进度，引用本卡字段，且不能同时声明 value。")
            }
        }
        if let action = node.action {
            guard [.button, .submitButton, .resetButton].contains(node.kind),
                  node.kind != .submitButton || action == .continue,
                  node.kind != .resetButton || action == .reset else {
                throw issue("按钮只能提交当前任务选择或重置本卡草稿。")
            }
        }
        if node.kind == .button, node.action == nil { throw issue("button 必须声明 continue 或 reset 动作。") }
        if let children = node.children, !children.isEmpty, !node.kind.allowsChildren {
            throw issue("\(node.kind.rawValue) 不接受子组件。")
        }
        if let columns = node.columns, !(1...4).contains(columns) { throw issue("网格列数必须为 1 至 4。") }
        let numeric = [node.value, node.min, node.max, node.step].compactMap { $0 }
        guard numeric.allSatisfy(\.isFinite), (node.min ?? 0) < (node.max ?? 100),
              node.numericStep > 0 else { throw issue("数值范围或步长不合法。") }
        if [.rating].contains(node.kind), !((node.max ?? 5) >= 1 && (node.max ?? 5) <= 10 && (node.max ?? 5).rounded() == (node.max ?? 5)) {
            throw issue("评分刻度必须为 1 至 10。")
        }
        if let options = node.options {
            guard Set(options.map(\.id)).count == options.count,
                  options.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 80 && !$0.label.isEmpty && $0.label.count <= 200 && ($0.detail?.count ?? 0) <= 1_000 }) else {
                throw issue("选项必须有唯一 id 和可读标签。")
            }
        }
        if [.singleChoice, .multiChoice, .segmented, .picker, .colorChoice, .menu].contains(node.kind), (node.options ?? []).isEmpty {
            throw issue("选择控件需要 options。")
        }
        if node.kind == .checklist, (node.options ?? []).isEmpty {
            guard let items = node.items, !items.isEmpty, Set(items).count == items.count else { throw issue("checklist 需要唯一的 items 或 options。") }
        }
        if node.kind == .progress, (node.max ?? 100) <= 0 { throw issue("进度总值必须大于零。") }
        if node.kind == .colorChoice {
            guard (node.options ?? []).allSatisfy({ IOSIntelligentUIComponent.colorNames.contains($0.color ?? "accent") }) else {
                throw issue("colorChoice 只支持目录中的原生颜色。")
            }
        }
        if [.barChart, .lineChart].contains(node.kind) {
            guard let rows = node.rows, !rows.isEmpty,
                  rows.allSatisfy({ $0.value?.isFinite == true || $0.valueFieldID != nil }) else { throw issue("图表每行需要有限 value 或 value_field_id。") }
        }
        if node.kind == .keyValue {
            guard node.rows == nil, !(node.title ?? "").isEmpty, !(node.text ?? "").isEmpty else {
                throw issue("keyValue 需要 title 和 text，且不使用 rows。")
            }
        }
        if node.kind == .comparison {
            guard !(node.options ?? []).isEmpty, node.rows == nil else {
                throw issue("comparison 需要 options，且不使用 rows。")
            }
        }
        if [.timeline, .steps, .list].contains(node.kind) {
            guard !(node.rows ?? []).isEmpty, node.items == nil else {
                throw issue("\(node.kind.rawValue) 需要 rows，且不使用 items。")
            }
        }
        if node.kind == .table {
            guard let rows = node.rows, !rows.isEmpty,
                  (node.items ?? []).isEmpty || rows.allSatisfy({ $0.cells == nil || $0.cells?.count == node.items?.count }) else {
                throw issue("table 需要 rows，且 cells 列数需与 items 列标题一致。")
            }
        }
        if node.kind == .tabs || node.kind == .accordion {
            guard let children = node.children, !children.isEmpty,
                  children.allSatisfy({ !($0.title ?? "").isEmpty }) else { throw issue("tabs 和 accordion 的每个子组件需要标题。") }
        }
        if node.kind == .decisionSummary {
            guard (node.items ?? []).allSatisfy({ fields.contains($0) }) else { throw issue("摘要只能引用已声明字段。") }
        }
        if let url = node.url {
            guard [.image, .avatar, .linkCard].contains(node.kind),
                  let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host != nil,
                  parsed.user == nil, parsed.password == nil else { throw issue("媒体只支持无认证信息的 HTTPS 地址。") }
        }
        for item in node.items ?? [] where item.count > 2_000 { throw issue("列表项内容过长。") }
        for row in node.rows ?? [] {
            if let reference = row.valueFieldID {
                guard [.barChart, .lineChart].contains(node.kind), fields.contains(reference), row.value == nil else {
                    throw issue("数据行 value_field_id 只能用于本卡图表，且不能同时声明 value。")
                }
            }
            guard row.label.count <= 300, (row.detail?.count ?? 0) <= 2_000,
                  (row.cells?.count ?? 0) <= 8, (row.cells ?? []).allSatisfy({ $0.count <= 2_000 }),
                  row.value?.isFinite != false else { throw issue("数据行内容不合法。") }
        }
        for child in node.children ?? [] {
            try validate(child, depth: depth + 1, ids: &ids, count: &count, fields: fields)
        }
    }

    /// Called when restoring/committing a draft. Invalid values stay visible as errors;
    /// controls never silently change submitted values into their display defaults.
    static func validateDraftValues(_ values: [String: String], components: [IOSIntelligentUIComponent]) throws {
        for node in components {
            if let fieldID = node.fieldID, let value = values[fieldID], !value.isEmpty {
                var valid = true
                switch node.kind {
                case .singleChoice, .segmented, .picker, .colorChoice, .menu:
                    valid = (node.options ?? []).contains { $0.id == value }
                case .toggle, .disclosure: valid = value == "true" || value == "false"
                case .multiChoice, .checklist, .accordion:
                    let allowed = Set(node.kind == .accordion ? (node.children ?? []).map(\.id) : (node.options?.map(\.id) ?? node.items ?? []))
                    if let data = value.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) {
                        valid = Set(ids).count == ids.count && Set(ids).isSubset(of: allowed)
                    } else { valid = false }
                case .tabs: valid = (node.children ?? []).contains { $0.id == value }
                case .numberField, .slider, .stepper, .rating:
                    valid = IOSIntelligentUIComponentValues.isValidNumericDraft(value, input: node)
                case .datePicker: valid = IOSIntelligentUIComponentValues.isValidDateString(value, timeOnly: false)
                case .timePicker: valid = IOSIntelligentUIComponentValues.isValidDateString(value, timeOnly: true)
                default: break
                }
                guard valid else { throw issue("字段“\(node.title ?? fieldID)”的值不符合组件要求。") }
            }
            try validateDraftValues(values, components: node.children ?? [])
        }
    }

    /// References only read typed numeric fields owned by inputs in this card.
    static func validateValueReferences(_ components: [IOSIntelligentUIComponent],
                                        numberFieldIDs: Set<String>,
                                        inputComponents: [IOSIntelligentUIComponent]) throws {
        let owners = Dictionary(grouping: IOSIntelligentUIComponentValues.numericInputs(in: inputComponents)) { $0.fieldID ?? "" }
        func validateReference(_ fieldID: String) throws {
            guard numberFieldIDs.contains(fieldID), let inputs = owners[fieldID], let first = inputs.first else {
                throw issue("数值引用必须指向本卡 type=number 且有数字输入组件的字段：\(fieldID)。")
            }
            let bounds = IOSIntelligentUIComponentValues.numericBounds(for: first)
            let initial = IOSIntelligentUIComponentValues.defaultNumber(for: first)
            guard inputs.allSatisfy({
                IOSIntelligentUIComponentValues.numericBounds(for: $0) == bounds &&
                $0.numericStep == first.numericStep &&
                IOSIntelligentUIComponentValues.defaultNumber(for: $0) == initial &&
                ($0.kind == .rating) == (first.kind == .rating)
            }) else {
                throw issue("被引用字段的多个数字输入需要一致的范围、步长和预览初值：\(fieldID)。")
            }
        }
        func walk(_ nodes: [IOSIntelligentUIComponent]) throws {
            for node in nodes {
                if let fieldID = node.valueFieldID { try validateReference(fieldID) }
                for row in node.rows ?? [] {
                    if let fieldID = row.valueFieldID { try validateReference(fieldID) }
                }
                try walk(node.children ?? [])
            }
        }
        try walk(components)
    }

    static let capabilityPrompt = """
    可选 components 支持 80 个原生组件，以数据组合界面，不执行代码。每个节点有唯一 id、kind，可选 title/text。
    组件节点只允许 id/kind/title/text/children/items/options/field_id/value/value_field_id/min/max/step/columns/rows/symbol/url/action/style；children 内的节点遵守同一规则。下面的键是按组件需要选择的可选能力，不要给每个节点填满全部属性。
    布局：stack,column,row,grid,card,panel,group,inset,divider,spacer。
    column 纵向排列，row 横向排列；stack 是重叠布局（ZStack），不是纵向列表。标签页内有多项内容时使用 column，不用 stack 叠在一起。
    文本：title,subtitle,body,caption,callout,quote,inlineCode,bulletList,numberedList,keyValue,footnote,highlight。
    状态：badge,chip,tag,statusDot,progress,stepProgress,skeleton,emptyState,notice,alert。
    输入：singleChoice,multiChoice,segmented,picker,toggle,textField,textArea,numberField,slider,stepper,datePicker,timePicker,rating,colorChoice。
    数据：metric,metricGrid,table,list,comparison,timeline,steps,checklist,barChart,lineChart。
    媒体：image,imageGrid,avatar,icon,linkCard,fileCard,codeBlock,diagram。
    任务：goal,context,source,reason,tradeoff,result,assumptions,decisionSummary。
    操作：button,buttonGroup,submitButton,resetButton,disclosure,tabs,accordion,menu。
    输入及 checklist/disclosure/tabs/accordion/menu 必须 field_id 引用 fields 已声明的 id。只有 decision 的决策方案由根 options 单选承担，其他任务不需要根 options。
    field.type 与绑定组件对应：text→textField/textArea（也可不绑定）；number→numberField/slider/stepper/rating；bool→toggle；date→datePicker；time→timePicker。
    choice→singleChoice/segmented/picker/colorChoice/menu；multiChoice→multiChoice/checklist；presentation→disclosure/tabs/accordion。字段 type 不是控件 kind，不写 type=slider/select/checkbox。
    组件的 options 每项必填 id/label，可选 detail/color，选择控件需 1–20 项；items 是文字数组；rows 每行只允许 label/value/value_field_id/detail/cells，cells 是文字数组。
    【内容形状：按实际渲染入口填写，不套用通用表格结构】
    - rows[].value 只能是 JSON 数字，不能放文字或数字字符串。文字说明用 rows[].detail，表格文字用 rows[].cells；组件的 value 也只能为数字。
    - keyValue 使用 title/text 展示一对键值，不读取 rows。多对键值用 column.children 内的多个 keyValue；不要写 rows:[{label,value:"文字"}]。
    - comparison 使用 options（id/label/detail）展示比较项，不读取 rows，也不需要 field_id；它不是 singleChoice，不会选择方案。
    - timeline/steps/list 使用 rows，每行必填 label、可选 detail；这些组件不读取 items。bulletList/numberedList 使用 items；stepProgress.items 是步骤标签。
    - table.items 是列标题，rows[].cells 是要显示的完整一行，包括第一列；提供 cells 后不会自动加上 row.label。若要显示行标签，请把它也放入 cells。
    min/max/step/value 使用 JSON 数字，网格 columns 为1–4的整数。用户操作后宿主草稿才使用字符串：slider/stepper 为数值字符串，toggle 为 true/false，多选为 id 的JSON数组字符串；不要把草稿值格式写进组件 JSON。
    toggle 和选择控件不设置 value/selected/default，不替用户预选。选项的 id/label 是字符串，required/recommended 是布尔值，不写成字符串。
    metric/progress/stepProgress 可用 value_field_id 代替 value；barChart/lineChart 的每行也可用 value_field_id 代替 value。
    引用必须是本卡 fields 中 type=number 且由 numberField/slider/stepper/rating 输入绑定的字段。相同字段的多个数字输入必须有一致范围、步长和预览初值。
    只有通过 value_field_id 引用的数字输入变化会立即更新对应图形；不支持公式、跨卡引用或脚本。progress.max 是总值，stepProgress.items 是步骤标签。value 与 value_field_id 不能同时出现。
    segmented/picker/colorChoice 等选择控件只保存字段偏好，不驱动布局、主题或图表；colorChoice 只展示色板，不改变 App 配色。不声称切换它们会更新其他组件，需要进一步处理时显式提交给 agent。
    数字输入的 value 仅是未确认的预览初值，slider/stepper 未指定时预览范围下界；其他数字输入未指定初值时等待输入。预览不保存、不进入提交，用户操作或确认后才保存数值；非法数值显示错误，不替换成零。
    datePicker 传 yyyy-MM-dd，timePicker 传 HH:mm，rating 传整数，其他单选传 option.id。不要用默认值替用户做选择。
    children 只用于 stack/column/row/grid/card/panel/group/inset/metricGrid/imageGrid/buttonGroup/disclosure/tabs/accordion；最大8层、160节点。
    tabs/accordion 的页面内容放在 children，不是 options；每个子节点要有 title，field_id 绑定 type=presentation、required=false 的字段，分别保存当前子 id / 展开子 id 数组；disclosure 保存 true/false。
    媒体 url 只接受 HTTPS；linkCard/fileCard/source 仅展示引用，不执行打开或工具动作；不能将模型文案标成已验证事实。
    button.action 只能 continue 或 reset；submitButton/resetButton 固定由宿主提交/重置。
    colorChoice.option.color 支持 accent,red,orange,yellow,green,cyan,blue,indigo,purple,pink,gray。
    样式 style 只允许 tone/emphasis/density/alignment/spacing/padding；不要生成 CSS、hex 颜色或自定义尺寸。
    tone:neutral/accent/success/warning/danger；emphasis:plain/soft/outlined/filled；density:compact/comfortable；alignment:leading/center；spacing 和 padding:none/small/medium/large。
    状态颜色只表达文案含义，不证明执行结果。
    需要简洁时不填 components，按当前 kind 使用默认界面；study 的翻卡和测验无需额外组件。适合补充数据时选少量组件组合，不为展示目录而堆砌。
    例：{"id":"budget","kind":"slider","title":"预算","field_id":"budget","min":0,"max":10000,"step":100}。
    例：{"id":"evidence","kind":"disclosure","title":"查看依据","field_id":"evidence_open","children":[{"id":"source1","kind":"source","text":"用户提供的需求；未做外部核验"}]}。
    例：{"id":"stats","kind":"barChart","title":"估算耗时","rows":[{"label":"方案A","value":3},{"label":"方案B","value":7}]}。
    """

    private static func issue(_ reason: String) -> IOSIntelligentUIComponentError { .init(reason: reason) }
}

/// Conversion lives outside rendering. Array decoding is performed by events/lifecycle, not body.
enum IOSIntelligentUIComponentValues {
    static func numericInputs(in components: [IOSIntelligentUIComponent]) -> [IOSIntelligentUIComponent] {
        components.flatMap { node in
            (node.kind.isNumericInput ? [node] : []) + numericInputs(in: node.children ?? [])
        }
    }

    static func numericBounds(for input: IOSIntelligentUIComponent) -> ClosedRange<Double> {
        switch input.kind {
        case .numberField: (input.min ?? -.greatestFiniteMagnitude)...(input.max ?? .greatestFiniteMagnitude)
        case .rating: 1...(input.max ?? 5)
        default: input.numericRange
        }
    }

    static func isValidNumericDraft(_ rawValue: String, input: IOSIntelligentUIComponent) -> Bool {
        guard !rawValue.isEmpty else { return true }
        guard let number = Double(rawValue), number.isFinite, numericBounds(for: input).contains(number) else { return false }
        return input.kind != .rating || number.rounded() == number
    }

    static func hasValidNumericDraftValues(_ values: [String: String], components: [IOSIntelligentUIComponent]) -> Bool {
        numericInputs(in: components).allSatisfy { input in
            isValidNumericDraft(values[input.fieldID ?? ""] ?? "", input: input)
        }
    }

    /// A preview is a display value, never a write to the user's draft.
    static func defaultNumber(for input: IOSIntelligentUIComponent) -> Double? {
        guard input.kind.isNumericInput else { return nil }
        if input.kind == .slider || input.kind == .stepper {
            let range = input.numericRange
            return min(max(input.value ?? range.lowerBound, range.lowerBound), range.upperBound)
        }
        guard let value = input.value, isValidNumericDraft(String(value), input: input) else { return nil }
        return value
    }

    static func numericValue(_ rawValue: String?, input: IOSIntelligentUIComponent) -> Double? {
        guard let rawValue, !rawValue.isEmpty else { return defaultNumber(for: input) }
        guard isValidNumericDraft(rawValue, input: input) else { return nil }
        return Double(rawValue)
    }

    /// Draft storage must preserve the control's value, including sub-millionth steps.
    static func numericDraftString(_ number: Double) -> String { String(number) }

    static func numericDisplayString(_ number: Double) -> String {
        let magnitude = abs(number)
        if number != 0 && (magnitude < 1e-9 || magnitude >= 1e15) {
            return number.formatted(.number.notation(.scientific).precision(.significantDigits(1...15)))
        }
        return number.formatted(.number.precision(.significantDigits(1...15)))
    }

    static func resolveNumber(value: Double?, valueFieldID: String?, draftValues: [String: String],
                              fieldComponents: [String: IOSIntelligentUIComponent]) -> Double? {
        guard let fieldID = valueFieldID else { return value }
        guard let input = fieldComponents[fieldID], input.kind.isNumericInput else { return nil }
        return numericValue(draftValues[fieldID], input: input)
    }

    static func encodeSelection(_ ids: Set<String>) -> String {
        let data = try? JSONEncoder().encode(ids.sorted())
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decodeSelection(_ value: String) -> Set<String> {
        guard let data = value.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    static func toggling(_ id: String, in selection: Set<String>) -> Set<String> {
        var next = selection
        if !next.insert(id).inserted { next.remove(id) }
        return next
    }

    static func summary(_ rawValue: String, for component: IOSIntelligentUIComponent) -> String {
        guard !rawValue.isEmpty else { return "" }
        switch component.kind {
        case .multiChoice, .checklist, .accordion:
            let ids = decodeSelection(rawValue)
            let options = component.options ?? component.items?.map { .init(id: $0, label: $0) } ?? []
            return options.filter { ids.contains($0.id) }.map(\.label).joined(separator: "、")
        case .toggle, .disclosure: return rawValue == "true" ? "是" : "否"
        case .singleChoice, .segmented, .picker, .colorChoice, .menu:
            return component.options?.first(where: { $0.id == rawValue })?.label ?? rawValue
        case .tabs: return component.children?.first(where: { $0.id == rawValue })?.title ?? rawValue
        default: return rawValue
        }
    }

    static func date(from string: String, timeOnly: Bool, fallback: Date = Date()) -> Date {
        let formatter = dateFormatter(timeOnly: timeOnly)
        return formatter.date(from: string) ?? fallback
    }

    static func dateString(_ date: Date, timeOnly: Bool) -> String {
        dateFormatter(timeOnly: timeOnly).string(from: date)
    }

    static func isValidDateString(_ string: String, timeOnly: Bool) -> Bool {
        let formatter = dateFormatter(timeOnly: timeOnly)
        guard let date = formatter.date(from: string) else { return false }
        return formatter.string(from: date) == string
    }

    private static func dateFormatter(timeOnly: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = timeOnly ? "HH:mm" : "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
