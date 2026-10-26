import SwiftUI

struct DesktopImageGenerationView: View {
    let workspace: DesktopWorkspace
    let ownerID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var style = ""
    @State private var aspectRatio = IOSImageAspectRatio.square
    @State private var count = 1
    @State private var operation: Task<Void, Never>?
    @State private var error: String?
    @State private var addedImages: Set<UUID> = []

    private var generator: DesktopImageGeneration { workspace.imageGeneration }
    private var ownsResult: Bool { generator.ownerID == ownerID }
    private var ownerExists: Bool { workspace.summaries.contains { $0.id == ownerID } }
    private var ownerTitle: String { workspace.summaries.first { $0.id == ownerID }?.title ?? "原会话已删除" }
    private var pendingSaveCount: Int { generator.pendingSaveCount(for: ownerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("图片生成").font(DesktopTheme.serif(size: 22, weight: .semibold))
                    Text("保存到：\(ownerTitle)").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(1).help(ownerTitle)
                }
                Spacer()
                Button(generator.isRunning && ownsResult ? "取消并关闭" : "完成") {
                    if ownsResult { operation?.cancel(); generator.cancel() }
                    dismiss()
                }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !generator.isAvailable {
                        Label("界面预览不调用真实生图服务，请使用正式版本。", systemImage: "info.circle")
                            .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary)
                    }
                    HStack {
                        Text(generator.configuredModelName ?? "尚未配置生图模型").lineLimit(1)
                        Spacer()
                        SettingsLink { Text("选择生图模型…") }.buttonStyle(.link).foregroundStyle(DesktopTheme.accent)
                    }.font(.system(size: 13))
                    Text("描述想要生成的图片").font(.system(size: 14, weight: .semibold))
                    TextEditor(text: $prompt)
                        .font(.system(size: 14))
                        .frame(height: 110)
                        .desktopEditor()
                        .accessibilityLabel("图片提示词")
                        .disabled(generator.isRunning)
                    HStack(spacing: 20) {
                        Picker("画幅", selection: $aspectRatio) {
                            ForEach(IOSImageAspectRatio.allCases) { Text($0.title).tag($0) }
                        }.frame(maxWidth: 240)
                        Stepper("数量：\(count)", value: $count, in: 1...4)
                    }.disabled(generator.isRunning)
                    TextField("风格（可选）", text: $style).textFieldStyle(.desktop).disabled(generator.isRunning)
                    Text("生成结果直接保存在原会话文件中；加入草稿后，发送时才会作为图片附件进入对话。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                    if pendingSaveCount > 0 {
                        Label("\(pendingSaveCount) 张生成结果已保留，等待保存到原会话文件。", systemImage: "tray.and.arrow.down")
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Text("重试只保存本地文件，不会再次请求模型生成。")
                            .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    }
                    if ownsResult, let status = generator.statusMessage {
                        Label(status, systemImage: generator.isRunning ? "sparkles" : "checkmark.circle")
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = error ?? (ownsResult ? generator.errorMessage : nil) {
                        Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.danger).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if ownsResult {
                        ForEach(generator.artifacts, id: \.document.id) { artifact in
                            VStack(alignment: .leading, spacing: 10) {
                                if let image = artifact.document.image {
                                    DesktopMessageImageView(source: .init(url: image.dataURL, name: artifact.document.name))
                                }
                                HStack {
                                    Text("已保存到原会话文件").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                                    Spacer()
                                    Button(addedImages.contains(artifact.document.id) ? "已加入草稿" : "加入原会话草稿") {
                                        do {
                                            try workspace.addGeneratedImageAttachments([artifact.document], to: ownerID)
                                            addedImages.insert(artifact.document.id)
                                            error = nil
                                        } catch { self.error = error.localizedDescription }
                                    }
                                    .disabled(generator.isRunning || !ownerExists || workspace.isManagingBackup || addedImages.contains(artifact.document.id))
                                }
                            }
                            .padding(12)
                            .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            HStack {
                if generator.isRunning {
                    ProgressView().controlSize(.small)
                    Text(ownsResult ? "正在生成，可取消" : "另一会话正在生成图片")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer()
                if generator.isRunning && ownsResult {
                    Button("取消生成", role: .cancel) { operation?.cancel(); generator.cancel() }
                } else if pendingSaveCount > 0 {
                    Button("重试保存") { retrySaving() }
                        .buttonStyle(.desktopProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(generator.isRunning || !ownerExists || workspace.isManagingBackup)
                } else {
                    Button("生成图片") { generate() }
                        .buttonStyle(.desktopProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(generator.isRunning || !generator.isAvailable || !ownerExists || workspace.isManagingBackup
                            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24).frame(width: 680, height: 620)
        .interactiveDismissDisabled(generator.isRunning && ownsResult)
        .onDisappear { if ownsResult { operation?.cancel(); generator.cancel() }; workspace.reloadFiles() }
    }

    private func generate() {
        addedImages = []
        run {
            try await workspace.generateImages(ownerID: ownerID, prompt: prompt, aspectRatio: aspectRatio, count: count, style: style)
        }
    }

    private func retrySaving() {
        run { try await workspace.retryGeneratedImageSaving(ownerID: ownerID) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> [DesktopGeneratedImageArtifact]) {
        error = nil
        operation = Task {
            do {
                _ = try await action()
            } catch is CancellationError {
                // The generator retains the cancellation status and any saved artifacts.
            } catch {
                if (error as? URLError)?.code != .cancelled {
                    self.error = error is DesktopRuntimeError ? error.localizedDescription
                        : generator.errorMessage ?? "图片生成失败，请检查服务与原会话文件后重试。"
                }
            }
            workspace.reloadFiles()
            operation = nil
        }
    }
}
