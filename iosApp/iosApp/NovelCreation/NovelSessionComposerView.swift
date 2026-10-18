import SwiftUI

struct NovelSessionComposerMetaValues {
    let modelLabel: String
    let contextSnapshot: ChatContextSnapshot
    let contextPanel: NovelInjectionPanelModel
    let currentIntent: NovelComposerIntent
    let needsSync: Bool
    let hasArchivableDiscussion: Bool
    let isBusy: Bool
    let controlsDisabled: Bool
}

struct NovelSessionComposerDock<Chrome: View>: View {
    let chrome: Chrome
    @Binding var inputText: String
    @Binding var inputHeight: CGFloat
    @Binding var isInputFocused: Bool
    @Binding var isContextPanelPresented: Bool
    let placeholder: String
    let isInputEnabled: Bool
    let sendOnEnter: Bool
    let canSend: Bool
    let isRunning: Bool
    let isStopping: Bool
    let canStop: Bool
    let injectionOverrides: NovelInjectionOverrides
    let meta: NovelSessionComposerMetaValues
    let controller: ComposerInputController
    let reduceMotion: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onOpenModel: () -> Void
    let onArchiveDiscussion: () -> Void
    let onSetIntent: (NovelComposerIntent) -> Void

    private var showsMeta: Bool {
        isInputFocused || isContextPanelPresented ||
            !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            injectionOverrides != .none || isRunning || isStopping
    }

    var body: some View {
        VStack(spacing: 8) {
            chrome

            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    ZStack(alignment: .leading) {
                        ComposerInputTextView(
                            text: $inputText,
                            height: $inputHeight,
                            isFocused: $isInputFocused,
                            isEnabled: isInputEnabled,
                            sendOnEnter: sendOnEnter,
                            controller: controller,
                            onSubmit: onSend
                        )
                        .frame(height: max(44, inputHeight))

                        if inputText.isEmpty {
                            Text(placeholder)
                                .font(.body)
                                .foregroundStyle(AmberTheme.muted)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .padding(.leading, 18)
                .padding(.trailing, 18)
                // 与 Chat 一致：内容行 44 + 上下 5 → 外高 54，对齐发送键。
                .padding(.vertical, 5)
                .composerDockGlass(cornerRadius: 27)

                ComposerDockSendButton(
                    isLoading: isRunning && canStop,
                    isStopping: isStopping,
                    sendEnabled: NovelSessionComposerPolicy.canSubmit(
                        canSend: canSend,
                        text: inputText
                    ),
                    diameter: 54,
                    onSend: onSend,
                    onStop: onStop
                )
            }

            if showsMeta {
                NovelSessionComposerMetaControls(
                    values: meta,
                    isContextPanelPresented: $isContextPanelPresented,
                    onOpenModel: onOpenModel,
                    onArchiveDiscussion: onArchiveDiscussion,
                    onSetIntent: onSetIntent
                )
                .transition(
                    reduceMotion
                        ? .identity
                        : .move(edge: .top).combined(with: .opacity)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                colors: [AmberTheme.background.opacity(0.78), AmberTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86),
            value: showsMeta
        )
    }
}

private struct NovelSessionComposerMetaControls: View {
    let values: NovelSessionComposerMetaValues
    @Binding var isContextPanelPresented: Bool
    let onOpenModel: () -> Void
    let onArchiveDiscussion: () -> Void
    let onSetIntent: (NovelComposerIntent) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpenModel) {
                Text(values.modelLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .composerDockGlass(cornerRadius: 15)
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .selection))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .disabled(values.controlsDisabled)
            .accessibilityLabel("切换模型，当前 \(values.modelLabel)")

            Spacer(minLength: 0)

            Menu {
                Picker("创作方式", selection: Binding(
                    get: { values.currentIntent },
                    set: { intent in onSetIntent(intent) }
                )) {
                    Section("构思") {
                        ForEach(NovelComposerIntent.discussionOptions) { intent in
                            Text(intent.title).tag(intent)
                        }
                    }
                    Section("写正文") {
                        ForEach(NovelComposerIntent.proseOptions) { intent in
                            Text(intent.title)
                                .tag(intent)
                                .disabled(values.needsSync)
                        }
                    }
                }
                if values.needsSync {
                    Text("剧情同步完成后可写正文")
                }
                Divider()
                Button("归档当前讨论", systemImage: "archivebox") {
                    onArchiveDiscussion()
                }
                .disabled(
                    !values.hasArchivableDiscussion ||
                        values.needsSync || values.isBusy
                )
            } label: {
                Text(values.currentIntent.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .composerDockGlass(cornerRadius: 15)
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .selection))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .disabled(values.controlsDisabled)
            .accessibilityLabel("创作方式，当前 \(values.currentIntent.title)")

            ContextRingButton(
                snapshot: values.contextSnapshot,
                compactState: .idle,
                action: { isContextPanelPresented.toggle() }
            )
            .disabled(values.controlsDisabled)
            .popover(isPresented: $isContextPanelPresented, arrowEdge: .bottom) {
                ComposerContextPanel(
                    snapshot: values.contextSnapshot,
                    novelInjection: values.contextPanel
                )
                    .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}
