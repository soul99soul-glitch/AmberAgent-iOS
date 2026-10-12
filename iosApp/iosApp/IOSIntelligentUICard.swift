import SwiftUI

/// Native interactions keep drafts local; only explicit continuation reaches the agent.
struct IOSIntelligentUICard: View {
    let definition: IOSIntelligentUICardDefinition
    @Binding var selectedOptionID: String?
    @Binding var values: [String: String]
    var isEditable = true
    var isSubmitEnabled = false
    var status: String?
    var error: String?
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(kindTitle, systemImage: kindSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.accent)
            Text(definition.goal)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !definition.question.isEmpty {
                Text(definition.question)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
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
                IOSIntelligentUIComponentView(component: component, draftValues: $values,
                                             isEnabled: isEditable, canSubmit: isEditable && isSubmitEnabled && hasRequiredInput && hasValidNumericInput,
                                             fieldLabels: Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.id, $0.label) }),
                                             fieldComponents: Dictionary(uniqueKeysWithValues: definition.fields.compactMap { field in
                                                 definition.boundComponent(for: field.id).map { (field.id, $0) }
                                             }),
                                             requiredFieldIDs: Set(definition.fields.filter(\.required).map(\.id)),
                                             onSubmit: submitIfReady,
                                             onReset: { selectedOptionID = nil; values = [:] })
            }
            ForEach(definition.fields.filter { definition.boundComponent(for: $0.id) == nil }) { field in
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.label + (field.required ? "（必填）" : ""))
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(field.placeholder ?? "请输入", text: fieldBinding(field.id), axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .frame(minHeight: 44)
                        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AmberTheme.borderSoft))
                        .disabled(!isEditable)
                        .accessibilityLabel(field.label + (field.required ? "，必填" : ""))
                        .accessibilityIdentifier("task-ui-field-\(field.id)")
                }
            }
            if let selected = definition.options.first(where: { $0.id == selectedOptionID }) {
                Text("当前选择：\(selected.title)")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-ui-selection")
            }
            if let status {
                Text(status).font(.footnote).foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(AmberTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-ui-error")
            }
            Button(action: submitIfReady) {
                Text(definition.submit.label)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AmberTheme.accent)
            .disabled(!isEditable || !isSubmitEnabled || !hasRequiredInput || !hasValidNumericInput)
            .accessibilityIdentifier("task-ui-submit-\(definition.cardID)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AmberTheme.borderSoft))
        // A container keeps this diagnostic ID from replacing each native control's ID.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-ui-card-\(definition.cardID)")
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
        case "explore": "square.grid.2x2"
        case "form": "square.and.pencil"
        default: "list.bullet.clipboard"
        }
    }

    private func submitIfReady() {
        guard isEditable && isSubmitEnabled && hasRequiredInput && hasValidNumericInput else { return }
        onSubmit()
    }

    private func fieldBinding(_ id: String) -> Binding<String> {
        Binding(get: { values[id] ?? "" }, set: { values[id] = String($0.prefix(2_000)) })
    }

    private func optionRow(_ option: IOSIntelligentUICardDefinition.Option) -> some View {
        let selected = selectedOptionID == option.id
        return Button {
            selectedOptionID = option.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? AmberTheme.accent : AmberTheme.muted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(option.title).font(.subheadline.weight(.semibold))
                    if option.recommended == true {
                        Text("推荐").font(.caption.weight(.medium)).foregroundStyle(AmberTheme.accent)
                    }
                    Text(option.summary).font(.subheadline).foregroundStyle(AmberTheme.muted)
                    ForEach(Array((option.tradeoffs ?? []).enumerated()), id: \.offset) { _, tradeoff in
                        Text("• " + tradeoff).font(.footnote).foregroundStyle(AmberTheme.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? AmberTheme.accent.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? AmberTheme.accent : AmberTheme.borderSoft, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .accessibilityLabel(([option.title, option.summary] + (option.tradeoffs ?? []) + (option.recommended == true ? ["推荐"] : [])).joined(separator: "，"))
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityIdentifier("task-ui-option-\(option.id)")
    }
}

/// Draft state lives with the conversation owner, independently of timeline recycling.
struct ChatIntelligentUIBlock: View {
    let definition: IOSIntelligentUICardDefinition
    let isMessageComplete: Bool
    var interactionEnabled = true
    var messageID: String? = nil
    var textPartIndex = 0
    @Environment(\.intelligentUIHost) private var host
    @Environment(\.intelligentUIConversationID) private var conversationID
    @Environment(\.intelligentUIBusy) private var isBusy
    @State private var error: String?
    @State private var lastResult: IOSIntelligentUISubmitResult?

    private var source: IOSIntelligentUISource? {
        guard let conversationID, let messageID else { return nil }
        return IOSIntelligentUISource(conversationID: conversationID, messageID: messageID,
                                      textPartIndex: textPartIndex, cardID: definition.cardID)
    }

    var body: some View {
        if let source, let host {
            let draft = host.stateStore.draft(for: source, definition: definition)
            let wasSubmitted = host.receipts[source]?.matches(draft) == true
            let isPending = host.pending.contains(source)
            IOSIntelligentUICard(
                definition: definition,
                selectedOptionID: Binding(get: { host.stateStore.draft(for: source, definition: definition).selectedOptionID },
                                          set: { update(host, source: source, selection: $0, values: host.stateStore.draft(for: source, definition: definition).values) }),
                values: Binding(get: { host.stateStore.draft(for: source, definition: definition).values },
                                set: { update(host, source: source, selection: host.stateStore.draft(for: source, definition: definition).selectedOptionID, values: $0) }),
                isEditable: isMessageComplete && interactionEnabled && !isPending,
                isSubmitEnabled: !isBusy && !wasSubmitted && !isPending,
                status: status(host, source: source, submitted: wasSubmitted, pending: isPending),
                error: error ?? host.stateStore.storageError,
                onSubmit: {
                    Task {
                        error = nil
                        let result = await host.submit(source: source, definition: definition)
                        lastResult = result
                        if case .failure(let reason) = result { error = reason }
                    }
                }
            )
            .onAppear { host.stateStore.register(source: source, definition: definition) }
            .onChange(of: definition) { _, _ in
                host.stateStore.register(source: source, definition: definition)
                error = nil
                lastResult = nil
            }
        } else {
            IOSIntelligentUICard(definition: definition, selectedOptionID: .constant(nil), values: .constant([:]),
                                 isEditable: false, status: "当前预览不能提交；请在原会话中继续。")
        }
    }

    private func update(_ host: IOSIntelligentUIHost, source: IOSIntelligentUISource,
                        selection: String?, values: [String: String]) {
        do {
            try host.stateStore.update(source: source, definition: definition,
                                       selectedOptionID: selection, values: values)
            error = nil
            lastResult = nil
        } catch { self.error = error.localizedDescription }
    }

    private func status(_ host: IOSIntelligentUIHost, source: IOSIntelligentUISource,
                        submitted: Bool, pending: Bool) -> String? {
        if !interactionEnabled { return "任务界面操作已在设置中关闭。" }
        if !isMessageComplete { return "回复成功完成后可操作；中断的任务卡不能提交。" }
        if pending { return "正在保存本次提交…" }
        if host.stateStore.hasDefinitionChanged(for: source, definition: definition) {
            return "任务卡内容已更新，请重新操作。"
        }
        if submitted {
            return lastResult == .saved ? "结果已保存到原会话；生成尚未开始。" : "已提交本次结果；修改后可以再次提交。"
        }
        if isBusy { return "操作会保存在本地；当前任务结束后可提交。" }
        return definition.kind == "study" ? "翻卡与练习在本地完成；点击继续才会把学习结果发给 agent。" : "操作仅保存在本地，点击继续才会发给 agent。"
    }
}
