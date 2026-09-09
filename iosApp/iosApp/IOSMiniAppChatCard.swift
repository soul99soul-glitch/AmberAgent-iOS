import Shared
import SwiftUI
import UIKit

/// Incremental presentation state for a live MiniApp payload.
///
/// The message still owns the complete raw payload. This state keeps that
/// payload to distinguish an append from a replacement and to preserve the
/// bare-HTML fallback, while the JSON decoder consumes just the new suffix.
/// The decoded source is kept
/// intact for the presentation window's count and tail; only the returned text
/// is capped at `ChatTextWindow.limit`.
struct IOSMiniAppStreamingCodePreviewState {
    private enum ScanState {
        case searchingHTMLKey
        case waitingForHTMLValue
        case readingHTMLValue
        case finishedHTMLValue
    }

    private enum EscapeState {
        case normal
        case escaped
        case unicode
    }

    private static let htmlKey = Array("\"html\"")
    private static let bareHTMLOverlapLength = 13
    private static let doctypeMarker = "<!DOCTYPE html"
    private static let htmlMarker = "<html"

    private var rawSource = ""
    private var rawSourceUTF8Count = 0
    private var rawCharacterCount = 0
    private var rawSearchTail = ""
    private var rawHTMLStartCharacter: Int?
    private var bareHTMLSource = ""
    private var scanState: ScanState = .searchingHTMLKey
    private var htmlKeyProgress = 0
    private var escapeState: EscapeState = .normal
    private var unicodeDigits = ""
    private var pendingHighSurrogate: UInt16?
    private var decodedHTML = ""
    private var decodedCharacterCount = 0
    private(set) var displayText = ""

    init(_ source: String = "") {
        update(source)
    }

    private static func characterCountAfterAppending(
        _ delta: String,
        to source: String,
        currentCount: Int
    ) -> Int {
        guard !delta.isEmpty else { return currentCount }
        guard let last = source.last else {
            return currentCount + delta.count
        }
        // Recount the boundary grapheme. A streamed chunk can begin with a
        // combining mark or joiner that extends the preceding Character.
        return currentCount + (String(last) + delta).count - 1
    }

    /// Consumes a new cumulative payload. The single prefix check is needed
    /// because the current message API supplies snapshots rather than deltas;
    /// decoding itself remains incremental for ordinary streaming appends.
    @discardableResult
    mutating func update(_ next: String) -> Bool {
        if next == rawSource {
            refreshDisplay()
            return false
        }

        let isAppend = !rawSource.isEmpty && next.utf8.starts(with: rawSource.utf8)
        let delta: String
        let rawCharacterCountBeforeDelta: Int
        if isAppend {
            delta = String(decoding: next.utf8.dropFirst(rawSourceUTF8Count), as: UTF8.self)
            rawCharacterCountBeforeDelta = rawCharacterCount
            rawCharacterCount = Self.characterCountAfterAppending(
                delta,
                to: rawSource,
                currentCount: rawCharacterCount
            )
            rawSourceUTF8Count += delta.utf8.count
        } else {
            resetDecoder()
            delta = next
            rawCharacterCountBeforeDelta = 0
            rawCharacterCount = next.count
            rawSourceUTF8Count = next.utf8.count
        }

        consume(delta)
        rawSource = next
        scanBareHTML(in: delta, absoluteStart: rawCharacterCountBeforeDelta)
        refreshDisplay()
        return isAppend
    }

    /// Flushes an incomplete final escape/surrogate when a live response ends.
    /// Valid streams do not need this, but it prevents the last malformed piece
    /// from disappearing if a provider stops immediately after `\\u12`.
    mutating func finish() {
        guard scanState == .readingHTMLValue else {
            refreshDisplay()
            return
        }
        var suffix = ""
        flushIncompleteValue(into: &suffix)
        appendDecoded(suffix)
        refreshDisplay()
    }

    private mutating func resetDecoder() {
        scanState = .searchingHTMLKey
        htmlKeyProgress = 0
        escapeState = .normal
        unicodeDigits.removeAll(keepingCapacity: true)
        pendingHighSurrogate = nil
        rawSearchTail.removeAll(keepingCapacity: true)
        rawHTMLStartCharacter = nil
        bareHTMLSource.removeAll(keepingCapacity: true)
        decodedHTML.removeAll(keepingCapacity: true)
        decodedCharacterCount = 0
    }

    private mutating func scanBareHTML(in delta: String, absoluteStart: Int) {
        guard decodedHTML.isEmpty else { return }
        guard rawHTMLStartCharacter == nil else {
            bareHTMLSource.append(contentsOf: delta)
            return
        }

        let candidatePrefix = rawSearchTail
        let candidate = candidatePrefix + delta
        guard let marker = candidate.range(of: Self.doctypeMarker, options: .caseInsensitive)
            ?? candidate.range(of: Self.htmlMarker, options: .caseInsensitive) else {
            rawSearchTail = String(candidate.suffix(Self.bareHTMLOverlapLength))
            return
        }

        let markerOffset = candidate.distance(from: candidate.startIndex, to: marker.lowerBound)
        let start = max(0, absoluteStart - candidatePrefix.count + markerOffset)
        rawHTMLStartCharacter = start
        bareHTMLSource = String(rawSource.dropFirst(start))
        rawSearchTail.removeAll(keepingCapacity: true)
    }

    private mutating func consume(_ delta: String) {
        guard !delta.isEmpty else { return }
        var decodedDelta = ""
        decodedDelta.reserveCapacity(min(delta.utf8.count, 16_384))
        for character in delta {
            consume(character, into: &decodedDelta)
        }
        appendDecoded(decodedDelta)
    }

    private mutating func consume(_ character: Character, into output: inout String) {
        var current: Character? = character
        while let character = current {
            current = nil
            switch scanState {
            case .searchingHTMLKey:
                if character == Self.htmlKey[htmlKeyProgress] {
                    htmlKeyProgress += 1
                    if htmlKeyProgress == Self.htmlKey.count {
                        htmlKeyProgress = 0
                        scanState = .waitingForHTMLValue
                    }
                } else {
                    htmlKeyProgress = character == Self.htmlKey[0] ? 1 : 0
                }

            case .waitingForHTMLValue:
                if character.isWhitespace || character == ":" {
                    continue
                }
                if character == "\"" {
                    scanState = .readingHTMLValue
                    escapeState = .normal
                    continue
                }
                // The first occurrence may have been text inside another
                // string. Resume the same cheap key scan instead of getting
                // stuck and missing a later real HTML field.
                scanState = .searchingHTMLKey
                htmlKeyProgress = character == Self.htmlKey[0] ? 1 : 0

            case .readingHTMLValue:
                consumeHTMLValueCharacter(character, into: &output, reprocess: &current)

            case .finishedHTMLValue:
                return
            }
        }
    }

    private mutating func consumeHTMLValueCharacter(
        _ character: Character,
        into output: inout String,
        reprocess: inout Character?
    ) {
        switch escapeState {
        case .normal:
            if character == "\\" {
                escapeState = .escaped
            } else if character == "\"" {
                flushPendingSurrogate(into: &output)
                scanState = .finishedHTMLValue
            } else {
                flushPendingSurrogate(into: &output)
                output.append(character)
            }

        case .escaped:
            switch character {
            case "n":
                flushPendingSurrogate(into: &output)
                output.append("\n")
            case "r":
                flushPendingSurrogate(into: &output)
                output.append("\r")
            case "t":
                flushPendingSurrogate(into: &output)
                output.append("\t")
            case "b":
                flushPendingSurrogate(into: &output)
                output.append("\u{8}")
            case "f":
                flushPendingSurrogate(into: &output)
                output.append("\u{c}")
            case "\"", "\\", "/":
                flushPendingSurrogate(into: &output)
                output.append(character)
            case "u":
                unicodeDigits.removeAll(keepingCapacity: true)
                escapeState = .unicode
                return
            default:
                // Preserve the historical streaming behavior for an unknown
                // escape: the slash is syntax and the character is content.
                flushPendingSurrogate(into: &output)
                output.append(character)
            }
            escapeState = .normal

        case .unicode:
            guard let scalar = character.unicodeScalars.first,
                  scalar.value <= 0x7F,
                  String(character).count == 1,
                  "0123456789abcdefABCDEF".contains(character) else {
                output.append("\\u")
                output.append(contentsOf: unicodeDigits)
                unicodeDigits.removeAll(keepingCapacity: true)
                escapeState = .normal
                reprocess = character
                return
            }
            unicodeDigits.append(character)
            guard unicodeDigits.count == 4 else { return }
            let codeUnit = UInt16(unicodeDigits, radix: 16) ?? 0xFFFD
            unicodeDigits.removeAll(keepingCapacity: true)
            escapeState = .normal
            appendUnicodeCodeUnit(codeUnit, into: &output)
        }
    }

    private mutating func appendUnicodeCodeUnit(_ codeUnit: UInt16, into output: inout String) {
        if let high = pendingHighSurrogate {
            if (0xDC00...0xDFFF).contains(codeUnit) {
                let scalar = 0x10000 +
                    ((UInt32(high) - 0xD800) << 10) +
                    (UInt32(codeUnit) - 0xDC00)
                output.append(Character(UnicodeScalar(scalar)!))
                pendingHighSurrogate = nil
                return
            }
            output.append("\u{FFFD}")
            pendingHighSurrogate = nil
        }

        if (0xD800...0xDBFF).contains(codeUnit) {
            pendingHighSurrogate = codeUnit
        } else if (0xDC00...0xDFFF).contains(codeUnit) {
            output.append("\u{FFFD}")
        } else {
            output.append(Character(UnicodeScalar(codeUnit)!))
        }
    }

    private mutating func flushPendingSurrogate(into output: inout String) {
        guard pendingHighSurrogate != nil else { return }
        output.append("\u{FFFD}")
        pendingHighSurrogate = nil
    }

    private mutating func flushIncompleteValue(into output: inout String) {
        switch escapeState {
        case .normal:
            break
        case .escaped:
            output.append("\\")
        case .unicode:
            output.append("\\u")
            output.append(contentsOf: unicodeDigits)
        }
        unicodeDigits.removeAll(keepingCapacity: true)
        escapeState = .normal
        flushPendingSurrogate(into: &output)
    }

    private mutating func appendDecoded(_ text: String) {
        guard !text.isEmpty else { return }
        decodedCharacterCount = Self.characterCountAfterAppending(
            text,
            to: decodedHTML,
            currentCount: decodedCharacterCount
        )
        decodedHTML.append(contentsOf: text)
    }

    private mutating func refreshDisplay() {
        let source: String
        let count: Int
        if !decodedHTML.isEmpty {
            source = decodedHTML
            count = decodedCharacterCount
        } else if let start = rawHTMLStartCharacter {
            source = bareHTMLSource
            count = rawCharacterCount - start
        } else {
            source = rawSource
            count = rawCharacterCount
        }
        let tail = String(source.suffix(ChatTextWindow.limit))
        guard count > ChatTextWindow.limit else {
            displayText = tail
            return
        }
        let notice = IOSAppLocalization.formatted(
            "已省略 %lld 字",
            defaultValue: "已省略 %lld 字",
            arguments: [Int64(count - ChatTextWindow.limit)]
        )
        displayText = notice + "\n" + tail
    }
}

/// Streaming MiniApp payload card: image-gen-like surface by default, tap to
/// watch frontend/code stream, tap again to collapse. Replaces flat markdown
/// while the model is emitting MiniApp JSON/HTML.
struct ChatMiniAppStreamingCard: View {
    let text: String
    var isGenerating: Bool = true

    @State private var showCode = false
    @State private var previewState = IOSMiniAppStreamingCodePreviewState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasCode: Bool {
        text.contains { !$0.isWhitespace }
    }

    private var title: String {
        let key: String
        if isGenerating {
            key = showCode ? "正在生成前端代码" : "正在生成小应用"
        } else {
            key = showCode ? "小应用代码" : "小应用"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }

    private var displayCode: String {
        previewState.displayText
    }

    var body: some View {
        // One shell both modes: whole card toggles. Use simultaneousGesture so
        // ScrollView drags still work; a discrete tap flips preview ↔ code.
        cardShell {
            headerRow
            if showCode {
                codeBody
            } else {
                previewBody
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(toggleMode))
        .modifier(ChatGeneratedImageAppearModifier())
        .accessibilityElement(children: showCode ? .contain : .combine)
        .accessibilityLabel(title)
        .accessibilityValue(IOSAppLocalization.string(
            showCode ? "代码模式" : "预览模式",
            defaultValue: showCode ? "代码模式" : "预览模式"
        ))
        .accessibilityHint(IOSAppLocalization.string(
            "点按切换预览与代码",
            defaultValue: "点按切换预览与代码"
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(IOSAppLocalization.string(
            showCode ? "显示预览" : "显示代码",
            defaultValue: showCode ? "显示预览" : "显示代码"
        )), toggleMode)
        .onAppear {
            previewState.update(text)
            if !isGenerating { previewState.finish() }
        }
        .onChange(of: text) { _, newValue in
            previewState.update(newValue)
        }
        .onChange(of: isGenerating) { _, generating in
            if !generating { previewState.finish() }
        }
    }

    private func cardShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            ChatUIKitVariableColorSymbol(
                systemName: showCode ? "chevron.left.forwardslash.chevron.right" : "sparkles",
                pointSize: 12.5,
                weight: .semibold,
                tint: UIColor(AmberTheme.accent),
                isActive: isGenerating && !reduceMotion
            )

            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(1)

            Spacer(minLength: 6)

            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AmberTheme.muted)
                .rotationEffect(.degrees(showCode ? 180 : 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleMode() {
        guard hasCode || isGenerating else { return }
        if reduceMotion {
            showCode.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                showCode.toggle()
            }
        }
    }

    private var previewBody: some View {
        // Pure image-gen surface — no mid-card copy overlay.
        ChatGeneratedImageDotPlaceholder(
            aspectRatio: 16.0 / 10.0,
            cornerRadius: 12,
            showsChrome: false,
            isAnimating: isGenerating
        )
        .frame(maxWidth: .infinity)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .accessibilityHidden(true)
    }

    private var codeBody: some View {
        let code = displayCode
        return ScrollViewReader { proxy in
            ScrollView {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // No textSelection: it steals the card-level tap that
                    // collapses code → preview. Final MiniApp card can export.
                    .id("miniapp-code-bottom")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .padding(10)
            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            // Streaming: disable selection so parent card tap can collapse.
            // (Selection while generating fights the toggle gesture.)
            .onChange(of: code) { _, _ in
                guard isGenerating else { return }
                if reduceMotion {
                    proxy.scrollTo("miniapp-code-bottom", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("miniapp-code-bottom", anchor: .bottom)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo("miniapp-code-bottom", anchor: .bottom)
            }
        }
        .mask(codeFadeMask)
        .accessibilityLabel(IOSAppLocalization.string("小应用代码", defaultValue: "小应用代码"))
    }

    private var codeFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
        }
    }

    /// Prefer decoded `"html"` field while JSON is streaming; fall back to a bare HTML
    /// document if present; otherwise show the full payload so partial output still paints.
    static func codePreview(from text: String) -> String {
        var state = IOSMiniAppStreamingCodePreviewState(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        state.finish()
        return state.displayText
    }
}

/// Chat-inline MiniApp card: run / modify / export / versions.
struct IOSMiniAppChatCard: View {
    @Environment(\.chatMessageEditingAllowed) private var messageEditingAllowed
    let part: UIMessagePart.MiniApp
    var onRun: () -> Void = {}
    var onOpenList: () -> Void = {}
    /// Returns false when the modify request was rejected (e.g. generation already active).
    var onModify: (String) -> Bool = { _ in true }

    @State private var showModifySheet = false
    @State private var modifyPrompt = ""
    @State private var modifyBusyRejected = false
    @State private var exportShare: MiniAppExportShare?
    @State private var exportError: MiniAppExportError?
    @State private var showVersionHistory = false
    @State private var versions: [IOSMiniAppVersionRecord] = []
    @State private var cardTitle: String = ""
    @State private var cardVersion: Int = 1
    @State private var repository = IOSMiniAppRepository.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(part.iconEmoji?.nilIfBlank ?? "▣")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(2)
                    Text(verbatim: IOSAppLocalization.formatted(
                        "v%lld · %@",
                        defaultValue: "v%lld · %@",
                        arguments: [
                            Int64(displayVersion),
                            categoryLabel(part.category?.nilIfBlank ?? "tool"),
                        ]
                    ))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Top-align with title line; 44pt hit box without centering on the icon.
                Button(action: onOpenList) {
                    Text(IOSAppLocalization.string("全部", defaultValue: "全部"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
                .padding(.top, 1)
                .accessibilityLabel(IOSAppLocalization.string("全部小应用", defaultValue: "全部小应用"))
            }

            if !part.description_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(part.description_)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Equal-width capsules edge-to-edge (生图 action row density).
            actionButtonsRow
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AmberTheme.border.opacity(0.7), lineWidth: 1)
        )
        .task(id: "\(part.appId):\(repository.revision)") {
            refreshHeaderFromRepository()
        }
        .sheet(isPresented: $showModifySheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(IOSAppLocalization.string("描述你想改的地方", defaultValue: "描述你想改的地方"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    TextEditor(text: $modifyPrompt)
                        .frame(minHeight: 140)
                        .padding(10)
                        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(IOSAppLocalization.string(
                            "小应用修改说明",
                            defaultValue: "小应用修改说明"
                        ))
                        .accessibilityHint(IOSAppLocalization.string(
                            "描述希望修改的内容",
                            defaultValue: "描述希望修改的内容"
                        ))
                    if modifyBusyRejected {
                        Text(IOSAppLocalization.string(
                            "当前正在生成回复，请稍后再修改。",
                            defaultValue: "当前正在生成回复，请稍后再修改。"
                        ))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.accentAmber)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .navigationTitle(IOSAppLocalization.string("修改小应用", defaultValue: "修改小应用"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(IOSAppLocalization.string("取消", defaultValue: "取消")) {
                            showModifySheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(IOSAppLocalization.string("发送", defaultValue: "发送")) {
                            let prompt = modifyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !prompt.isEmpty else { return }
                            let accepted = onModify(
                                IOSMiniAppChatMessageFactory.revisionPrompt(
                                    appId: part.appId,
                                    title: displayTitle,
                                    version: displayVersion,
                                    request: prompt
                                )
                            )
                            if accepted {
                                showModifySheet = false
                            } else {
                                modifyBusyRejected = true
                            }
                        }
                        .disabled(modifyPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVersionHistory) {
            NavigationStack {
                Group {
                    if versions.isEmpty {
                        ContentUnavailableView(
                            IOSAppLocalization.string("暂无历史版本", defaultValue: "暂无历史版本"),
                            systemImage: "clock",
                            description: Text(IOSAppLocalization.string(
                                "保存或修改小应用后会出现版本记录",
                                defaultValue: "保存或修改小应用后会出现版本记录"
                            ))
                        )
                    } else {
                        List {
                            ForEach(versions) { version in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("v\(version.versionNumber)")
                                            .font(.subheadline.weight(.semibold))
                                        if version.versionNumber == displayVersion {
                                            Text(IOSAppLocalization.string("当前", defaultValue: "当前"))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(AmberTheme.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(AmberTheme.accentTint, in: Capsule())
                                        }
                                        Spacer()
                                        Text(Self.formatDate(version.createdAt))
                                            .font(.caption)
                                            .foregroundStyle(AmberTheme.muted)
                                    }
                                    Text(version.changeNote ?? IOSAppLocalization.string(
                                        "小应用版本",
                                        defaultValue: "小应用版本"
                                    ))
                                        .font(.caption)
                                        .foregroundStyle(AmberTheme.muted)
                                        .lineLimit(3)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .background(AmberTheme.background)
                        .listStyle(.insetGrouped)
                    }
                }
                .navigationTitle(IOSAppLocalization.string("版本历史", defaultValue: "版本历史"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(IOSAppLocalization.string("完成", defaultValue: "完成")) {
                            showVersionHistory = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $exportShare) { share in
            MiniAppActivityShareSheet(items: [share.url])
        }
        .alert(item: $exportError) { error in
            Alert(
                title: Text(IOSAppLocalization.string("无法导出小应用", defaultValue: "无法导出小应用")),
                message: Text(error.message),
                dismissButton: .default(Text(IOSAppLocalization.string("知道了", defaultValue: "知道了")))
            )
        }
    }

    private var displayTitle: String {
        let trimmed = cardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? part.title : trimmed
    }

    private var displayVersion: Int {
        max(cardVersion, Int(part.version))
    }

    private func categoryLabel(_ raw: String) -> String {
        let key: String?
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tool": key = "工具"
        case "game": key = "游戏"
        case "info": key = "信息"
        case "custom": key = "自定义"
        default: key = nil
        }
        guard let key else {
            return raw.isEmpty
                ? IOSAppLocalization.string("小应用", defaultValue: "小应用")
                : raw
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }

    /// Visual capsule height matches chat image actions (~28–30), not chunky
    /// `.bordered` system controls. Four equal columns span the card content width.
    private var actionButtonsRow: some View {
        HStack(spacing: 8) {
            miniAppActionButton(
                title: "运行",
                systemImage: "play.fill",
                emphasized: true,
                action: onRun
            )
            miniAppActionButton(title: "修改", systemImage: "pencil", emphasized: false) {
                modifyBusyRejected = false
                modifyPrompt = ""
                showModifySheet = true
            }
            .disabled(!messageEditingAllowed)
            miniAppActionButton(
                title: "导出",
                systemImage: "square.and.arrow.up",
                emphasized: false,
                action: exportHTML
            )
            miniAppActionButton(title: "历史", systemImage: "clock.arrow.circlepath", emphasized: false) {
                versions = repository.versions(appId: part.appId)
                showVersionHistory = true
            }
        }
    }

    private func miniAppActionButton(
        title: String,
        systemImage: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let localizedTitle = IOSAppLocalization.string(title, defaultValue: title)
        return Button(action: action) {
            Label {
                Text(localizedTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(emphasized ? AmberTheme.accent : AmberTheme.foreground2)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                emphasized ? AmberTheme.accentTint : AmberTheme.surface2,
                in: Capsule()
            )
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .selection))
        // Visual capsule stays ~30; expand hit area without restyling.
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(localizedTitle)
    }

    private func refreshHeaderFromRepository() {
        guard let record = repository.get(part.appId) else {
            cardTitle = part.title
            cardVersion = Int(part.version)
            return
        }
        cardTitle = record.title
        cardVersion = record.version
    }

    private func exportHTML() {
        guard let record = repository.get(part.appId) else {
            exportError = MiniAppExportError(message: IOSAppLocalization.string(
                "找不到这个小应用的已保存内容。",
                defaultValue: "找不到这个小应用的已保存内容。"
            ))
            return
        }
        let safeName = record.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "\(safeName.isEmpty ? "miniapp" : safeName)-v\(record.version).html"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try record.htmlContent.write(to: url, atomically: true, encoding: .utf8)
            exportShare = MiniAppExportShare(url: url)
        } catch {
            exportError = MiniAppExportError(message: IOSAppLocalization.formatted(
                "无法写入导出文件：%@",
                defaultValue: "无法写入导出文件：%@",
                arguments: [error.localizedDescription]
            ))
        }
    }

    private static func formatDate(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            .formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened)
                    .locale(IOSAppLanguagePreference.selected().resolvedLocale())
            )
    }
}

private struct MiniAppExportShare: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MiniAppExportError: Identifiable {
    let id = UUID()
    let message: String
}

private struct MiniAppActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
