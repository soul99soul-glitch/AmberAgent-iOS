import SwiftUI

/// Session values are owned by the existing conversation draft, not by recycled rows.
struct IOSIntelligentUIStudyView: View {
    let definition: IOSIntelligentUIStudyDefinition
    @Binding var values: [String: String]
    var isEnabled = true

    @State private var session = IOSIntelligentUIStudySession()
    @State private var sessionError: String?
    @State private var restoredDefinition: IOSIntelligentUIStudyDefinition?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var quizCount: Int { definition.items.filter { !($0.options ?? []).isEmpty }.count }
    private var itemCount: Int { session.mode == .review ? definition.items.count : quizCount }

    var body: some View {
        Group {
            if restoredDefinition == definition {
                studyContent
            } else {
                ProgressView("正在恢复练习…")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .onAppear(perform: restore)
        .onChange(of: values[IOSIntelligentUIStudySession.storageKey]) { _, _ in restore() }
        .onChange(of: definition) { _, _ in restore() }
    }

    private var studyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if quizCount > 0 {
                HStack(spacing: 8) {
                    modeButton(.review, label: "复习", symbol: "rectangle.on.rectangle")
                    modeButton(.quiz, label: "抽考", symbol: "questionmark.circle")
                }
            }
            if let sessionError {
                Label(sessionError, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-ui-study-error")
            }
            Text("第 \(session.index + 1) / \(itemCount) \(session.mode == .review ? "张" : "题")")
                .font(.caption.weight(.medium))
                .foregroundStyle(AmberTheme.muted)
                .accessibilityIdentifier("task-ui-study-progress")
            ProgressView(value: session.mode == .review ? Double(session.index + 1) : Double(session.summary(definition: definition).answeredCount),
                         total: Double(itemCount))
                .tint(AmberTheme.accent)
                .accessibilityLabel(session.mode == .review ? "卡片浏览进度" : "练习作答进度")
            itemContent(session.currentItem(definition: definition))
            if session.mode == .quiz {
                let summary = session.summary(definition: definition)
                Text("已答 \(summary.answeredCount) / \(summary.totalQuizCount) 题 · 答对 \(summary.correctCount) 题")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-ui-study-score")
            }
            Button {
                change { try $0.next(definition: definition) }
            } label: {
                Label(nextLabel, systemImage: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(AmberTheme.accent)
            .disabled(!isEnabled || sessionError != nil || !session.canGoNext(definition: definition))
            .accessibilityIdentifier("task-ui-study-next")
            Button {
                var fresh = IOSIntelligentUIStudySession()
                if session.mode == .quiz {
                    do { try fresh.setMode(.quiz, definition: definition) }
                    catch { sessionError = error.localizedDescription; return }
                }
                save(fresh)
            } label: {
                Text("重新练习")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AmberTheme.accent)
            .disabled(!isEnabled)
            .accessibilityIdentifier("task-ui-study-reset")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-ui-study")
    }

    private var nextLabel: String {
        if session.index + 1 == itemCount { return session.mode == .review ? "已到最后一张" : "已到最后一题" }
        return session.mode == .review ? "下一张" : "下一题"
    }

    private func modeButton(_ mode: IOSIntelligentUIStudySession.Mode, label: String, symbol: String) -> some View {
        Button {
            change { try $0.setMode(mode, definition: definition) }
        } label: {
            VStack(spacing: 4) {
                if !dynamicTypeSize.isAccessibilitySize { Image(systemName: symbol) }
                Text(label).fixedSize(horizontal: false, vertical: true)
            }
                .font(.subheadline.weight(.medium))
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(session.mode == mode ? AmberTheme.accent.opacity(0.1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(session.mode == mode ? AmberTheme.accent : AmberTheme.borderSoft))
        }
        .buttonStyle(.plain)
        .foregroundStyle(session.mode == mode ? AmberTheme.accent : AmberTheme.muted)
        .disabled(!isEnabled || sessionError != nil)
        .accessibilityValue(session.mode == mode ? "当前模式" : "")
        .accessibilityIdentifier("task-ui-study-mode-\(mode == .review ? "review" : "quiz")")
    }

    @ViewBuilder private func itemContent(_ item: IOSIntelligentUIStudyDefinition.Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.prompt)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("task-ui-study-prompt")
            if session.mode == .review {
                if session.revealed {
                    answerContent(item)
                } else {
                    Button {
                        change { try $0.reveal(definition: definition) }
                    } label: {
                        Label("查看答案", systemImage: "eye")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isEnabled || sessionError != nil)
                    .accessibilityIdentifier("task-ui-study-reveal")
                }
            } else {
                let feedback = session.feedback(definition: definition)
                ForEach(item.options ?? []) { option in
                    choiceButton(option, item: item)
                }
                if let feedback {
                    Label(feedback.isCorrect ? "答对了" : "再记一下这题", systemImage: feedback.isCorrect ? "checkmark.circle.fill" : "info.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(feedback.isCorrect ? AmberTheme.accentGreen : AmberTheme.accentRed)
                        .accessibilityIdentifier("task-ui-study-feedback")
                    answerContent(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerContent(_ item: IOSIntelligentUIStudyDefinition.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.answer)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("task-ui-study-answer")
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func choiceButton(_ option: IOSIntelligentUIStudyDefinition.Choice,
                                          item: IOSIntelligentUIStudyDefinition.Item) -> some View {
        if session.answers[item.id] != nil {
            choiceLabel(option, item: item)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(option.label)
                .accessibilityValue(answerAccessibilityValue(option, item: item))
                .accessibilityIdentifier("task-ui-study-choice-\(option.id)")
        } else {
            Button {
                change { try $0.answer(optionID: option.id, definition: definition) }
            } label: {
                choiceLabel(option, item: item)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled || sessionError != nil)
            .accessibilityLabel(option.label)
            .accessibilityValue("未选择")
            .accessibilityIdentifier("task-ui-study-choice-\(option.id)")
        }
    }

    private func choiceLabel(_ option: IOSIntelligentUIStudyDefinition.Choice,
                             item: IOSIntelligentUIStudyDefinition.Item) -> some View {
        let selected = session.answers[item.id] == option.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? AmberTheme.accent : AmberTheme.muted)
                .padding(.top, 2)
            Text(option.label)
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(selected ? AmberTheme.accent.opacity(0.08) : AmberTheme.surface,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? AmberTheme.accent : AmberTheme.borderSoft))
    }

    private func answerAccessibilityValue(_ option: IOSIntelligentUIStudyDefinition.Choice,
                                          item: IOSIntelligentUIStudyDefinition.Item) -> String {
        let selected = session.answers[item.id] == option.id
        if selected { return option.id == item.correctOptionID ? "已选择，答案正确" : "已选择，答案错误" }
        return option.id == item.correctOptionID ? "未选择，正确答案" : "未选择"
    }

    private func restore() {
        do {
            session = try IOSIntelligentUIStudySession.restore(values[IOSIntelligentUIStudySession.storageKey], definition: definition)
            sessionError = nil
        } catch {
            session = IOSIntelligentUIStudySession()
            sessionError = "练习记录无法恢复：\(error.localizedDescription) 可重新练习。"
        }
        restoredDefinition = definition
    }

    private func change(_ action: (inout IOSIntelligentUIStudySession) throws -> Void) {
        do {
            var next = session
            try action(&next)
            save(next)
        } catch { sessionError = error.localizedDescription }
    }

    private func save(_ next: IOSIntelligentUIStudySession) {
        do {
            let raw = try next.encodedValue()
            var updated = values
            updated[IOSIntelligentUIStudySession.storageKey] = raw
            values = updated
            // The host can reject a stale source. Do not show an unsaved local session.
            if values[IOSIntelligentUIStudySession.storageKey] == raw {
                session = next
                sessionError = nil
            }
        } catch { sessionError = error.localizedDescription }
    }
}
