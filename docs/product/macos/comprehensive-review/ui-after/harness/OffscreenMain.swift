import AppKit
import SwiftUI

@main struct AmberOffscreenMain {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); try await capturePhase2States(); try await captureEditorStates(); print("OFFSCREEN COMPLETE"); exit(0) }
            catch { print("OFFSCREEN FAILED", error); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let workspace = DesktopWorkspace.uiFixture()
        await workspace.agentTasks.waitUntilLoaded()
        await workspace.collaborations.waitUntilLoaded()
        let owner = workspace.selectedID!
        try await capture("workspace-chat-1280-light", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 1280, height: 800, dark: false)
        try await capture("workspace-chat-860-dark", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 860, height: 600, dark: true)
        workspace.draft = "帮我整理今天的思路。"
        try await capture("workspace-compose-active-860-dark", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 860, height: 600, dark: true)
        try await capture("workspace-compose-active-860-light", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 860, height: 600, dark: false)
        workspace.draft = ""
        let empty = DesktopWorkspace.uiFixture()
        empty.createConversation()
        try await capture("workspace-welcome-1280-light", view: DesktopWorkspaceView(workspace: empty, searchRequest: 0), width: 1280, height: 800, dark: false)
        try await capture("workspace-welcome-860-dark", view: DesktopWorkspaceView(workspace: empty, searchRequest: 0), width: 860, height: 600, dark: true)
        if var config = workspace.settings.selectedProvider {
            if let index = config.models.firstIndex(where: { $0.id == config.selectedModelID }) {
                config.models[index].name = "用于离屏布局检查的很长很长模型名称 · 应保持单行并可通过悬停查看完整内容"
            }
            try workspace.settings.saveProvider(config, apiKey: "fixture-only")
            if let modelID = config.selectedModelID { workspace.settings.setAuxiliaryModel(modelID, for: .imageGeneration) }
        }
        let knowledge = workspace.knowledge
        let staging = URL(fileURLWithPath: "/tmp/amber-offscreen-review/fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let skill = staging.appendingPathComponent("SKILL.md")
        try Data("---\nname: detailed-project-context\ndescription: 这是用于离屏布局检查的较长技能说明。它包含工作目标、边界与交付要求，应当自然换行，不把右侧启用、编辑和删除按钮推到边缘之外。\nallowed-tools: workspace_file_read workspace_file_list\n---\n检查当前工作区的真实资料，结合任务背景组织可验证的下一步。\n".utf8).write(to: skill)
        try knowledge.importSkill(from: skill)
        try knowledge.setSkillEnabled("detailed-project-context", enabled: true)
        try knowledge.saveSoul("# 工作偏好\n\n先确认资料来源，再组织结果。保持简洁，保留可追溯来源。", source: "离屏验证临时fixture")
        var memory = DesktopMemoryRecord(content: "布局检查用记忆：较长中文段落应完整显示，来源会话可以追踪，元数据与操作不相互挤压。")
        memory.sourceConversationId = owner.uuidString.lowercased()
        memory.sourceMessageIds = [workspace.selectedConversation!.messages[0].id.uuidString.lowercased()]
        memory.pinned = true
        _ = try knowledge.saveMemory(memory)
        let taskID = try await workspace.agentTasks.begin(conversationID: owner, title: "离屏验证任务 · 写入一份较长中文文件名的阶段成果并检查参数展示与确认按钮", cancel: {})
        try await workspace.agentTasks.requestApproval(runID: taskID, approval: DesktopToolApproval(id: "offscreen-approval", name: "workspace_file_write", arguments: "{\"path\":\"阶段成果/桌面版复用检查与后续验证计划.md\",\"content\":\"这是真实任务卡的布局fixture；并未执行文件写入工具。长参数应能阅读或滚动，确认按钮保持完整。\"}", reason: "请求向原会话工作区写入文件。请核对目标路径和内容；本场景仅显示确认卡，不会执行工具。"))
        let recipe = staging.appendingPathComponent("recipe.json")
        try Data(#"{"schema":"amber.recipe.v1","name":"review_and_save_project_notes","version":"1.0.0","description":"读取工作区内容，整理较长的中文阶段说明，再保存到指定路径。每个固定步骤沿用原有权限与取消规则。","inputs":{"output_path":"string","include_sources":"boolean"},"steps":[{"id":"list","tool":"workspace_file_list","arguments":{}},{"id":"save","tool":"workspace_file_write","arguments":{"path":"${input.output_path}","content":"离屏验证静态文本，不执行此Recipe。"}}],"outputs":{"saved_path":"${step.save.output.path}"}}"#.utf8).write(to: recipe)
        try workspace.recipes.store.importRecipe(from: recipe)
        try workspace.recipes.store.setEnabled("review_and_save_project_notes", enabled: true)

        try await capture("knowledge-skills-light", view: DesktopKnowledgeView(store: knowledge, conversationIDs: [owner], onOpenSource: { _, _ in }), width: 860, height: 720, dark: false)
        try await capture("knowledge-soul-light", view: DesktopKnowledgeView(store: knowledge, conversationIDs: [owner], onOpenSource: { _, _ in }), width: 860, height: 720, dark: false, tab: 1)
        try await capture("knowledge-memory-dark", view: DesktopKnowledgeView(store: knowledge, conversationIDs: [owner], onOpenSource: { _, _ in }), width: 860, height: 720, dark: true, tab: 2)
        try await capture("tasks-approval-dark", view: DesktopAgentTasksView(workspace: workspace), width: 860, height: 720, dark: true)
        try await capture("recipes-light", view: DesktopRecipesView(workspace: workspace), width: 860, height: 750, dark: false)
        try await capture("collaboration-dark", view: DesktopCollaborationsView(workspace: workspace, onOpenSavedResult: { _, _ in }), width: 860, height: 780, dark: true)
        try await capture("settings-providers-light", view: PreviewSettingsView(workspace: workspace), width: 860, height: 760, dark: false)
        try await capture("settings-general-dark", view: PreviewSettingsView(workspace: workspace), width: 860, height: 760, dark: true, tab: 1)
        try await capture("settings-mcp-light", view: PreviewSettingsView(workspace: workspace), width: 860, height: 760, dark: false, tab: 2)
        try await capture("settings-sync-dark", view: PreviewSettingsView(workspace: workspace), width: 860, height: 760, dark: true, tab: 3)
        try await capture("image-form-light", view: DesktopImageGenerationView(workspace: workspace, ownerID: owner), width: 860, height: 720, dark: false)
        try await capture("storage-dark", view: DesktopStorageUsageView(sources: workspace.storageUsageSources, conversationCount: workspace.summaries.count), width: 860, height: 640, dark: true)
        let config = DesktopProviderConfiguration(name: "离屏验证导入配置 · 较长服务商名称", kind: .openAI, baseURL: "https://api.example.com/v1", modelID: "long-model-name-for-layout-review-only")
        var restoredMemory = DesktopMemoryRecord(content: "离屏恢复fixture，检查真实长恢复状态行自然换行。")
        restoredMemory.id = 1000
        var payload = DesktopBackupPayload(providers: [config], memories: [restoredMemory], knowledgeFiles: [DesktopBackupPayload.File(path: "SOUL.md", data: Data("离屏验证知识副本".utf8))])
        payload.preferences = DesktopBackupPayload.Preferences(workspace.settings)
        let restored = workspace.importBackup(data: try DesktopBackup.encode(payload, password: nil), password: nil)
        await restored?.value
        print("BACKUP STATUS", workspace.backupStatusMessage ?? "nil", "ERROR", workspace.backupErrorMessage ?? "nil")
        try await capture("backup-restored-light", view: DesktopBackupView(workspace: workspace), width: 860, height: 560, dark: false)
        try await capture("backup-restored-dark", view: DesktopBackupView(workspace: workspace), width: 1280, height: 680, dark: true)
        workspace.select(owner)
        workspace.draft = "离屏布局检查的输入草稿：文字与附件入口、工具开关、模型菜单、发送按钮应对齐。"
        workspace.send()
        for number in 1...3 { workspace.draft = "排队指令 \(number)：保持原会话归属，较长说明完整换行，等待当前生成结束后继续。"; _ = workspace.queueInstruction() }
        try await capture("workspace-queue-860-light", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 860, height: 600, dark: false)
        try await capture("workspace-queue-860-dark", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 860, height: 600, dark: true)
        try await capture("workspace-queue-1280-dark", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 1280, height: 800, dark: true)
        workspace.stop()
        if let reading = workspace.conversations.first(where: { $0.title == "阅读排版 · 本地示例" }) {
            workspace.select(reading.id)
            try await capture("workspace-reading-1280-dark", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 1280, height: 1000, dark: true)
            try await capture("workspace-reading-860-light", view: DesktopWorkspaceView(workspace: workspace, searchRequest: 0), width: 860, height: 800, dark: false)
        }
        _ = await workspace.flush()
    }

    @MainActor static func capture<V: View>(_ name: String, view: V, width: CGFloat, height: CGFloat, dark: Bool, tab: Int? = nil) async throws {
        if name == "settings-general-dark" { return } // General notification authorization requires the real registered app bundle; covered by CUA.
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let filter = ProcessInfo.processInfo.environment["AMBER_OFFSCREEN_FILTER"], !name.hasPrefix(filter) { return }
        let root = Group {
            if name.hasPrefix("workspace") {
                view.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
            Text("离屏原生布局验证 · \(name) · 视口 \(Int(width))×\(Int(height))pt · 非交互窗口截图")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 26).background(.secondary.opacity(0.08))
            view.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, dark ? .dark : .light)
        .tint(DesktopTheme.accent)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.title = "离屏验证 · " + name
        window.contentView = hosting
        window.orderFront(nil)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        try await Task.sleep(for: .milliseconds(450))
        hosting.layoutSubtreeIfNeeded()
        if let tab {
            let found = allViews(hosting).compactMap { $0 as? NSTabView }
            print("TABS", name, found.map { $0.numberOfTabViewItems })
            if let control = found.first, tab < control.numberOfTabViewItems {
                control.selectTabViewItem(at: tab)
                try await Task.sleep(for: .milliseconds(200))
                hosting.layoutSubtreeIfNeeded()
            } else if let control = allViews(hosting).compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount > tab }) {
                control.selectedSegment = tab
                if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
                try await Task.sleep(for: .milliseconds(250))
                hosting.layoutSubtreeIfNeeded()
                FileHandle.standardError.write(Data("NATIVE_SEGMENT_ACTION \(name) selected=\(control.selectedSegment) count=\(control.segmentCount)\n".utf8))
            }
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw DesktopRuntimeError.message("无法创建原生离屏bitmap。") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DesktopRuntimeError.message("无法编码离屏PNG。") }
        try png.write(to: URL(fileURLWithPath: "/Users/mi/Downloads/AI/AmberAgent/ios/docs/product/macos/comprehensive-review/ui-after/components/" + name + ".png"))
        print("CAPTURE", name, "content", hosting.bounds, "window", window.frame, "pixels", bitmap.pixelsWide, bitmap.pixelsHigh)
        window.orderOut(nil)
    }
    @MainActor static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
