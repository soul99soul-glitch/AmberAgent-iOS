import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

struct ConversationSummaryRow: View, Equatable {
    let summary: ConversationSummary
    let isCurrent: Bool
    let isGenerating: Bool
    /// LLM 浓缩预览；空则 meta 只显示时间·条数（不交错）。
    let listPreview: String
    /// 标题 LLM 选出的图标 key；nil 则回退标题关键词 / 哈希。
    var listIconKey: String? = nil
    let slice: HomeCardSlice
    let hidesSeparator: Bool
    let onTap: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// 与 onRename 同理：只捕获 `summary.id` 与已参与比较的 `summary.title`。
    var onExport: (IOSConversationExportFormat) -> Void = { _ in }
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    /// true = 显示浓缩预览；false = 时间·条数。仅 isCurrent 且有 preview 时轮播。
    @State private var showingListPreview = false
    @State private var metaOpacity: Double = 1
    @State private var metaCycleTask: Task<Void, Never>?
    @ScaledMetric(relativeTo: .body) private var conversationTitleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var conversationMetadataSize: CGFloat = 11

    /// 供 `.equatable()` 用：只比较 body 实际读取、决定渲染结果的字段。
    /// `summary` 是 KMP `data class`（结构相等），但这里不比较整个对象——只挑 body 里
    /// 真正用到的四个字段（title/isPinned/messageCount/updateAt），忽略
    /// assistantId/createAt/memoryMode 等本行不读的字段，命中率更高。
    ///
    /// 闭包（onTap/onRename/onTogglePin/onDelete）故意不参与比较：
    /// - onTap/onDelete/onTogglePin 只捕获 `summary.id`（同一行 id 恒定不变）和
    ///   引用类型 owner（conversationStore/chatViewModel/router，@State 写入路径也是
    ///   共享存储，与具体是哪一份 self 快照无关），跟“这份闭包是不是本帧新建的”无关。
    /// - onRename 额外捕获 `summary.title` 写进 renameDraft；但 title 已经是本 == 的
    ///   比较字段之一——只要 title 变了这一行就判定不相等、body 会重新求值并换上带新
    ///   title 的闭包，所以点击时拿到的必然是当前 title，不存在“旧闭包捕获旧标题”的
    ///   过期风险，不需要额外改成点击时按 id 现查。
    nonisolated static func == (lhs: ConversationSummaryRow, rhs: ConversationSummaryRow) -> Bool {
        lhs.summary.id == rhs.summary.id
            && lhs.summary.title == rhs.summary.title
            && lhs.summary.isPinned == rhs.summary.isPinned
            && lhs.summary.messageCount == rhs.summary.messageCount
            && lhs.summary.updateAt == rhs.summary.updateAt
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isGenerating == rhs.isGenerating
            && lhs.listPreview == rhs.listPreview
            && lhs.listIconKey == rhs.listIconKey
            && lhs.slice == rhs.slice
            && lhs.hidesSeparator == rhs.hidesSeparator
    }

    var body: some View {
        let ambient = AmberTheme.cardShadowAmbientGeometry(for: colorScheme)
        Button(action: onTap) {
            HStack(spacing: 13) {
                iconView

                VStack(alignment: .leading, spacing: 7) {
                    Text(displayTitle)
                        .font(.system(size: conversationTitleSize, weight: .semibold))
                        .tracking(-0.08)
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(2)
                    metaLine
                        .opacity(metaOpacity)
                        .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 28 : 0)
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .frame(minHeight: 72)
            .padding(.leading, 17).padding(.trailing, 16)
            .background {
                // 卡面实色 +（纹理主题）卡内淡网格 + 当前行浅染。
                // 网格叠在实色上、选中晕之下，字仍坐在不透明面上，但 session 框内有方格/点阵感。
                let fill = ZStack {
                    HomeSliceShape(slice: slice).fill(AmberTheme.card)
                    HomeCardCanvasTexture()
                        .clipShape(HomeSliceShape(slice: slice))
                    HomeSliceShape(slice: slice)
                        .fill(isCurrent ? AmberTheme.activeCard : Color.clear)
                        .animation(homeCurrentBandMotion, value: isCurrent)
                }
                // 一体卡投影：仅 top/bottom/single 携带，middle 无影防接缝。
                switch slice {
                case .single:
                    fill
                        .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
                        .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
                case .bottom:
                    fill
                        .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
                        .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
                        .mask(
                            Rectangle()
                                .padding(.horizontal, -48)
                                .padding(.bottom, -48)
                                .padding(.top, 0)
                        )
                case .top:
                    fill
                        .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
                        .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
                        .mask(
                            Rectangle()
                                .padding(.horizontal, -48)
                                .padding(.top, -48)
                                .padding(.bottom, 0)
                        )
                case .middle:
                    fill
                }
            }
            .overlay {
                if pressed {
                    HomeSliceShape(slice: slice)
                        .fill(AmberTheme.press)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if !hidesSeparator {
                    // 卡内 hairline：略强于旧 sep token，仍左缩进对齐标题。
                    Rectangle()
                        .fill(AmberTheme.foreground.opacity(0.08))
                        .frame(height: max(1 / displayScale, 0.5))
                        .padding(.leading, 70)
                        .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomePressStateStyle(pressed: $pressed, scale: 0.98, scaleAnchor: .leading))
        .accessibilityLabel(accessibilityRowLabel)
        // 主操作:Apple Music 同款左右滑动(原生 List swipeActions，iOS 26 自带 Liquid Glass 渲染)。
        // 右滑→删除(整行划到底触发确认) / 重命名;左滑→置顶切换。删除只打开二次确认，真正删在 alert 确认后。
        // 故意不用 role: .destructive：List 会把它当“立即删除”先把行动画移走，数据还在时确认弹窗下就会闪一下又弹回。
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // 危险色靠显式 .tint(.red)；不用 role: .destructive（见上）。未设 tint 时会继承 AppShell 强调色。
            Button(action: onDelete) {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
            Button(action: onRename) {
                Label("重命名", systemImage: "pencil")
            }
            .tint(AmberTheme.muted2)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: onTogglePin) {
                Label(summary.isPinned ? "取消置顶" : "置顶",
                      systemImage: summary.isPinned ? "pin.slash" : "pin")
            }
            .tint(AmberTheme.muted2)
        }
        // 次操作:保留长按上下文菜单(与 Apple Music 一致，两种入口并存)。
        .contextMenu {
            Button {
                onTogglePin()
            } label: {
                Label(summary.isPinned ? "取消置顶" : "置顶",
                      systemImage: summary.isPinned ? "pin.slash" : "pin")
            }
            Button {
                onRename()
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Menu {
                ForEach(IOSConversationExportFormat.allCases) { format in
                    Button(format.title, systemImage: format.systemImage) {
                        onExport(format)
                    }
                }
            } label: {
                Label("导出对话", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .onAppear { restartMetaCycleIfNeeded() }
        .onChange(of: isCurrent) { _, _ in restartMetaCycleIfNeeded() }
        .onChange(of: listPreview) { _, _ in restartMetaCycleIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in restartMetaCycleIfNeeded() }
        .onDisappear {
            metaCycleTask?.cancel()
            metaCycleTask = nil
        }
    }

    private var accessibilityRowLabel: String {
        var label = IOSAppLocalization.formatted(
            "会话 %@，%@ 条消息",
            defaultValue: "会话 %@，%@ 条消息",
            arguments: [displayTitle, String(summary.messageCount)]
        )
        if summary.isPinned {
            label += "，" + IOSAppLocalization.string("已置顶", defaultValue: "已置顶")
        }
        if isGenerating {
            label += "，" + IOSAppLocalization.string("正在生成", defaultValue: "正在生成")
        }
        // 不跟 4.2s 轮播抢读：有浓缩预览时固定附带一句，避免动态切换。
        if isCurrent, !listPreview.isEmpty { label += "，\(listPreview)" }
        return label
    }

    @ViewBuilder
    private var metaLine: some View {
        if showingListPreview, !listPreview.isEmpty, isCurrent {
            Text(listPreview)
                .font(.system(size: conversationMetadataSize, weight: .regular))
                .tracking(0.11)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                Text(relativeTime)
                    .font(.system(size: conversationMetadataSize, weight: .regular)).tracking(0.11)
                    .foregroundStyle(AmberTheme.muted)
                Text("·")
                    .font(.system(size: conversationMetadataSize, weight: .regular))
                    .foregroundStyle(AmberTheme.muted2)
                Text(
                    IOSAppLocalization.formatted(
                        "%d 条",
                        defaultValue: "%d 条",
                        arguments: [Int32(summary.messageCount)]
                    )
                )
                    .font(.system(size: conversationMetadataSize, weight: .regular)).tracking(0.11)
                    .foregroundStyle(AmberTheme.muted)
            }
            .monospacedDigit()
        }
    }

    /// 当前行色带 / 头像色切换：短 ease，不 spring。
    private var homeCurrentBandMotion: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    private var iconView: some View {
        ZStack {
            Circle()
                .fill(isCurrent ? AmberTheme.avatarActive : AmberTheme.avatarIdle)
                .animation(homeCurrentBandMotion, value: isCurrent)
            if summary.isPinned {
                HomePhosphorIcon(.pushPin, size: 20)
                    .foregroundStyle(isCurrent ? AmberTheme.avatarActiveInk : AmberTheme.avatarIdleInk)
                    .animation(homeCurrentBandMotion, value: isCurrent)
            } else {
                HomePhosphorIcon(
                    HomeConversationIcon.icon(
                        forTitle: displayTitle,
                        isPinned: false,
                        preferredKey: listIconKey
                    ),
                    size: 20
                )
                    .foregroundStyle(isCurrent ? AmberTheme.avatarActiveInk : AmberTheme.avatarIdleInk)
                    .animation(homeCurrentBandMotion, value: isCurrent)
                    .animation(homeCurrentBandMotion, value: listIconKey)
            }
            if isGenerating {
                ConversationGeneratingRing()
            }
        }
        .frame(width: 40, height: 40)
        // 光晕在 background 且自裁 64pt：余光可见，仍尽量少渗邻行。
        .background {
            if isCurrent {
                CurrentConversationAvatarGlow()
                    .frame(
                        width: HomeCurrentAvatarBreath.clipSize,
                        height: HomeCurrentAvatarBreath.clipSize
                    )
                    .clipped()
            }
        }
    }

    /// 空标题统一走「新对话」占位语义：行文本、搜索匹配与图标映射同一输入。
    private var displayTitle: String {
        summary.title.isEmpty
            ? IOSAppLocalization.string("新对话", defaultValue: "新对话")
            : summary.title
    }

    /// 相对时间：updateAt -> "刚刚 / N分钟前 / N小时前 / 昨天 / M月D日"。
    private var relativeTime: String {
        let ms = summary.updateAt.toEpochMilliseconds()
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// E 版 meta 淡切：~4.2s 一轮，0.4s 淡出换文；仅当前会话且有浓缩预览时启用。
    private func restartMetaCycleIfNeeded() {
        metaCycleTask?.cancel()
        metaCycleTask = nil
        showingListPreview = false
        metaOpacity = 1
        guard isCurrent, !listPreview.isEmpty, !reduceMotion else { return }
        metaCycleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_200_000_000)
                guard !Task.isCancelled else { return }
                // 与 E 版 `.hm-m` 0.4s ease 淡切对齐
                withAnimation(.easeInOut(duration: 0.4)) { metaOpacity = 0 }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                showingListPreview.toggle()
                withAnimation(.easeInOut(duration: 0.4)) { metaOpacity = 1 }
            }
        }
    }
}

private struct ConversationGeneratingRing: View {
    @State private var isRotating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            ring.rotationEffect(.degrees(-90))
        } else {
            ring
                .rotationEffect(.degrees(isRotating ? 270 : -90))
                .animation(
                    .linear(duration: 0.9).repeatForever(autoreverses: false),
                    value: isRotating
                )
                .onAppear { isRotating = true }
                .onDisappear {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isRotating = false }
                }
        }
    }

    private var ring: some View {
        Circle()
            .trim(from: 0.0, to: 0.78)
            .stroke(
                AmberTheme.foreground2,
                style: StrokeStyle(lineWidth: 1.05, lineCap: .round)
            )
            .accessibilityHidden(true)
    }
}

/// E 版原型 `hm-breathe`：当前会话头像光晕呼吸（已压低，避免 accent 下过曝）。
/// 时序仍 1.6s delay / 3.4s period；视觉只做轻余光。
enum HomeCurrentAvatarBreath {
    static let delaySeconds: TimeInterval = 1.6
    static let periodSeconds: TimeInterval = 3.4
    static let blurRadius: CGFloat = 5
    /// 相对 40pt 头像外扩（收紧，少渗邻行）。
    static let spread: CGFloat = 2
    static let clipSize: CGFloat = 52
    /// 峰值再压一层，强度曲线仍 0…1。
    static let peakOpacity: Double = 0.55

    /// Core Animation 按同一余弦曲线采样，避免 SwiftUI 每帧重算模糊视图。
    static let opacityKeyframes: [NSNumber] = (0...60).map { index in
        let elapsed = delaySeconds + Double(index) / 60 * periodSeconds
        return NSNumber(value: intensity(elapsed: elapsed, reduceMotion: false) * peakOpacity)
    }
    static let opacityKeyTimes: [NSNumber] = (0...60).map { NSNumber(value: Double($0) / 60) }

    /// 0…1。Reduce Motion 时恒为 0。
    static func intensity(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0 }
        guard elapsed >= delaySeconds else { return 0 }
        let phase = ((elapsed - delaySeconds) / periodSeconds)
            .truncatingRemainder(dividingBy: 1)
        return 0.5 - 0.5 * cos(phase * 2 * .pi)
    }
}

/// 仅挂在 `isCurrent` 会话头像后：轻量外溢光晕，不参与布局命中。
private struct CurrentConversationAvatarGlow: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 显式观察主题输入；UIColor 动态颜色闭包本身不会触发 SwiftUI Observation。
        let accentHex = AmberThemeRuntime.shared.accentHex
        let paper = AmberThemeRuntime.shared.paper
        AvatarGlowOpacityHost(
            start: start,
            reduceMotion: reduceMotion,
            accentHex: accentHex,
            paper: paper
        ) {
            let diameter = 40 + HomeCurrentAvatarBreath.spread * 2
            // 单环 soft blur，去掉双层叠晕（叠晕在 accent 下易过曝）。
            Circle()
                .fill(AmberTheme.activeAvatarGlow)
                .frame(width: diameter, height: diameter)
                .blur(radius: HomeCurrentAvatarBreath.blurRadius)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 用宿主 layer 驱动静态光晕的透明度，保留 SwiftUI 主题颜色和模糊效果。
private struct AvatarGlowOpacityHost<Content: View>: UIViewControllerRepresentable {
    let start: Date
    let reduceMotion: Bool
    let accentHex: UInt32
    let paper: AmberThemeRuntime.Paper
    let content: Content

    init(
        start: Date,
        reduceMotion: Bool,
        accentHex: UInt32,
        paper: AmberThemeRuntime.Paper,
        @ViewBuilder content: () -> Content
    ) {
        self.start = start
        self.reduceMotion = reduceMotion
        self.accentHex = accentHex
        self.paper = paper
        self.content = content()
    }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        updateOpacityAnimation(on: controller.view.layer)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content
        updateOpacityAnimation(on: controller.view.layer)
    }

    static func dismantleUIViewController(_ controller: UIHostingController<Content>, coordinator: ()) {
        controller.view.layer.removeAnimation(forKey: "homeAvatarGlowBreath")
    }

    private func updateOpacityAnimation(on layer: CALayer) {
        layer.removeAnimation(forKey: "homeAvatarGlowBreath")
        layer.opacity = 0
        guard !reduceMotion else { return }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = HomeCurrentAvatarBreath.opacityKeyframes
        animation.keyTimes = HomeCurrentAvatarBreath.opacityKeyTimes
        animation.calculationMode = .linear
        animation.duration = HomeCurrentAvatarBreath.periodSeconds
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            + HomeCurrentAvatarBreath.delaySeconds
            - Date().timeIntervalSince(start)
        animation.repeatCount = .infinity
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "homeAvatarGlowBreath")
    }
}
