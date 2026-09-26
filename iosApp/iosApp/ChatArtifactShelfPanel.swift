import SwiftUI
import UIKit

struct ChatArtifactShelfPanel: View {
    let artifacts: ConversationArtifactIndex
    var maxHeight: CGFloat? = nil
    let onLocate: (ConversationArtifactIndex.Source) -> Void
    let onClose: () -> Void
    var snippets: [IOSPinnedSnippet] = []
    var adoptedVersions: [String: String] = [:]
    var conversationTitle = ""
    var onLocateSnippet: (IOSPinnedSnippet) -> Void = { _ in }
    var onUnpinSnippet: (String) -> Void = { _ in }
    var onAdoptVersion: (String, String) -> Void = { _, _ in }
    var onContinue: (ChatArtifactContinuation) async -> Bool = { _ in false }

    @State private var selectedImage: ConversationArtifactIndex.Image?
    @State private var selectedDetail: ChatArtifactDetail?
    @State private var canScrollDown = false
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var sectionsHeight: CGFloat?
    /// 多选状态保持 internal，便于测试夹具直接渲染多选态。
    @State var isSelecting = false
    @State var selectedArtifactIDs: Set<String> = []
    @State private var exportState = ChatArtifactShelfExportState()
    @State private var isSavingImages = false
    @State private var selectionNotice: String?
    @State private var failureMessage: String?
    private let sectionSpacing: CGFloat = 14
    private let contentPadding: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            if artifactItemCount == 0 {
                emptyState
            } else {
                ScrollView(.vertical) {
                    shelfSections
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sectionsHeight = $0 }
                }
                .frame(height: scrollHeight)
                .scrollIndicators(.visible)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height > geometry.visibleRect.maxY + 1
                } action: { _, hasMore in
                    canScrollDown = hasMore
                }
                .overlay(alignment: .bottom) {
                    if canScrollDown {
                        LinearGradient(
                            colors: [AmberTheme.background.opacity(0), AmberTheme.background],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 36)
                        .allowsHitTesting(false)
                    }
                }
            }

            if isSelecting {
                selectionActions
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
        }
        .padding(contentPadding)
        .padding(.top, 8)
        .background {
            ChatArtifactShelfShape(cornerRadius: AmberTheme.homeCardRadius)
                .fill(AmberTheme.background)
                .modifier(ChatArtifactShelfGlass())
        }
        .accessibilityIdentifier("chat-artifact-shelf")
        .fullScreenCover(item: $selectedImage) { image in
            ChatGeneratedImagePreview(urlString: image.url, image: nil)
        }
        .sheet(item: $selectedDetail) { detail in
            ChatArtifactDetailSheet(detail: detail)
        }
        .alert("操作未完成", isPresented: Binding(
            get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
        )) {
            Button("好", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
        .task(id: exportKey) { await prepareExport(exportKey) }
        .task(id: selectionNotice) {
            guard selectionNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            selectionNotice = nil
        }
        .onDisappear { exportState.removeDirectories() }
    }

    private var scrollHeight: CGFloat? {
        Self.scrollHeight(
            maxHeight: maxHeight, headerHeight: headerHeight, footerHeight: footerHeight,
            sectionsHeight: sectionsHeight, isSelecting: isSelecting
        )
    }

    /// 列表可用高度；退出多选后底栏高度不再参与计算。
    static func scrollHeight(
        maxHeight: CGFloat?,
        headerHeight: CGFloat,
        footerHeight: CGFloat,
        sectionsHeight: CGFloat?,
        isSelecting: Bool,
        sectionSpacing: CGFloat = 14,
        contentPadding: CGFloat = 16
    ) -> CGFloat? {
        guard let maxHeight else { return sectionsHeight }
        let gaps = sectionSpacing * (isSelecting ? 2 : 1)
        let footer = isSelecting ? footerHeight : 0
        let available = max(0, maxHeight - headerHeight - footer - gaps - contentPadding * 2 - 8)
        return min(sectionsHeight ?? available, available)
    }

    private var shelfSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !artifacts.images.isEmpty {
                mediaStrip
            }
            if !artifacts.files.isEmpty {
                filesSection
            }
            if !artifacts.webPages.isEmpty {
                webPagesSection
            }
            if !snippets.isEmpty {
                snippetsSection
            }
        }
        .padding(.bottom, 2)
    }

    private var artifactItemCount: Int { artifacts.count + snippets.count }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AmberTheme.accent)
            Text("产物架")
                .font(.headline)
                .foregroundStyle(AmberTheme.foreground)
            if artifactItemCount > 0 {
                Text("\(artifactItemCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AmberTheme.muted)
            }
            Spacer(minLength: 8)
            if artifactItemCount > 0 {
                Button {
                    isSelecting.toggle()
                    selectedArtifactIDs = []
                    selectionNotice = nil
                } label: {
                    Text(isSelecting ? "完成" : "选择")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.accent)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-artifact-shelf-select")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("关闭产物架")
            .accessibilityIdentifier("chat-artifact-shelf-close")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AmberTheme.muted.opacity(0.8))
            Text("本对话还没有产物")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
            Text("图片、文件和网页会集中收集在这里；长按消息可收进产物架。")
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 270)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var mediaStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(artifacts.images) { image in
                    ChatArtifactMediaTile(
                        image: image,
                        onOpen: {
                            if isSelecting { toggleSelection(ChatArtifactActions.selectionID(for: image)) }
                            else { selectedImage = image }
                        },
                        onLocate: { onLocate(image.source) },
                        isSelecting: isSelecting,
                        isSelected: selectedArtifactIDs.contains(ChatArtifactActions.selectionID(for: image)),
                        onToggleSelection: { toggleSelection(ChatArtifactActions.selectionID(for: image)) },
                        onContinue: { continueFrom(.image(image)) }
                    )
                }
            }
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("文件", count: artifacts.files.count)
            ForEach(artifacts.files) { file in
                ChatArtifactFileVersionCard(
                    file: file,
                    onPreview: { version in
                        selectedDetail = .file(path: file.path, version: version)
                    },
                    onLocate: onLocate,
                    adoptedVersionID: ChatArtifactActions.adoptedVersionID(for: file, adoptedVersions: adoptedVersions),
                    isSelecting: isSelecting,
                    isSelected: selectedArtifactIDs.contains(ChatArtifactActions.selectionID(for: file)),
                    onToggleSelection: { toggleSelection(ChatArtifactActions.selectionID(for: file)) },
                    onAdoptVersion: { onAdoptVersion(file.path, $0) },
                    onContinue: { continueFrom(.file(path: file.path)) }
                )
            }
        }
    }

    private var webPagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("网页", count: artifacts.webPages.count)
            ForEach(artifacts.webPages) { page in
                ChatArtifactWebPageRow(page: page,
                    isSelecting: isSelecting,
                    isSelected: selectedArtifactIDs.contains(ChatArtifactActions.selectionID(for: page)),
                    onToggleSelection: { toggleSelection(ChatArtifactActions.selectionID(for: page)) },
                    onContinue: { continueFrom(.webPage(page)) }) {
                    selectedDetail = .webPage(page)
                } onLocate: {
                    onLocate(page.source)
                }
            }
        }
    }

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("片段", count: snippets.count)
            ForEach(snippets) { snippet in
                ChatArtifactPinnedSnippetRow(
                    snippet: snippet,
                    isSelecting: isSelecting,
                    isSelected: selectedArtifactIDs.contains(ChatArtifactActions.selectionID(for: snippet)),
                    onToggleSelection: { toggleSelection(ChatArtifactActions.selectionID(for: snippet)) },
                    onLocate: { onLocateSnippet(snippet) },
                    onCopy: {
                        UIPasteboard.general.string = snippet.text
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    },
                    onUnpin: { onUnpinSnippet(snippet.id) },
                    onContinue: { continueFrom(.snippet(snippet)) }
                )
            }
        }
    }

    private var selectedImages: [ConversationArtifactIndex.Image] {
        artifacts.images.filter { selectedArtifactIDs.contains(ChatArtifactActions.selectionID(for: $0)) }
    }

    /// 仍存在于当前索引中的选择；分支切换后消失的项不参与导出。
    private var validSelection: Set<String> {
        selectedArtifactIDs.intersection(
            artifacts.images.map(ChatArtifactActions.selectionID(for:))
                + artifacts.files.map(ChatArtifactActions.selectionID(for:))
                + artifacts.webPages.map(ChatArtifactActions.selectionID(for:))
                + snippets.map(ChatArtifactActions.selectionID(for:))
        )
    }

    /// 只随所选项及其导出版本变化；索引其他部分的刷新不触发重新导出。
    private var exportKey: ChatArtifactShelfExportKey? {
        guard isSelecting else { return nil }
        let selection = validSelection
        return ChatArtifactShelfExportKey(
            selectedIDs: selection,
            fileVersionIDs: artifacts.files
                .filter { selection.contains(ChatArtifactActions.selectionID(for: $0)) }
                .compactMap { ChatArtifactActions.selectedVersion(for: $0, adoptedVersions: adoptedVersions)?.id }
        )
    }

    private var selectionStatus: String {
        if let selectionNotice { return selectionNotice }
        let count = validSelection.count
        guard count > 0 else { return "选择要分享或导出的成果" }
        if exportState.isPreparing { return "已选 \(count) 项 · 正在准备…" }
        var parts = ["已选 \(count) 项"]
        if let skipped = exportState.export?.skippedCount, skipped > 0 {
            parts.append("\(skipped) 项无法读取，已跳过")
        }
        if let reportOnly = exportState.export?.reportOnlyCount, reportOnly > 0 {
            parts.append("\(reportOnly) 个文件无正文，仅写入报告")
        }
        return parts.joined(separator: " · ")
    }

    private var selectionActions: some View {
        VStack(spacing: 6) {
            Text(selectionStatus)
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat-artifact-shelf-selection-status")

            HStack(spacing: 6) {
                Button {
                    saveImages(selectedImages)
                } label: {
                    ChatArtifactShelfActionLabel(title: "存到相册", systemImage: "photo.badge.arrow.down")
                }
                .disabled(selectedImages.isEmpty || isSavingImages)
                .accessibilityIdentifier("chat-artifact-shelf-save-photos")

                ShareLink(items: exportState.export?.shareURLs ?? [], subject: Text(conversationTitle)) {
                    ChatArtifactShelfActionLabel(title: "分享", systemImage: "square.and.arrow.up")
                }
                .disabled(exportState.export?.shareURLs.isEmpty ?? true)
                .accessibilityIdentifier("chat-artifact-shelf-share")

                Group {
                    if let export = exportState.export {
                        ShareLink(item: export.reportURL, subject: Text("\(conversationTitle) · 成果报告")) {
                            ChatArtifactShelfActionLabel(title: "导出成果报告", systemImage: "doc.richtext")
                        }
                    } else {
                        // 报告在选择后于后台生成，生成前保持同尺寸的禁用按钮。
                        Button {} label: {
                            ChatArtifactShelfActionLabel(title: "导出成果报告", systemImage: "doc.richtext")
                        }
                        .disabled(true)
                    }
                }
                .accessibilityIdentifier("chat-artifact-shelf-export-report")
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(AmberTheme.borderSoft).frame(height: 0.5)
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedArtifactIDs.contains(id) {
            selectedArtifactIDs.remove(id)
        } else {
            selectedArtifactIDs.insert(id)
        }
    }

    private func continueFrom(_ source: ChatArtifactContinuationSource) {
        let action = ChatArtifactActions.continuation(for: source)
        Task { if await onContinue(action) { onClose() } }
    }

    private func saveImages(_ images: [ConversationArtifactIndex.Image]) {
        guard !images.isEmpty, !isSavingImages else { return }
        isSavingImages = true
        Task {
            defer { isSavingImages = false }
            var saved = 0
            do {
                for image in images {
                    try await ChatGeneratedImagePhotoWriter.write(image.url)
                    saved += 1
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                selectionNotice = "已存入相册 \(saved) 张"
            } catch {
                failureMessage = saved > 0
                    ? "已存入 \(saved) 张，其余未保存：\(error.localizedDescription)"
                    : error.localizedDescription
            }
        }
    }

    private func prepareExport(_ key: ChatArtifactShelfExportKey?) async {
        guard let key, !key.selectedIDs.isEmpty else {
            exportState.reset()
            return
        }
        // 准备期间清掉上一批结果，分享和报告按钮不会发出旧选择。
        exportState.begin()
        do {
            let prepared = try await ChatArtifactShelfExporter.prepare(
                index: artifacts, snippets: snippets, adoptedVersions: adoptedVersions,
                selectedIDs: key.selectedIDs, title: conversationTitle
            )
            // 选择已变化时丢弃这批过期文件，由新的 task 生成。
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: prepared.directory)
                return
            }
            exportState.finish(prepared.export, directory: prepared.directory)
        } catch {
            guard !Task.isCancelled else { return }
            let message = "无法准备所选成果：\(error.localizedDescription)"
            if exportState.fail(message) { failureMessage = message }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AmberTheme.muted.opacity(0.8))
        }
    }

}

private extension View {
    /// 多选时整张卡片切换选择，卡内预览、定位等按钮暂不响应；勾选圈仍是无障碍入口。
    func chatArtifactSelectionTap(_ isSelecting: Bool, perform action: @escaping () -> Void) -> some View {
        overlay {
            if isSelecting {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: action)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct ChatArtifactShelfExportKey: Equatable {
    let selectedIDs: Set<String>
    let fileVersionIDs: [String]
}

/// 多选底栏按钮：图标在上、文字在下，375pt 宽度下三项等分；辅助功能字号时文字可折两行。
private struct ChatArtifactShelfActionLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(height: 20)
            Text(title)
                .font(.caption2.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .foregroundStyle(AmberTheme.accent)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: .infinity)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct ChatArtifactMediaTile: View {
    let image: ConversationArtifactIndex.Image
    let onOpen: () -> Void
    let onLocate: () -> Void
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                ChatArtifactImageThumbnail(urlString: image.url)
                .frame(width: 112, height: 72)
                .clipShape(RoundedRectangle(
                    cornerRadius: max(0, AmberTheme.radiusLarge - 7), style: .continuous
                ))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelecting ? (isSelected ? "取消选择图片" : "选择图片") : "预览图片")
            // 勾选圈与文件、网页、片段行一致放在左上。
            .overlay(alignment: .topLeading) {
                if isSelecting {
                    Button(action: onToggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? AmberTheme.accent : .black.opacity(0.45))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !isSelecting {
                    ChatArtifactImageShareButton(urlString: image.url)
                        .padding(4)
                }
            }

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            Button("第 \(image.source.turn) 轮 ↗", action: onLocate)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AmberTheme.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("定位到第 \(image.source.turn) 轮")
        }
        .padding(7)
        .chatArtifactSelectionTap(isSelecting, perform: onToggleSelection)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .contextMenu {
            Button(action: onContinue) {
                Label("基于它继续", systemImage: "arrowshape.turn.up.left")
            }
        }
    }

    private var title: String {
        image.prompt?.nilIfBlank ?? "生成图片"
    }
}

private struct ChatArtifactImageShareButton: View {
    let urlString: String
    @State private var image: UIImage?

    private var url: URL? { IOSImageGenerationRepository.resolvedImageURL(from: urlString) }

    var body: some View {
        Group {
            if let url {
                ShareLink(item: url) { label }
            } else if let image {
                let sharedImage = Image(uiImage: image)
                ShareLink(item: sharedImage, preview: SharePreview("生成的图片", image: sharedImage)) { label }
            } else {
                label.hidden()
            }
        }
        .accessibilityLabel("分享图片")
        .task(id: urlString) {
            image = nil
            guard url == nil, urlString.hasPrefix("data:") else { return }
            let result = await ChatDataImageLoadState.resolve(urlString: urlString)
            if !Task.isCancelled, case .success(let decoded) = result { image = decoded }
        }
    }

    private var label: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AmberTheme.foreground)
            .frame(width: 26, height: 26)
            .background(AmberTheme.background.opacity(0.9), in: Circle())
            .contentShape(Circle())
    }
}

private struct ChatArtifactImageThumbnail: View {
    let urlString: String
    @State private var dataImageState: ChatDataImageLoadState = .loading

    private var isDataURL: Bool { urlString.hasPrefix("data:") }
    private var url: URL? { IOSImageGenerationRepository.resolvedImageURL(from: urlString) }

    var body: some View {
        Group {
            if isDataURL {
                switch dataImageState {
                case .success(let image):
                    Image(uiImage: image).resizable().scaledToFill()
                case .loading:
                    ProgressView().tint(AmberTheme.accent)
                case .failure:
                    imagePlaceholder
                }
            } else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView().tint(AmberTheme.accent)
                    case .failure:
                        imagePlaceholder
                    @unknown default:
                        imagePlaceholder
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(width: 112, height: 72)
        .background(AmberTheme.surface)
        .task(id: urlString) {
            guard isDataURL else { return }
            dataImageState = await ChatDataImageLoadState.resolve(urlString: urlString)
        }
    }

    private var imagePlaceholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(AmberTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatArtifactFileVersionCard: View {
    let file: ConversationArtifactIndex.FileGroup
    let onPreview: (ConversationArtifactIndex.FileVersion) -> Void
    let onLocate: (ConversationArtifactIndex.Source) -> Void
    let adoptedVersionID: String?
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onAdoptVersion: (String) -> Void
    let onContinue: () -> Void

    @State private var selectedVersionIndex: Int
    @State private var comparesWithPrevious = false

    init(
        file: ConversationArtifactIndex.FileGroup,
        onPreview: @escaping (ConversationArtifactIndex.FileVersion) -> Void,
        onLocate: @escaping (ConversationArtifactIndex.Source) -> Void,
        adoptedVersionID: String?,
        isSelecting: Bool,
        isSelected: Bool,
        onToggleSelection: @escaping () -> Void,
        onAdoptVersion: @escaping (String) -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.file = file
        self.onPreview = onPreview
        self.onLocate = onLocate
        self.adoptedVersionID = adoptedVersionID
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
        self.onAdoptVersion = onAdoptVersion
        self.onContinue = onContinue
        _selectedVersionIndex = State(initialValue: Self.initialVersionIndex(file, adoptedVersionID: adoptedVersionID))
    }

    /// 打开时先展示已采用的版本，未采用（或采用记录已失效）时展示最新版本。
    private static func initialVersionIndex(_ file: ConversationArtifactIndex.FileGroup, adoptedVersionID: String?) -> Int {
        file.versions.firstIndex { $0.id == adoptedVersionID } ?? max(0, file.versions.count - 1)
    }

    private var currentVersion: ConversationArtifactIndex.FileVersion? {
        guard file.versions.indices.contains(selectedVersionIndex) else { return nil }
        return file.versions[selectedVersionIndex]
    }

    private var previousVersion: ConversationArtifactIndex.FileVersion? {
        guard selectedVersionIndex > 0,
              file.versions.indices.contains(selectedVersionIndex - 1) else { return nil }
        return file.versions[selectedVersionIndex - 1]
    }

    private var canCompare: Bool {
        currentVersion?.content != nil && previousVersion?.content != nil
    }

    private var versionsIdentity: String {
        file.versions.map(\.id).joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                if isSelecting {
                    Button(action: onToggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? AmberTheme.accent : AmberTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "取消选择文件" : "选择文件")
                }
                Image(systemName: "doc.text")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AmberTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)
                    if file.versions.count > 1 {
                        Text("版本 \(selectedVersionIndex + 1) / \(file.versions.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AmberTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                if !isSelecting, let currentVersion, let content = currentVersion.content {
                    ShareLink(item: content) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("分享此文件版本")
                }
            }

            versionPages

            HStack(spacing: 8) {
                if canCompare {
                    Button(comparesWithPrevious ? "查看此版本" : "与上一版对比") {
                        comparesWithPrevious.toggle()
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AmberTheme.accent)
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if let currentVersion {
                    if adoptedVersionID == currentVersion.id {
                        Label("已采用", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AmberTheme.accent)
                            .fixedSize()
                            .accessibilityIdentifier("chat-artifact-adopted.\(file.path)")
                    } else if !isSelecting {
                        Button {
                            onAdoptVersion(currentVersion.id)
                        } label: {
                            Text("采用")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AmberTheme.accent)
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat-artifact-adopt.\(file.path).\(currentVersion.id)")
                    }
                    Button {
                        onLocate(currentVersion.source)
                    } label: {
                        Text("第 \(currentVersion.source.turn) 轮 ↗")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AmberTheme.accent)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("定位到第 \(currentVersion.source.turn) 轮")
                    .accessibilityIdentifier("chat-artifact-locate.\(currentVersion.source.messageID).\(currentVersion.source.toolCallID)")
                }
            }
        }
        .padding(12)
        .background {
            ZStack(alignment: .top) {
                if file.versions.count > 1 {
                    RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                        .fill(AmberTheme.surface.opacity(0.55))
                        .padding(.horizontal, 8)
                        .offset(y: 6)
                }
                RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                    .fill(AmberTheme.surface2)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .chatArtifactSelectionTap(isSelecting, perform: onToggleSelection)
        .onChange(of: versionsIdentity) { _, _ in
            selectedVersionIndex = Self.initialVersionIndex(file, adoptedVersionID: adoptedVersionID)
            comparesWithPrevious = false
        }
        .onChange(of: selectedVersionIndex) { _, _ in comparesWithPrevious = false }
        .contextMenu {
            Button(action: onContinue) {
                Label("基于它继续", systemImage: "arrowshape.turn.up.left")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-artifact-file-card.\(file.path)")
        .padding(.bottom, file.versions.count > 1 ? 6 : 0)
    }

    private var fileName: String {
        URL(fileURLWithPath: file.path).lastPathComponent
    }

    /// scrollPosition(id:) 只跟踪当前页，不负责首帧偏移（模拟器实测去掉锚点后显示第 1 页而计数为 2/2），
    /// 首帧由等宽分页锚点 i / (n - 1) 定位到采用版或最新版。
    private var initialScrollAnchor: UnitPoint {
        guard file.versions.count > 1 else { return .leading }
        let index = Self.initialVersionIndex(file, adoptedVersionID: adoptedVersionID)
        return UnitPoint(x: CGFloat(index) / CGFloat(file.versions.count - 1), y: 0.5)
    }

    private var versionPages: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(file.versions.enumerated()), id: \.element.id) { index, version in
                    Group {
                        if index == selectedVersionIndex, comparesWithPrevious, index > 0,
                           file.versions[index - 1].content != nil, version.content != nil {
                            diffPreview(previous: file.versions[index - 1], current: version)
                        } else if version.content != nil {
                            Button { onPreview(version) } label: {
                                versionSummary(version)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("预览 \(fileName) 第 \(index + 1) 版")
                        } else {
                            versionSummary(version)
                        }
                    }
                    .opacity(adoptedVersionID == nil || adoptedVersionID == version.id ? 1 : 0.42)
                    .containerRelativeFrame(.horizontal)
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .defaultScrollAnchor(initialScrollAnchor, for: .initialOffset)
        .scrollPosition(id: Binding<Int?>(
            get: { selectedVersionIndex },
            set: { if let index = $0 { selectedVersionIndex = index } }
        ))
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func versionSummary(_ version: ConversationArtifactIndex.FileVersion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let content = version.content {
                Text(String(content.prefix(180)))
                    .font(.caption.monospaced())
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            } else {
                Text("此版本未保留正文")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if version.content != nil {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(8)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium, style: .continuous))
        .contentShape(Rectangle())
    }

    private func diffPreview(
        previous: ConversationArtifactIndex.FileVersion,
        current: ConversationArtifactIndex.FileVersion
    ) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(ChatArtifactTextDiff.lines(
                    previous: previous.content ?? "",
                    current: current.content ?? ""
                ).enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(line.kind == .removed ? AmberTheme.accentRed : line.kind == .added ? AmberTheme.accentGreen : AmberTheme.foreground2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .frame(height: 132)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium, style: .continuous))
        .accessibilityLabel("与上一版的文本差异")
    }


}

private struct ChatArtifactWebPageRow: View {
    let page: ConversationArtifactIndex.WebPage
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onContinue: () -> Void
    let onPreview: () -> Void
    let onLocate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isSelecting {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AmberTheme.accent : AmberTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "取消选择网页" : "选择网页")
            }
            Button(action: onPreview) {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 30, height: 30)
                        .background(AmberTheme.accent.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)
                        Text(page.url ?? page.preview ?? "网页内容")
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onLocate) {
                Text("第 \(page.source.turn) 轮 ↗")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AmberTheme.accent)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("定位到第 \(page.source.turn) 轮")
            .accessibilityIdentifier("chat-artifact-locate.\(page.source.messageID).\(page.source.toolCallID)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        .chatArtifactSelectionTap(isSelecting, perform: onToggleSelection)
        .contextMenu {
            Button(action: onContinue) {
                Label("基于它继续", systemImage: "arrowshape.turn.up.left")
            }
        }
    }
}

private struct ChatArtifactPinnedSnippetRow: View {
    let snippet: IOSPinnedSnippet
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onLocate: () -> Void
    let onCopy: () -> Void
    let onUnpin: () -> Void
    let onContinue: () -> Void

    private var firstLines: String {
        snippet.text
            .components(separatedBy: .newlines)
            .prefix(4)
            .joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if isSelecting {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AmberTheme.accent : AmberTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "取消选择片段" : "选择片段")
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(firstLines)
                    .font(snippet.kind == .code ? .caption.monospaced() : .subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 0) {
                    Button(action: onLocate) {
                        Text("第 \(snippet.turn) 轮 ↗")
                            .font(.caption.weight(.medium))
                            .fixedSize()
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("定位到第 \(snippet.turn) 轮")
                    Spacer(minLength: 8)

                    if !isSelecting {
                        Button(action: onCopy) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption.weight(.medium))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("复制片段")

                        Button(action: onUnpin) {
                            Image(systemName: "pin.slash")
                                .font(.caption.weight(.medium))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("取消收藏片段")
                    }
                }
                .foregroundStyle(AmberTheme.accent)
                .buttonStyle(.plain)
                .padding(.vertical, -8)
                .padding(.trailing, -8)
            }
        }
        .padding(11)
        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .chatArtifactSelectionTap(isSelecting, perform: onToggleSelection)
        .contextMenu {
            Button(action: onContinue) {
                Label("基于它继续", systemImage: "arrowshape.turn.up.left")
            }
            Button(action: onUnpin) {
                Label("取消收藏", systemImage: "pin.slash")
            }
        }
    }
}

private enum ChatArtifactDetail: Identifiable {
    case file(path: String, version: ConversationArtifactIndex.FileVersion)
    case webPage(ConversationArtifactIndex.WebPage)

    var id: String {
        switch self {
        case .file(let path, let version): "file-\(path)-\(version.id)"
        case .webPage(let page): "web-\(page.id)"
        }
    }
}

private struct ChatArtifactDetailSheet: View {
    let detail: ChatArtifactDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch detail {
                    case .file(let path, let version):
                        filePreview(path: path, version: version)
                    case .webPage(let page):
                        webPreview(page)
                    }
                }
                .padding(16)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    switch detail {
                    case .file(_, let version):
                        if let content = version.content {
                            ShareLink(item: content) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("分享此文件版本")
                        }
                    case .webPage(let page):
                        if let url = page.url.flatMap(ChatMarkdownOpenURLPolicy.url(from:)) {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("分享网页")
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func filePreview(path: String, version: ConversationArtifactIndex.FileVersion) -> some View {
        detailHeader(
            systemImage: "doc.text",
            title: URL(fileURLWithPath: path).lastPathComponent,
            subtitle: path
        )
        WorkspacePreviewBlock(
            text: version.content ?? "",
            emptyText: "此版本没有可预览的文本内容。"
        )
    }

    @ViewBuilder
    private func webPreview(_ page: ConversationArtifactIndex.WebPage) -> some View {
        detailHeader(systemImage: "globe", title: page.title, subtitle: page.url ?? "网页")
        if let url = page.url.flatMap(ChatMarkdownOpenURLPolicy.url(from:)) {
            Link(destination: url) {
                Label("在浏览器中打开", systemImage: "safari")
                    .font(.subheadline.weight(.medium))
            }
        }
        if let preview = page.preview?.nilIfBlank {
            WorkspacePreviewBlock(text: preview, emptyText: "没有网页摘要。")
        }
    }

    private func detailHeader(systemImage: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 42, height: 42)
                .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(3)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ChatArtifactShelfGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: ChatArtifactShelfShape(cornerRadius: AmberTheme.homeCardRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: ChatArtifactShelfShape(cornerRadius: AmberTheme.homeCardRadius))
                .overlay {
                    ChatArtifactShelfShape(cornerRadius: AmberTheme.homeCardRadius)
                        .stroke(AmberTheme.border.opacity(0.28), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        }
    }
}


private struct ChatArtifactShelfShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + 8
        // 面板右缘与圆形停靠位齐平，尖角的中心距右缘恰为按钮半径。
        let arrowX = rect.maxX - ChatTopBarLayout.toolbarButtonDiameter / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: top))
        path.addLine(to: CGPoint(x: arrowX - 9, y: top))
        path.addQuadCurve(to: CGPoint(x: arrowX - 2, y: top - 7),
                          control: CGPoint(x: arrowX - 5, y: top - 2))
        path.addQuadCurve(to: CGPoint(x: arrowX + 2, y: top - 7),
                          control: CGPoint(x: arrowX, y: top - 9))
        path.addQuadCurve(to: CGPoint(x: arrowX + 8, y: top + 2),
                          control: CGPoint(x: arrowX + 4, y: top - 5))
        path.addCurve(to: CGPoint(x: rect.maxX, y: top + cornerRadius),
                      control1: CGPoint(x: rect.maxX - 1, y: top + 5),
                      control2: CGPoint(x: rect.maxX, y: top + cornerRadius - 8))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: top + cornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + cornerRadius, y: top),
                          control: CGPoint(x: rect.minX, y: top))
        path.closeSubpath()
        return path
    }
}
