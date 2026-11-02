import SwiftUI

extension DesktopTheme {
    static var inset: Color { paperDeep }
    static var warning: Color { accent }
    static var accentSoft: Color { honeySoft }
    static var codeSurface: Color { paperDeep }
    static var cardShadow: Color { Color.black.opacity(0.06) }
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 14
}

/// Bridges shared `IOSIntelligentUI*View` tokens to macOS `DesktopTheme` ("琥珀含光").
enum AmberTheme {
    static var accent: Color { DesktopTheme.accent }
    static var accentInk: Color { DesktopTheme.accentInk }
    static var accentTint: Color { DesktopTheme.accentSoft }
    static var accentGreen: Color { DesktopTheme.success }
    static var accentYellow: Color { DesktopTheme.warning }
    static var statusAmber: Color { DesktopTheme.warning }
    static var accentRed: Color { DesktopTheme.danger }
    static var foreground: Color { DesktopTheme.ink }
    static var foreground2: Color { DesktopTheme.inkSecondary }
    static var muted: Color { DesktopTheme.inkTertiary }
    static var muted2: Color { DesktopTheme.inkTertiary.opacity(0.75) }
    static var surface: Color { DesktopTheme.card }
    static var surface2: Color { DesktopTheme.inset }
    static var border: Color { DesktopTheme.hairline }
    static var borderSoft: Color { DesktopTheme.hairline }
}

/// Activity indicator used by shared streaming preview and skeleton components.
struct IOSGenerationActivityIndicator: View {
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "circle.grid.2x2.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DesktopTheme.accent)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isActive && !reduceMotion)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

extension View {
    func nativeGenerationReveal(key: String?) -> some View {
        self.transition(.opacity)
    }
}

extension EnvironmentValues {
    @Entry var desktopIntelligentUIHost: DesktopIntelligentUIHost? = nil
    @Entry var desktopIntelligentUIConversationID: String? = nil
    @Entry var desktopIntelligentUIBusy = false
    @Entry var desktopIntelligentUIEnabled = true
}

/// Native macOS card surface for `task-ui v1` (`decision`, `form`, `explore`, `study`).
@MainActor
struct DesktopIntelligentUICard: View {
    let definition: IOSIntelligentUICardDefinition
    @Binding var selectedOptionID: String?
    @Binding var values: [String: String]
    var isEditable = true
    var isSubmitEnabled = false
    var isInsertDraftEnabled = false
    var wasSubmitted = false
    var status: String?
    var error: String?
    var onSubmit: () -> Void = {}
    var onInsertDraft: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            Text(definition.goal)
                .font(DesktopTheme.serif(size: 16, weight: .semibold))
                .foregroundStyle(DesktopTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !definition.question.isEmpty {
                Text(definition.question)
                    .font(.system(size: 13))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !definition.options.isEmpty {
                VStack(spacing: 8) {
                    ForEach(definition.options) { option in
                        optionRow(option)
                    }
                }
            }
            if let study = definition.study {
                IOSIntelligentUIStudyView(definition: study, values: $values, isEnabled: isEditable)
            }
            ForEach(definition.components) { component in
                IOSIntelligentUIComponentView(
                    component: component,
                    draftValues: $values,
                    isEnabled: isEditable,
                    canSubmit: canTriggerSubmit,
                    fieldLabels: Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.id, $0.label) }),
                    fieldComponents: Dictionary(uniqueKeysWithValues: definition.fields.compactMap { field in
                        definition.boundComponent(for: field.id).map { (field.id, $0) }
                    }),
                    requiredFieldIDs: Set(definition.fields.filter(\.required).map(\.id)),
                    onSubmit: submitIfReady,
                    onReset: resetDraft
                )
            }
            ForEach(definition.fields.filter { definition.boundComponent(for: $0.id) == nil }) { field in
                unboundFieldRow(field)
            }
            if let selected = definition.options.first(where: { $0.id == selectedOptionID }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.accent)
                    Text("已选方案：\(selected.title)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                }
                .accessibilityIdentifier("task-ui-selection")
            }
            if let status, !status.isEmpty {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-ui-error")
            }
            actionFooter
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesktopTheme.radiusLarge)
                .fill(DesktopTheme.card)
                .shadow(color: DesktopTheme.cardShadow, radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesktopTheme.radiusLarge)
                .stroke(wasSubmitted ? DesktopTheme.honeyEdge : DesktopTheme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-ui-card-\(definition.cardID)")
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Label(kindTitle, systemImage: kindSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesktopTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DesktopTheme.honeySoft, in: Capsule())
                .overlay(Capsule().stroke(DesktopTheme.honeyEdge, lineWidth: 0.75))
            Text(definition.cardID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesktopTheme.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if wasSubmitted {
                Label("已提交", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesktopTheme.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DesktopTheme.success.opacity(0.12), in: Capsule())
            } else if !isEditable {
                Text("只读")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DesktopTheme.inset, in: Capsule())
            }
        }
    }

    private func unboundFieldRow(_ field: IOSIntelligentUICardDefinition.Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(field.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesktopTheme.ink)
                if field.required {
                    Text("必填")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesktopTheme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DesktopTheme.honeySoft, in: Capsule())
                }
            }
            TextField(field.placeholder ?? "请输入…", text: fieldBinding(field.id), axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DesktopTheme.ink)
                .padding(10)
                .frame(minHeight: 38)
                .background(DesktopTheme.inset, in: RoundedRectangle(cornerRadius: DesktopTheme.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: DesktopTheme.radiusSmall)
                        .stroke(DesktopTheme.hairline, lineWidth: 1)
                )
                .disabled(!isEditable)
                .accessibilityLabel(field.label + (field.required ? "，必填" : ""))
                .accessibilityIdentifier("task-ui-field-\(field.id)")
        }
    }

    private var actionFooter: some View {
        HStack(spacing: 10) {
            Button(action: submitIfReady) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(definition.submit.label)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.desktopProminent)
            .disabled(!canTriggerSubmit)
            .accessibilityIdentifier("task-ui-submit-\(definition.cardID)")

            Button(action: insertDraftIfReady) {
                HStack(spacing: 5) {
                    Image(systemName: "text.insert")
                        .font(.system(size: 11, weight: .medium))
                    Text("填入输入框草稿")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.desktopActionPill)
            .disabled(!canTriggerInsertDraft)
            .help("将当前卡片选择与输入整理成结构化草稿追加到输入框，保留已有草稿与附件")
            .accessibilityIdentifier("task-ui-insert-draft-\(definition.cardID)")

            Spacer(minLength: 0)

            if hasAnyUserChanges && isEditable {
                Button("重置", action: resetDraft)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .accessibilityIdentifier("task-ui-reset-\(definition.cardID)")
            }
        }
        .padding(.top, 2)
    }

    private var hasAnyUserChanges: Bool {
        selectedOptionID != nil || values.contains { !$0.value.isEmpty }
    }

    private var hasValidNumericInput: Bool {
        IOSIntelligentUIComponentValues.hasValidNumericDraftValues(values, components: definition.components)
    }

    private var hasRequiredInput: Bool {
        (definition.kind != "decision" || selectedOptionID != nil) && definition.submissionFields.allSatisfy { field in
            let value = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = definition.boundComponent(for: field.id)?.kind
            let emptySelection = (kind == .multiChoice || kind == .checklist) && value == "[]"
            return !field.required || (!value.isEmpty && !emptySelection)
        }
    }

    private var canTriggerSubmit: Bool {
        isEditable && isSubmitEnabled && hasRequiredInput && hasValidNumericInput
    }

    private var canTriggerInsertDraft: Bool {
        isEditable && isInsertDraftEnabled && hasRequiredInput && hasValidNumericInput
    }

    private var kindTitle: String {
        switch definition.kind {
        case "study": "学习与练习"
        case "explore": "交互探索"
        case "form": "信息填写"
        default: "任务决策"
        }
    }

    private var kindSymbol: String {
        switch definition.kind {
        case "study": "rectangle.on.rectangle"
        case "explore": "slider.horizontal.3"
        case "form": "square.and.pencil"
        default: "list.bullet.clipboard"
        }
    }

    private func submitIfReady() {
        guard canTriggerSubmit else { return }
        onSubmit()
    }

    private func insertDraftIfReady() {
        guard canTriggerInsertDraft else { return }
        onInsertDraft()
    }

    private func resetDraft() {
        selectedOptionID = nil
        values = [:]
    }

    private func fieldBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { values[id] ?? "" },
            set: { values[id] = String($0.prefix(2_000)) }
        )
    }

    private func optionRow(_ option: IOSIntelligentUICardDefinition.Option) -> some View {
        let selected = selectedOptionID == option.id
        return Button {
            selectedOptionID = option.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesktopTheme.ink)
                        if option.recommended == true {
                            Text("推荐")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesktopTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(DesktopTheme.honeySoft, in: Capsule())
                        }
                    }
                    Text(option.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    ForEach(Array((option.tradeoffs ?? []).enumerated()), id: \.offset) { _, tradeoff in
                        Text("• " + tradeoff)
                            .font(.system(size: 11))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? DesktopTheme.honeySoft : DesktopTheme.inset,
                in: RoundedRectangle(cornerRadius: DesktopTheme.radiusMedium)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesktopTheme.radiusMedium)
                    .stroke(selected ? DesktopTheme.accent : DesktopTheme.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesktopTheme.radiusMedium))
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .accessibilityLabel(([option.title, option.summary] + (option.tradeoffs ?? []) + (option.recommended == true ? ["推荐"] : [])).joined(separator: "，"))
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityIdentifier("task-ui-option-\(option.id)")
    }
}

/// Binds a `task-ui` card in the macOS transcript to `DesktopIntelligentUIHost`.
@MainActor
struct DesktopIntelligentUIBlock: View {
    let definition: IOSIntelligentUICardDefinition
    let isMessageComplete: Bool
    var interactionEnabled = true
    var messageID: String? = nil
    var textPartIndex = 0

    @Environment(\.desktopIntelligentUIHost) private var host
    @Environment(\.desktopIntelligentUIConversationID) private var conversationID
    @Environment(\.desktopIntelligentUIBusy) private var isBusy
    @State private var error: String? = nil
    @State private var lastResult: DesktopIntelligentUISubmitResult? = nil

    init(
        definition: IOSIntelligentUICardDefinition,
        isMessageComplete: Bool,
        interactionEnabled: Bool = true,
        messageID: String? = nil,
        textPartIndex: Int = 0
    ) {
        self.definition = definition
        self.isMessageComplete = isMessageComplete
        self.interactionEnabled = interactionEnabled
        self.messageID = messageID
        self.textPartIndex = textPartIndex
    }

    private var source: IOSIntelligentUISource? {
        guard let conversationID, let messageID else { return nil }
        return IOSIntelligentUISource(
            conversationID: conversationID,
            messageID: messageID,
            textPartIndex: textPartIndex,
            cardID: definition.cardID
        )
    }

    var body: some View {
        if let source, let host {
            let _ = host.stateStore.revision
            let draft = host.stateStore.draft(for: source, definition: definition)
            let wasSubmitted = host.receipts[source]?.matches(draft) == true
            let isPending = host.pending.contains(source)
            DesktopIntelligentUICard(
                definition: definition,
                selectedOptionID: Binding(
                    get: { host.stateStore.draft(for: source, definition: definition).selectedOptionID },
                    set: { update(host, source: source, selection: $0, values: host.stateStore.draft(for: source, definition: definition).values) }
                ),
                values: Binding(
                    get: { host.stateStore.draft(for: source, definition: definition).values },
                    set: { update(host, source: source, selection: host.stateStore.draft(for: source, definition: definition).selectedOptionID, values: $0) }
                ),
                isEditable: isMessageComplete && interactionEnabled && !isPending,
                isSubmitEnabled: !isBusy && !wasSubmitted && !isPending,
                isInsertDraftEnabled: !isPending,
                wasSubmitted: wasSubmitted,
                status: statusText(host, source: source, submitted: wasSubmitted, pending: isPending),
                error: error ?? host.stateStore.storageError,
                onSubmit: {
                    Task {
                        error = nil
                        let result = await host.submit(source: source, definition: definition)
                        lastResult = result
                        if case .failure(let reason) = result { error = reason }
                    }
                },
                onInsertDraft: {
                    error = nil
                    let result = host.insertIntoDraft(source: source, definition: definition)
                    lastResult = result
                    if case .failure(let reason) = result { error = reason }
                }
            )
            .onAppear { host.stateStore.register(source: source, definition: definition) }
            .onChange(of: definition) { _, _ in
                host.stateStore.register(source: source, definition: definition)
                error = nil
                lastResult = nil
            }
        } else {
            DesktopIntelligentUICard(
                definition: definition,
                selectedOptionID: .constant(nil),
                values: .constant([:]),
                isEditable: false,
                status: "当前预览未关联会话，仅供浏览结构。"
            )
        }
    }

    private func update(
        _ host: DesktopIntelligentUIHost,
        source: IOSIntelligentUISource,
        selection: String?,
        values: [String: String]
    ) {
        do {
            try host.stateStore.update(
                source: source,
                definition: definition,
                selectedOptionID: selection,
                values: values
            )
            error = nil
            lastResult = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func statusText(
        _ host: DesktopIntelligentUIHost,
        source: IOSIntelligentUISource,
        submitted: Bool,
        pending: Bool
    ) -> String? {
        if !interactionEnabled { return "智能 UI 交互已在设置中关闭。" }
        if !isMessageComplete { return "回复成功完成后可操作；未完成或中断的任务卡不可提交。" }
        if pending { return "正在保存并提交本次选择…" }
        if host.stateStore.hasDefinitionChanged(for: source, definition: definition) {
            return "任务卡内容已更新，请重新确认选择。"
        }
        if lastResult == .draftInserted {
            return "已将结构化结果追加到下方输入框草稿（保留原有草稿与附件），可编辑后发送。"
        }
        if submitted {
            return lastResult == .saved
                ? "结果已作为用户消息保存到当前会话；配置服务商后可继续生成。"
                : "已作为聊天消息提交；修改选项或输入后可再次提交。"
        }
        if isBusy {
            return "操作会实时保存在本地；当前生成结束后可直接提交，或先点击「填入输入框草稿」。"
        }
        return definition.kind == "study"
            ? "翻卡与抽考在本地完成；完成后可点击提交继续或填入输入框草稿。"
            : "选择与输入自动保存在本地；可点击提交直接继续，或填入输入框草稿后再编辑。"
    }
}

/// Recoverable fallback card when a `task-ui` block fails JSON decoding or schema validation.
@MainActor
struct DesktopIntelligentUIInvalidCard: View {
    let raw: String
    let reason: String
    @State private var isExpanded = false

    init(raw: String, reason: String) {
        self.raw = raw
        self.reason = reason
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesktopTheme.warning)
                Text("智能 UI 任务卡未能渲染：\(reason)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("后续正文与媒体不受影响；你可展开查看模型输出的原始 task-ui 内容。")
                .font(.system(size: 11))
                .foregroundStyle(DesktopTheme.inkTertiary)
            DisclosureGroup("查看原始 task-ui 内容", isExpanded: $isExpanded) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(raw)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesktopTheme.codeSurface, in: RoundedRectangle(cornerRadius: DesktopTheme.radiusSmall))
                .padding(.top, 4)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DesktopTheme.inkSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesktopTheme.inset, in: RoundedRectangle(cornerRadius: DesktopTheme.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: DesktopTheme.radiusMedium)
                .stroke(DesktopTheme.warning.opacity(0.45), lineWidth: 1)
        )
        .accessibilityIdentifier("task-ui-invalid-card")
    }
}
