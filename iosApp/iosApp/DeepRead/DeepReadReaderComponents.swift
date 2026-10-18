import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
@preconcurrency import WebKit
#endif
@preconcurrency import Network
@preconcurrency import Shared
// MARK: - 详情页:生成中骨架 + 玻璃操作胶囊

/// 生成过渡态:不是一块呆板的灰条,而是「一篇正在排版的杂志稿」的骨架 ——
/// 报头标题 + 副标题 + 细分隔线 + 正文段落块 + 小节标题,配柔和脉冲,
/// 让等待阶段也保有阅读器的精致感。
// 杂志结构骨架屏:铺在实色阅读面上(非玻璃卡片)。deck 行 + 进度行(spinner + 衬线标签
// + 「排版中」meta)+ 导读 / 左竖线 pullquote / 要点 / 双栏。dimmed = 失败态(降透明、spinner 停)。
// 死代码：生成中页面已改用 IOSDeepReadNewsroomView，此骨架不再被引用；确认后可删除。
private struct DeepReadMagazineSkeleton: View {
    var dimmed: Bool = false
    var progressLabel: String? = nil
    @State private var pulse = false

    private var stageText: String {
        let label = progressLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.localizedProgressLabel(label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 进度行(置顶 —— 生成态唯一状态指示,紧贴标题下方)
            if !dimmed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(AmberTheme.accent)
                    Text(stageText)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text("排版中")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(AmberTheme.muted2)
                }
            }

            // deck(导语)
            bar(0.9, 14).padding(.top, 18)
            bar(0.6, 14).padding(.top, 9)

            Rectangle()
                .fill(AmberTheme.surface2)
                .frame(height: 1)
                .opacity(0.85)
                .padding(.top, 16)

            // 导读
            paragraph([1.0, 1.0, 1.0, 0.62]).padding(.top, 18)

            // 左竖线 pullquote
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(AmberTheme.accent)
                    .frame(width: 2)
                    .opacity(0.55)
                VStack(alignment: .leading, spacing: 10) {
                    bar(0.92, 13)
                    bar(0.6, 13)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 20)

            // 要点 小节标题 + 段落
            bar(0.3, 16).padding(.top, 22)
            paragraph([1.0, 1.0, 0.8, 0.46]).padding(.top, 14)

            // 双栏
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) { bar(1.0, 12); bar(1.0, 12); bar(0.66, 12) }
                VStack(alignment: .leading, spacing: 10) { bar(1.0, 12); bar(0.85, 12); bar(0.5, 12) }
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dimmed ? 0.38 : 1)
        .allowsHitTesting(!dimmed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dimmed
            ? IOSAppLocalization.string("生成未完成", defaultValue: "生成未完成")
            : stageText)
        .onAppear {
            guard !dimmed else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func paragraph(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                bar(w, 13)
            }
        }
    }

    private func bar(_ widthFraction: CGFloat, _ height: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: height >= 20 ? 7 : 4, style: .continuous)
                .fill(AmberTheme.surface2)
                .frame(width: geo.size.width * widthFraction)
                .opacity(dimmed ? 0.85 : (pulse ? 0.38 : 0.85))
        }
        .frame(height: height)
    }

    private static let fixedProgressKeys = [
        "准备生成",
        "正在搜索补充来源",
        "正在抓取网页正文",
        "正在生成深度阅读",
    ]

    private static let generationStageKeys = [
        "结构规划",
        "概览",
        "时间轴叙事",
        "深度分析",
        "扩展阅读",
    ]

    private static func localizedProgressLabel(_ raw: String) -> String {
        guard !raw.isEmpty else {
            return IOSAppLocalization.string("正在生成阅读稿…", defaultValue: "正在生成阅读稿…")
        }

        if let fixedKey = fixedProgressKeys.first(where: { matchesLocalizedValue(raw, canonicalKey: $0) }) {
            return IOSAppLocalization.string(fixedKey, defaultValue: fixedKey)
        }

        if let stageKey = generationStageKeys.first(where: { raw == $0 || raw.hasSuffix($0) }) {
            let localizedStage = IOSAppLocalization.string(stageKey, defaultValue: stageKey)
            if raw == stageKey {
                return localizedStage
            }
            return IOSAppLocalization.formatted(
                "正在生成%@",
                defaultValue: "正在生成%@",
                arguments: [localizedStage]
            )
        }

        return raw
    }

    private static func matchesLocalizedValue(_ raw: String, canonicalKey: String) -> Bool {
        raw == canonicalKey || IOSAppLanguage.explicitLanguages.contains {
            IOSAppLocalization.string(canonicalKey, language: $0) == raw
        }
    }
}

// 单条相关报道:杂志列表风(顶部分隔线 + 标题 + 媒体名),整条点击打开原文。
struct DeepReadRelatedRow: View {
    let source: IOSDeepReadSource
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let raw = source.url?.trimmingCharacters(in: .whitespaces),
               let link = URL(string: raw) {
                openURL(link)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(AmberTheme.borderSoft)
                    .frame(height: 1)

                Text(source.title)
                    .font(.system(size: 15))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineSpacing(1.5)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 11)

                Text(mediaLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(AmberTheme.muted)
                    .padding(.top, 5)
                    .padding(.bottom, 11)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.title)
        .accessibilityHint("打开原文")
    }

    /// 媒体名：取注册主域主体，而不是最左子域。
    /// `s.weibo.com` → WEIBO（不是 S）；`news.sina.com.cn` → SINA；`reuters.com` → REUTERS。
    private var mediaLabel: String {
        if let raw = source.url?.trimmingCharacters(in: .whitespaces),
           let host = URL(string: raw)?.host {
            return Self.brandLabel(fromHost: host)
        }
        return source.kind.localizedTitle
    }

    static func brandLabel(fromHost host: String) -> String {
        var bare = host.lowercased()
        if bare.hasPrefix("www.") {
            bare = String(bare.dropFirst(4))
        }
        let parts = bare.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return host }

        // 常见复合后缀：取后缀前一段作为品牌。
        let multiTLDs: Set<String> = [
            "com.cn", "net.cn", "org.cn", "gov.cn", "co.uk", "com.hk", "com.tw", "co.jp", "com.au",
        ]
        let brand: String
        if parts.count >= 3 {
            let lastTwo = parts.suffix(2).joined(separator: ".")
            if multiTLDs.contains(lastTwo) {
                brand = parts[parts.count - 3]
            } else {
                // s.weibo.com / m.zhihu.com → weibo / zhihu
                brand = parts[parts.count - 2]
            }
        } else if parts.count == 2 {
            brand = parts[0]
        } else {
            brand = parts[0]
        }
        return brand.uppercased()
    }
}
