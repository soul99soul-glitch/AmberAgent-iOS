import SwiftUI
import UIKit

struct IOSInteractiveIshTerminalView: View {
    @Bindable var model: IOSInteractiveIshTerminalModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var keyboardIsActive = false
    @State private var dismissWhenStopped = false
    @State private var userIsScrolling = false
    @State private var viewportIsNearBottom = true
    @State private var followsOutput = true

    private let terminalBottomID = "interactive-ish-terminal-bottom"

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.029, blue: 0.035)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                terminalViewport
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputControls
        }
        .task {
            model.start()
        }
        .onChange(of: model.state) { _, state in
            if state == .starting {
                userIsScrolling = false
                viewportIsNearBottom = true
                followsOutput = true
            }
            if !state.acceptsInput {
                keyboardIsActive = false
            }
            if dismissWhenStopped, state.hasStopped {
                dismiss()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            keyboardIsActive = false
            model.stop()
        }
        .onDisappear {
            model.stop()
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: closeTerminal) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .foregroundStyle(Color.white.opacity(0.92))
                .accessibilityLabel("关闭交互终端")

                VStack(alignment: .leading, spacing: 2) {
                    Text("iSH 交互终端")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.white)
                    Text("ExperimentalGPL · 本机 /workspace")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                terminalAction
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                Text(stateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("\(model.terminalSize.columns) × \(model.terminalSize.rows)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.48))
                    .accessibilityLabel("终端大小，\(model.terminalSize.columns) 列，\(model.terminalSize.rows) 行")
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Color.white.opacity(0.055), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.black.opacity(0.28))
    }

    @ViewBuilder
    private var terminalAction: some View {
        switch model.state {
        case .starting, .running:
            Button {
                keyboardIsActive = false
                model.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.red.opacity(0.18), in: Circle())
            }
            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.38))
            .accessibilityLabel("停止 iSH 会话")
        case .stopping:
            ProgressView()
                .tint(Color.white.opacity(0.72))
                .frame(width: 44, height: 44)
                .accessibilityLabel("正在停止 iSH 会话")
        case .idle, .stopped, .exited, .failed:
            Button {
                model.start()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .accessibilityLabel("重新启动 iSH 会话")
        }
    }

    private var terminalViewport: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(visibleTerminalText)
                                .font(.system(.footnote, design: .monospaced))
                                .lineSpacing(2)
                                .foregroundStyle(Color(red: 0.80, green: 0.88, blue: 0.82))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(
                                    minWidth: max(0, geometry.size.width - 24),
                                    minHeight: max(0, geometry.size.height - 24),
                                    alignment: .topLeading
                                )
                                .accessibilityLabel("终端输出")
                                .accessibilityValue(terminalAccessibilityValue)

                            Color.clear
                                .frame(width: 1, height: 1)
                                .id(terminalBottomID)
                        }
                        .padding(12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        guard model.state.acceptsInput else { return }
                        keyboardIsActive = true
                    }
                    .onScrollPhaseChange { _, phase in
                        switch phase {
                        case .tracking, .interacting:
                            userIsScrolling = true
                            followsOutput = false
                        case .idle:
                            if userIsScrolling {
                                followsOutput = viewportIsNearBottom
                            }
                            userIsScrolling = false
                        case .animating, .decelerating:
                            break
                        @unknown default:
                            break
                        }
                    }
                    .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                        scrollGeometry.contentSize.height - scrollGeometry.visibleRect.maxY <= 20
                    } action: { _, isNearBottom in
                        viewportIsNearBottom = isNearBottom
                    }

                    if !followsOutput {
                        Button {
                            followsOutput = true
                            proxy.scrollTo(terminalBottomID, anchor: .bottom)
                        } label: {
                            Label("回到底部", systemImage: "arrow.down.to.line")
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                                .padding(.horizontal, 12)
                                .background(Color.black.opacity(0.78), in: Capsule())
                        }
                        .foregroundStyle(Color.white.opacity(0.92))
                        .padding(12)
                        .accessibilityLabel("恢复跟随终端输出")
                    }
                }
                .onAppear {
                    resizeTerminal(for: geometry.size)
                }
                .onChange(of: geometry.size) { _, size in
                    resizeTerminal(for: size)
                }
                .onChange(of: dynamicTypeSize) { _, _ in
                    resizeTerminal(for: geometry.size)
                }
                .onChange(of: model.screenGeneration) { _, _ in
                    guard followsOutput else { return }
                    proxy.scrollTo(terminalBottomID, anchor: .bottom)
                }
            }
        }
    }

    private var inputControls: some View {
        VStack(spacing: 8) {
            if let visibleError {
                Text(visibleError)
                    .font(.caption)
                    .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.44))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .accessibilityLabel("终端错误：\(visibleError)")
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    terminalKeyButton("Ctrl-C", accessibilityLabel: localized("发送 Ctrl-C")) {
                        model.interrupt()
                    }
                    terminalKeyButton("Tab", accessibilityLabel: localized("发送 Tab")) {
                        model.sendKey(.tab)
                    }
                    terminalKeyButton("Esc", accessibilityLabel: localized("发送 Escape")) {
                        model.sendKey(.escape)
                    }
                    terminalKeyButton("←", accessibilityLabel: localized("发送左方向键")) {
                        model.sendKey(.left)
                    }
                    terminalKeyButton("↑", accessibilityLabel: localized("发送上方向键")) {
                        model.sendKey(.up)
                    }
                    terminalKeyButton("↓", accessibilityLabel: localized("发送下方向键")) {
                        model.sendKey(.down)
                    }
                    terminalKeyButton("→", accessibilityLabel: localized("发送右方向键")) {
                        model.sendKey(.right)
                    }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.hidden)
            .disabled(!model.state.acceptsInput)

            HStack(spacing: 10) {
                IOSInteractiveTerminalKeyboardBridge(
                    isActive: $keyboardIsActive,
                    onText: model.sendText,
                    onKey: model.sendKey,
                    onInterrupt: model.interrupt
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)

                Text(keyboardIsActive ? "键盘输入已连接到 PTY" : "点击终端或按钮呼出键盘")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)

                Spacer(minLength: 8)

                Button {
                    keyboardIsActive.toggle()
                } label: {
                    Label(keyboardIsActive ? "收起" : "键盘", systemImage: "keyboard")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .padding(.horizontal, 13)
                        .background(Color.white.opacity(0.09), in: Capsule())
                }
                .foregroundStyle(Color.white.opacity(model.state.acceptsInput ? 0.92 : 0.35))
                .disabled(!model.state.acceptsInput)
                .accessibilityLabel(keyboardIsActive ? "收起终端键盘" : "打开终端键盘")
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private func terminalKeyButton(
        _ title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.monospaced().weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 7)
                .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(model.state.acceptsInput ? 0.88 : 0.32))
        .accessibilityLabel(accessibilityLabel)
    }

    private var visibleTerminalText: String {
        if !model.screenText.isEmpty {
            return model.screenText
        }
        switch model.state {
        case .starting:
            return localized("正在准备 iSH rootfs 与 /workspace…")
        case .stopping:
            return localized("正在停止 iSH 会话…")
        case .failed(let message):
            return "iSH 启动失败\n\(message)"
        case .idle, .running, .stopped, .exited:
            return " "
        }
    }

    private var visibleError: String? {
        if let inputError = model.inputError {
            return inputError
        }
        if case .failed(let message) = model.state {
            return message
        }
        return nil
    }

    private var terminalAccessibilityValue: String {
        let visibleRows = model.screenText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(min(model.terminalSize.rows, 30))
            .joined(separator: "\n")
        return String(visibleRows.suffix(2_000))
    }

    private var stateLabel: String {
        switch model.state {
        case .idle: return localized("准备启动")
        case .starting: return localized("正在启动")
        case .running: return localized("运行中 · 前台会话")
        case .stopping: return localized("正在停止")
        case .stopped: return localized("已停止")
        case .exited(let exitCode, let signal):
            let exitStatus = signal == 0 ? "code \(exitCode)" : "signal \(signal)"
            return "\(localized("已退出")) · \(exitStatus)"
        case .failed: return localized("会话失败")
        }
    }

    private func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }

    private var stateColor: Color {
        switch model.state {
        case .running: Color(red: 0.32, green: 0.84, blue: 0.56)
        case .starting, .stopping: Color(red: 1, green: 0.70, blue: 0.30)
        case .failed: Color(red: 1, green: 0.38, blue: 0.34)
        case .idle, .stopped, .exited: Color.white.opacity(0.40)
        }
    }

    private func resizeTerminal(for size: CGSize) {
        let preferredFont = UIFont.preferredFont(forTextStyle: .footnote)
        let terminalFont = UIFont.monospacedSystemFont(
            ofSize: preferredFont.pointSize,
            weight: .regular
        )
        let measuredCellWidth = ("M" as NSString).size(withAttributes: [.font: terminalFont]).width
        let measuredLineHeight = terminalFont.lineHeight + 2
        let columns = Int(max(0, size.width - 24) / max(measuredCellWidth, 1))
        let rows = Int(max(0, size.height - 24) / max(measuredLineHeight, 1))
        model.resize(rows: rows, columns: columns)
    }

    private func closeTerminal() {
        keyboardIsActive = false
        if model.state.hasStopped {
            dismiss()
        } else {
            dismissWhenStopped = true
            model.stop()
        }
    }
}

private struct IOSInteractiveTerminalKeyboardBridge: UIViewRepresentable {
    @Binding var isActive: Bool
    let onText: (String) -> Void
    let onKey: (IOSInteractiveIshTerminalKey) -> Void
    let onInterrupt: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> IOSInteractiveTerminalKeyInputView {
        let view = IOSInteractiveTerminalKeyInputView()
        view.onText = onText
        view.onKey = onKey
        view.onInterrupt = onInterrupt
        view.onFocusChange = context.coordinator.updateFocus
        return view
    }

    func updateUIView(_ view: IOSInteractiveTerminalKeyInputView, context: Context) {
        context.coordinator.parent = self
        view.onText = onText
        view.onKey = onKey
        view.onInterrupt = onInterrupt
        if isActive, !view.isFirstResponder {
            DispatchQueue.main.async {
                _ = view.becomeFirstResponder()
            }
        } else if !isActive, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: IOSInteractiveTerminalKeyInputView, coordinator: Coordinator) {
        _ = view.resignFirstResponder()
    }

    final class Coordinator {
        var parent: IOSInteractiveTerminalKeyboardBridge

        init(parent: IOSInteractiveTerminalKeyboardBridge) {
            self.parent = parent
        }

        @MainActor
        func updateFocus(_ isFocused: Bool) {
            guard parent.isActive != isFocused else { return }
            parent.isActive = isFocused
        }
    }
}

private final class IOSInteractiveTerminalKeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((IOSInteractiveIshTerminalKey) -> Void)?
    var onInterrupt: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    var hasText: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            onKey?(.enter)
        } else if text == "\t" {
            onKey?(.tab)
        } else {
            onText?(text)
        }
    }

    func deleteBackward() {
        onKey?(.backspace)
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onFocusChange?(true)
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(sendUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(sendDown)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(sendLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(sendRight)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(sendEscape)),
            UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(sendInterrupt)),
        ]
    }

    @objc private func sendUp() { onKey?(.up) }
    @objc private func sendDown() { onKey?(.down) }
    @objc private func sendLeft() { onKey?(.left) }
    @objc private func sendRight() { onKey?(.right) }
    @objc private func sendEscape() { onKey?(.escape) }
    @objc private func sendInterrupt() { onInterrupt?() }
}
