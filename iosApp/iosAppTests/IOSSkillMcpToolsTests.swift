import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSSkillMcpToolsTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    func testInstallBuiltinSkillsSeedsSkillCreatorAndEnablesIt() throws {
        let root = tempRoot()
        let store = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "builtin-skills-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)

        let installed = IOSBuiltinSkills.installIfMissing(into: store, enableWith: settings)

        XCTAssertEqual(Set(installed), Set(IOSBuiltinSkills.factorySeedNames))
        XCTAssertEqual(Set(store.listSkillDirNames()), Set(IOSBuiltinSkills.factorySeedNames))
        XCTAssertTrue(settings.isSkillEnabled("skill-creator"))
        XCTAssertFalse(settings.isSkillEnabled("visual-svg"), "optional seed must not auto-enable")
        XCTAssertFalse(settings.isSkillEnabled("amber-ui-design"), "optional seed must not auto-enable")
        XCTAssertFalse(settings.isSkillEnabled("会议准备"))
        XCTAssertFalse(settings.isSkillEnabled("监控文档"))

        let second = IOSBuiltinSkills.installIfMissing(into: store, enableWith: settings)
        XCTAssertTrue(second.isEmpty, "second install must not overwrite existing builtins")
    }

    func testAmberUIDesignSeedParsesAsBuiltinSkill() throws {
        let root = tempRoot()
        let store = IOSSkillFileStore(baseDirectory: root)
        _ = IOSBuiltinSkills.installIfMissing(into: store)

        let factory = try XCTUnwrap(IOSBuiltinSkills.markdown(for: "amber-ui-design"))
        XCTAssertTrue(IOSBuiltinSkills.isFactorySnapshot(factory))
        XCTAssertEqual(try store.readSkillMarkdown(dirName: "amber-ui-design"), factory)

        let scanned = IosSkillFactory.shared.listSkills(documentsDir: root.path)
        XCTAssertEqual(scanned.count, IOSBuiltinSkills.factorySeedNames.count)
        XCTAssertTrue(scanned.contains { $0.name == "amber-ui-design" })
        XCTAssertTrue(IosSkillFactory.shared.listIssues(documentsDir: root.path).isEmpty)
    }

    func testOptionalAmberUIDesignSeedCanBeDeletedAndRestored() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        _ = IOSBuiltinSkills.installIfMissing(into: store)
        let factory = try XCTUnwrap(IOSBuiltinSkills.markdown(for: "amber-ui-design"))

        try store.deleteSkill(dirName: "amber-ui-design")
        IOSBuiltinSkills.markOptionalSeedRemoved("amber-ui-design", store: store)
        XCTAssertTrue(IOSBuiltinSkills.isOptionalSeedRemoved("amber-ui-design", store: store))
        _ = IOSBuiltinSkills.installIfMissing(into: store)
        XCTAssertFalse(store.listSkillDirNames().contains("amber-ui-design"))

        try IOSBuiltinSkills.restoreFactoryContent(name: "amber-ui-design", into: store)
        XCTAssertEqual(try store.readSkillMarkdown(dirName: "amber-ui-design"), factory)
        XCTAssertFalse(IOSBuiltinSkills.isOptionalSeedRemoved("amber-ui-design", store: store))
    }

    func testOptionalVisualSvgSeedIsDeletableAndRestorable() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        _ = IOSBuiltinSkills.installIfMissing(into: store)

        let factory = try XCTUnwrap(IOSBuiltinSkills.markdown(for: "visual-svg"))
        XCTAssertTrue(factory.contains("show-widget"))
        XCTAssertTrue(factory.contains("diagram"))
        XCTAssertTrue(factory.contains("illustration"))
        XCTAssertFalse(factory.contains("先 use_skill"))
        XCTAssertEqual(try store.readSkillMarkdown(dirName: "visual-svg"), factory)

        let edited = """
        ---
        name: visual-svg
        description: agent 改过的 visual-svg。
        ---

        # 自定义
        """
        _ = try store.saveSkillFiles(files: ["SKILL.md": edited])
        XCTAssertEqual(try store.readSkillMarkdown(dirName: "visual-svg"), edited)

        try IOSBuiltinSkills.restoreFactoryContent(name: "visual-svg", into: store)
        XCTAssertEqual(try store.readSkillMarkdown(dirName: "visual-svg"), factory)

        try store.deleteSkill(dirName: "visual-svg")
        IOSBuiltinSkills.markOptionalSeedRemoved("visual-svg", store: store)
        XCTAssertFalse(store.listSkillDirNames().contains("visual-svg"))

        let reinstall = IOSBuiltinSkills.installIfMissing(into: store)
        XCTAssertFalse(reinstall.contains("visual-svg"))
        XCTAssertFalse(store.listSkillDirNames().contains("visual-svg"))

        try IOSBuiltinSkills.restoreFactoryContent(name: "visual-svg", into: store)
        XCTAssertTrue(store.listSkillDirNames().contains("visual-svg"))
        XCTAssertFalse(IOSBuiltinSkills.isOptionalSeedRemoved("visual-svg", store: store))
    }

    func testSkillImportPreservesDisabledOptionalSeedEnableState() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "skill-import-optional-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let workspace = IOSWorkspaceStore(
            baseDirectory: tempRoot().appendingPathComponent("workspace", isDirectory: true)
        )
        _ = IOSBuiltinSkills.installIfMissing(into: skillStore, enableWith: settings)
        XCTAssertFalse(settings.isSkillEnabled("visual-svg"))

        let factory = try XCTUnwrap(IOSBuiltinSkills.markdown(for: "visual-svg"))
        let writeInput = try JSONSerialization.data(
            withJSONObject: [
                "path": "/workspace/skills/visual-svg/SKILL.md",
                "content": factory.replacingOccurrences(
                    of: "version: 1.1.0",
                    with: "version: 1.1.0-edited"
                ),
                "overwrite": true,
            ] as [String: Any],
            options: []
        )
        let writeResult = await workspace.executeTool(
            toolName: "workspace_file_write",
            input: String(data: writeInput, encoding: .utf8) ?? "{}"
        )
        XCTAssertTrue(writeResult.contains(#""ok":true"#), writeResult)

        let mcpDefaults = UserDefaults(suiteName: "mcp-optional-\(UUID().uuidString)")!
        let mcpStore = IOSMcpConfigStore(userDefaults: mcpDefaults)
        let mcpManager = IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        let service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: workspace,
            mcpConfigStore: mcpStore,
            mcpManager: mcpManager
        )
        let prepared = try service.prepareSkillImport(
            arguments: #"{"workspace_path":"/workspace/skills/visual-svg/SKILL.md"}"#
        )
        let imported = try service.applyPreparedSkillImport(prepared)
        XCTAssertTrue(imported.contains(#""success":true"#), imported)
        XCTAssertTrue(imported.contains(#""enabled":false"#), imported)
        XCTAssertFalse(settings.isSkillEnabled("visual-svg"))
    }

    func testInstallBuiltinSkillsRemovesDeprecatedMeetingAndDocumentSeeds() throws {
        let root = tempRoot()
        let store = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "builtin-skills-cleanup-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)

        for name in ["会议准备", "监控文档"] {
            _ = try store.saveSkillFiles(
                files: [
                    "SKILL.md": """
                    ---
                    name: \(name)
                    description: deprecated seed
                    ---

                    # \(name)
                    """
                ],
                allowBuiltinSkill: true
            )
            settings.setSkillEnabled(name: name, enabled: true)
        }

        _ = IOSBuiltinSkills.installIfMissing(into: store, enableWith: settings)

        XCTAssertFalse(store.listSkillDirNames().contains("会议准备"))
        XCTAssertFalse(store.listSkillDirNames().contains("监控文档"))
        XCTAssertTrue(store.listSkillDirNames().contains("skill-creator"))
        XCTAssertTrue(store.listSkillDirNames().contains("visual-svg"))
        XCTAssertFalse(settings.isSkillEnabled("会议准备"))
        XCTAssertFalse(settings.isSkillEnabled("监控文档"))
        XCTAssertFalse(settings.isSkillEnabled("visual-svg"))
    }

    func testSkillPackageImportCanIterateSkillCreatorAndRestoreFactoryBackup() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        _ = IOSBuiltinSkills.installIfMissing(into: store)
        let factory = try store.readSkillMarkdown(dirName: "skill-creator")
        XCTAssertTrue(factory.contains("当用户要创建、更新或迭代"))
        let replacement = """
        ---
        name: skill-creator
        description: 迭代后的 skill-creator 描述。
        ---

        # 迭代版
        Agent 可以覆盖本机 skill-creator。
        """

        _ = try store.saveSkillFiles(files: ["SKILL.md": replacement])
        XCTAssertEqual(try store.readSkillMarkdown(dirName: "skill-creator"), replacement)

        try IOSBuiltinSkills.restoreFactoryContent(name: "skill-creator", into: store)
        let restored = try store.readSkillMarkdown(dirName: "skill-creator")
        XCTAssertTrue(IOSBuiltinSkills.isFactorySnapshot(restored))
        XCTAssertTrue(restored.contains("当用户要创建、更新或迭代"))
        XCTAssertTrue(restored.contains("version: 2.2.0"))
        XCTAssertTrue(restored.contains("allowed-tools: workspace_file_write"))
        XCTAssertTrue(restored.contains("渐进披露"))
        XCTAssertTrue(restored.contains("轻量验收"))
        XCTAssertThrowsError(try store.deleteSkill(dirName: "skill-creator")) { error in
            XCTAssertEqual(error as? IOSSkillFileStoreError, .builtinSkillProtected("skill-creator"))
        }
    }

    func testInstallRefreshesUnmodifiedLegacyEnglishSkillCreator() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let legacy = IOSBuiltinSkills.legacyEnglishSkillCreatorMarkdown
        _ = try store.saveSkillFiles(files: ["SKILL.md": legacy], allowBuiltinSkill: true)
        XCTAssertTrue(IOSBuiltinSkills.isFactorySnapshot(legacy))

        _ = IOSBuiltinSkills.installIfMissing(into: store)
        let refreshed = try store.readSkillMarkdown(dirName: "skill-creator")
        XCTAssertTrue(refreshed.contains("version: 2.2.0"))
        XCTAssertTrue(refreshed.contains("当用户要创建、更新或迭代"))
        XCTAssertFalse(refreshed.contains("Use when the user wants to create a new AmberAgent skill"))
    }

    func testInstallRefreshesUnmodifiedLegacyChineseSkillCreatorV21() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let legacy = IOSBuiltinSkills.legacyChineseSkillCreatorMarkdownV21
        _ = try store.saveSkillFiles(
            files: [
                "SKILL.md": legacy,
                "references/kept.md": "keep across factory refresh\n",
            ],
            allowBuiltinSkill: true
        )
        XCTAssertTrue(IOSBuiltinSkills.isFactorySnapshot(legacy))

        _ = IOSBuiltinSkills.installIfMissing(into: store)
        let refreshed = try store.readSkillMarkdown(dirName: "skill-creator")
        XCTAssertTrue(refreshed.contains("version: 2.2.0"))
        XCTAssertTrue(refreshed.contains("渐进披露"))
        XCTAssertFalse(refreshed.contains("version: 2.1.0"))
        let kept = try store.resolveSkillFile(name: "skill-creator", relativePath: "references/kept.md")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "keep across factory refresh\n")
    }

    func testInstallRefreshesUnmodifiedLegacyVisualSvgV101() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let legacy = IOSBuiltinSkills.legacyVisualSvgMarkdownV101
        _ = try store.saveSkillFiles(files: ["SKILL.md": legacy], allowBuiltinSkill: true)
        XCTAssertTrue(IOSBuiltinSkills.isFactorySnapshot(legacy))

        _ = IOSBuiltinSkills.installIfMissing(into: store)
        let refreshed = try store.readSkillMarkdown(dirName: "visual-svg")
        XCTAssertTrue(refreshed.contains("version: 1.1.0"))
        XCTAssertTrue(refreshed.contains("动效"))
        XCTAssertTrue(refreshed.contains("animateTransform"))
        XCTAssertFalse(refreshed.contains("version: 1.0.1"))
    }

    func testSkillImportSingleSkillMarkdownMergesExistingSiblings() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "skill-import-merge-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let workspace = IOSWorkspaceStore(
            baseDirectory: tempRoot().appendingPathComponent("workspace", isDirectory: true)
        )
        let mcpDefaults = UserDefaults(suiteName: "mcp-import-merge-\(UUID().uuidString)")!
        let mcpStore = IOSMcpConfigStore(userDefaults: mcpDefaults)
        let mcpManager = IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        _ = try skillStore.saveSkillFiles(files: [
            "SKILL.md": """
            ---
            name: merge-pack
            description: installed
            ---

            # installed
            """,
            "assets/logo.txt": "logo\n",
        ])
        settings.setSkillEnabled(name: "merge-pack", enabled: true)

        let updated = """
        ---
        name: merge-pack
        description: imported update
        ---

        # imported
        """
        let writeInput = try JSONSerialization.data(
            withJSONObject: [
                "path": "/workspace/skills/merge-pack/SKILL.md",
                "content": updated,
            ]
        )
        _ = await workspace.executeTool(
            toolName: "workspace_file_write",
            input: String(data: writeInput, encoding: .utf8) ?? "{}"
        )

        let service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: workspace,
            mcpConfigStore: mcpStore,
            mcpManager: mcpManager
        )
        let prepared = try service.prepareSkillImport(
            arguments: #"{"workspace_path":"/workspace/skills/merge-pack/SKILL.md"}"#
        )
        let imported = try service.applyPreparedSkillImport(prepared)
        XCTAssertTrue(imported.contains(#""success":true"#), imported)
        XCTAssertTrue(try skillStore.readSkillMarkdown(dirName: "merge-pack").contains("imported update"))
        let logo = try skillStore.resolveSkillFile(name: "merge-pack", relativePath: "assets/logo.txt")
        XCTAssertEqual(try String(contentsOf: logo, encoding: .utf8), "logo\n")
    }

    func testInstallPreservesAgentIteratedSkillCreator() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        _ = IOSBuiltinSkills.installIfMissing(into: store)
        let iterated = """
        ---
        name: skill-creator
        description: agent 自己改过的描述。
        ---

        # 自定义迭代
        不要被启动 seed 覆盖。
        """
        _ = try store.saveSkillFiles(files: ["SKILL.md": iterated])

        _ = IOSBuiltinSkills.installIfMissing(into: store)
        XCTAssertEqual(try store.readSkillMarkdown(dirName: "skill-creator"), iterated)
    }

    func testSkillImportFromWorkspaceAndUseSkill() async throws {
        let root = tempRoot()
        let skillStore = IOSSkillFileStore(baseDirectory: root)
        let defaults = UserDefaults(suiteName: "skill-import-\(UUID().uuidString)")!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let workspace = IOSWorkspaceStore(
            baseDirectory: tempRoot().appendingPathComponent("workspace", isDirectory: true)
        )
        let mcpDefaults = UserDefaults(suiteName: "mcp-\(UUID().uuidString)")!
        let mcpStore = IOSMcpConfigStore(userDefaults: mcpDefaults)
        let mcpManager = IOSMcpManager(sharedSettings: settings, configStore: mcpStore)

        let markdown = """
        ---
        name: "demo-skill"
        description: "Use when testing skill import."
        ---

        # Demo
        Do the demo thing.
        """
        let writeInput = try JSONSerialization.data(
            withJSONObject: [
                "path": "/workspace/skills/demo-skill/SKILL.md",
                "content": markdown,
                "overwrite": true,
            ] as [String: Any],
            options: []
        )
        let writeResult = await workspace.executeTool(
            toolName: "workspace_file_write",
            input: String(data: writeInput, encoding: .utf8) ?? "{}"
        )
        XCTAssertTrue(writeResult.contains(#""ok":true"#), writeResult)

        let service = IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: workspace,
            mcpConfigStore: mcpStore,
            mcpManager: mcpManager
        )

        let prepared = try service.prepareSkillImport(
            arguments: #"{"workspace_path":"/workspace/skills/demo-skill/SKILL.md"}"#
        )
        let imported = try service.applyPreparedSkillImport(prepared)
        XCTAssertTrue(imported.contains(#""success":true"#), imported)
        XCTAssertTrue(imported.contains("demo-skill"), imported)
        XCTAssertTrue(settings.isSkillEnabled("demo-skill"))

        let listed = await service.execute(toolName: "skills_list", arguments: "{}")
        XCTAssertTrue(listed.contains("demo-skill"), listed)

        let used = await service.execute(
            toolName: "use_skill",
            arguments: #"{"name":"demo-skill"}"#
        )
        XCTAssertTrue(used.contains("AmberAgent Mobile Runtime"), used)
        XCTAssertTrue(used.contains("Do the demo thing."), used)
    }

    func testSkillImportPreviewApproveApplyRollbackRestoresCompletePackageAndEnableState() async throws {
        let skillStore = IOSSkillFileStore(baseDirectory: tempRoot())
        let defaults = isolatedDefaults()
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let workspace = IOSWorkspaceStore(
            baseDirectory: tempRoot().appendingPathComponent("workspace", isDirectory: true)
        )
        let skillName = "evolving-skill"
        let baseMarkdown = """
        ---
        name: evolving-skill
        description: Base package before self evolution.
        ---

        # Base
        """
        let candidateMarkdown = """
        ---
        name: evolving-skill
        description: Candidate package after self evolution.
        ---

        # Candidate
        """
        _ = try skillStore.saveSkillFiles(files: [
            "SKILL.md": baseMarkdown,
            "references/base.txt": "base sibling\n",
        ])
        settings.setSkillEnabled(name: skillName, enabled: false)
        try await writeWorkspaceText(
            candidateMarkdown,
            path: "/workspace/skills/evolving-skill/SKILL.md",
            workspace: workspace
        )
        try await writeWorkspaceText(
            "candidate sibling\n",
            path: "/workspace/skills/evolving-skill/references/candidate.txt",
            workspace: workspace
        )

        let mcpStore = IOSMcpConfigStore(userDefaults: isolatedDefaults())
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: settings,
            localToolExecutor: nil,
            searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore),
            skillFileStore: skillStore,
            workspaceStore: workspace,
            mcpConfigStore: mcpStore
        )
        let arguments = #"{"workspace_path":"/workspace/skills/evolving-skill"}"#
        let toolCall = UIMessagePart.Tool(
            toolCallId: "skill-import-contract-\(UUID().uuidString)",
            toolName: "skill_import",
            input: arguments,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let pending = makeSkillImportPending(toolCall: toolCall)

        let globalKey = "app.amber.ios.globalAutoApprove"
        let highRiskKey = "app.amber.ios.highRiskAutoApprove"
        let standardDefaults = UserDefaults.standard
        let previousGlobal = standardDefaults.object(forKey: globalKey)
        let previousHighRisk = standardDefaults.object(forKey: highRiskKey)
        defer {
            restore(previousGlobal, forKey: globalKey, in: standardDefaults)
            restore(previousHighRisk, forKey: highRiskKey, in: standardDefaults)
        }
        standardDefaults.set(true, forKey: globalKey)
        standardDefaults.set(false, forKey: highRiskKey)

        let previewResult = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: pending
        )
        guard case .waitingForApproval(.mcp(let request)) = previewResult,
              let preview = request.skillImportPreview else {
            return XCTFail("skill_import must pause unless high-risk auto-approve is on")
        }
        XCTAssertEqual(preview.skillName, skillName)
        XCTAssertEqual(preview.mutationKind, .update)
        XCTAssertEqual(
            Set(preview.changedFiles.map(\.path)),
            Set(["SKILL.md", "references/base.txt", "references/candidate.txt"])
        )
        XCTAssertEqual(try skillStore.readSkillMarkdown(dirName: skillName), baseMarkdown)
        XCTAssertEqual(
            try String(
                contentsOf: skillStore.resolveSkillFile(
                    name: skillName,
                    relativePath: "references/base.txt"
                ),
                encoding: .utf8
            ),
            "base sibling\n"
        )
        XCTAssertFalse(settings.isSkillEnabled(skillName))
        XCTAssertFalse(try skillStore.rollbackAvailability(name: skillName).canRollback)

        let prepared = try XCTUnwrap(
            runtime.takePreparedSkillImportForApproval(toolCallId: toolCall.toolCallId)
        )
        XCTAssertEqual(prepared.preview.candidateHash, preview.candidateHash)
        _ = await runtime.finishMcpApproval(
            pending: pending,
            allow: true,
            preparedSkillImport: prepared
        )

        XCTAssertEqual(try skillStore.readSkillMarkdown(dirName: skillName), candidateMarkdown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try skillStore.resolveSkillFile(
            name: skillName,
            relativePath: "references/base.txt"
        ).path))
        XCTAssertEqual(
            try String(
                contentsOf: skillStore.resolveSkillFile(
                    name: skillName,
                    relativePath: "references/candidate.txt"
                ),
                encoding: .utf8
            ),
            "candidate sibling\n"
        )
        XCTAssertFalse(settings.isSkillEnabled(skillName), "an update keeps the prior enable state")
        guard case .available(let manifest) = try skillStore.rollbackAvailability(name: skillName) else {
            return XCTFail("approved import must publish one rollback slot")
        }
        XCTAssertEqual(manifest.kind, .update)
        XCTAssertFalse(manifest.enabledBefore)

        settings.setSkillEnabled(name: skillName, enabled: true)
        let rollback = try skillStore.rollbackSkillPackage(
            name: skillName,
            expectedManifest: manifest
        )
        settings.setSkillEnabled(
            name: rollback.manifest.name,
            enabled: rollback.manifest.enabledBefore
        )

        XCTAssertEqual(try skillStore.readSkillMarkdown(dirName: skillName), baseMarkdown)
        XCTAssertEqual(
            try String(
                contentsOf: skillStore.resolveSkillFile(
                    name: skillName,
                    relativePath: "references/base.txt"
                ),
                encoding: .utf8
            ),
            "base sibling\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: try skillStore.resolveSkillFile(
            name: skillName,
            relativePath: "references/candidate.txt"
        ).path))
        XCTAssertFalse(settings.isSkillEnabled(skillName))
        XCTAssertFalse(try skillStore.rollbackAvailability(name: skillName).canRollback)
    }

    func testSkillImportHighRiskAutoApproveAppliesWithoutCard() async throws {
        let skillStore = IOSSkillFileStore(baseDirectory: tempRoot())
        let defaults = isolatedDefaults()
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let workspace = IOSWorkspaceStore(
            baseDirectory: tempRoot().appendingPathComponent("workspace", isDirectory: true)
        )
        let markdown = """
        ---
        name: "auto-skill"
        description: "Use when testing high-risk auto import."
        ---

        # Auto
        """
        try await writeWorkspaceText(
            markdown,
            path: "/workspace/skills/auto-skill/SKILL.md",
            workspace: workspace
        )
        let mcpStore = IOSMcpConfigStore(userDefaults: isolatedDefaults())
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: settings,
            localToolExecutor: nil,
            searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore),
            skillFileStore: skillStore,
            workspaceStore: workspace,
            mcpConfigStore: mcpStore
        )
        let toolCall = UIMessagePart.Tool(
            toolCallId: "skill-import-auto-\(UUID().uuidString)",
            toolName: "skill_import",
            input: #"{"workspace_path":"/workspace/skills/auto-skill"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let pending = makeSkillImportPending(toolCall: toolCall)
        await withAutoApproveFlags(global: false, highRisk: true) {
            let result = await runtime.execute(
                ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
                context: pending
            )
            guard case .completed = result else {
                return XCTFail("high-risk auto-approve must apply skill_import without a card, got \(result)")
            }
        }
        XCTAssertEqual(try skillStore.readSkillMarkdown(dirName: "auto-skill"), markdown)
        XCTAssertTrue(settings.isSkillEnabled("auto-skill"))
    }

    func testBackgroundSkillImportAppliesWhenHighRiskAutoApproveEnabled() async throws {
        let skillStore = IOSSkillFileStore(baseDirectory: tempRoot())
        let defaults = isolatedDefaults()
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let workspace = IOSWorkspaceStore(
            baseDirectory: tempRoot().appendingPathComponent("workspace", isDirectory: true)
        )
        let markdown = """
        ---
        name: "bg-skill"
        description: "Use when testing background high-risk import."
        ---

        # Background
        """
        try await writeWorkspaceText(
            markdown,
            path: "/workspace/skills/bg-skill/SKILL.md",
            workspace: workspace
        )
        let mcpStore = IOSMcpConfigStore(userDefaults: isolatedDefaults())
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: settings,
            localToolExecutor: nil,
            searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore),
            skillFileStore: skillStore,
            workspaceStore: workspace,
            mcpConfigStore: mcpStore
        )
        let importTool = try XCTUnwrap(ToolKt.iosToolDeclaration(name: "skill_import"))
        let pending = makeSkillImportPending(
            toolCall: UIMessagePart.Tool(
                toolCallId: "bg-skill-import",
                toolName: "skill_import",
                input: "{}",
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
        )
        let params = TextGenerationParams(
            model: pending.params.model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [importTool],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let executors = runtime.backgroundToolExecutors(
            providerSetting: pending.providerSetting,
            params: params,
            runId: "run-bg-skill-import"
        )
        let executor = try XCTUnwrap(executors["skill_import"])
        await withAutoApproveFlags(global: false, highRisk: true) {
            let outcome = await UncheckedSkillToolExecutorBox(executor).execute(
                name: "skill_import",
                arguments: #"{"workspace_path":"/workspace/skills/bg-skill"}"#,
                isUserInitiated: false
            )
            guard case .filled(let output) = outcome else {
                return XCTFail("high-risk auto-approve must apply background skill_import, got \(outcome)")
            }
            XCTAssertTrue(output.contains(#""success":true"#), output)
        }
        XCTAssertEqual(try skillStore.readSkillMarkdown(dirName: "bg-skill"), markdown)
        XCTAssertTrue(settings.isSkillEnabled("bg-skill"))
    }

    func testSkillImportRejectsStaleBaseOrCandidateWithoutMutation() async throws {
        do {
            let skillStore = IOSSkillFileStore(baseDirectory: tempRoot())
            let settings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
            let workspace = IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("stale-base-workspace", isDirectory: true)
            )
            _ = try skillStore.saveSkillFiles(files: [
                "SKILL.md": skillMarkdown(name: "stale-base", version: "base"),
                "references/state.txt": "base\n",
            ])
            settings.setSkillEnabled(name: "stale-base", enabled: false)
            try await writeWorkspaceText(
                skillMarkdown(name: "stale-base", version: "candidate"),
                path: "/workspace/skills/stale-base/SKILL.md",
                workspace: workspace
            )
            let service = makeSkillService(
                skillStore: skillStore,
                settings: settings,
                workspace: workspace
            )
            let prepared = try service.prepareSkillImport(
                arguments: #"{"workspace_path":"/workspace/skills/stale-base"}"#
            )

            let manualMarkdown = skillMarkdown(name: "stale-base", version: "manual-live-change")
            _ = try skillStore.saveSkillFiles(files: [
                "SKILL.md": manualMarkdown,
                "references/state.txt": "manual\n",
            ])
            let rollbackBeforeApply = try skillStore.rollbackAvailability(name: "stale-base")
            let result = try service.applyPreparedSkillImport(prepared)
            XCTAssertEqual(try jsonObject(result)["code"] as? String, "stale_base")
            XCTAssertEqual(try skillStore.readSkillMarkdown(dirName: "stale-base"), manualMarkdown)
            XCTAssertEqual(
                try String(
                    contentsOf: skillStore.resolveSkillFile(
                        name: "stale-base",
                        relativePath: "references/state.txt"
                    ),
                    encoding: .utf8
                ),
                "manual\n"
            )
            XCTAssertEqual(
                try skillStore.rollbackAvailability(name: "stale-base"),
                rollbackBeforeApply
            )
            XCTAssertFalse(settings.isSkillEnabled("stale-base"))
        }

        do {
            let skillStore = IOSSkillFileStore(baseDirectory: tempRoot())
            let settings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
            let workspace = IOSWorkspaceStore(
                baseDirectory: tempRoot().appendingPathComponent("stale-candidate-workspace", isDirectory: true)
            )
            let baseMarkdown = skillMarkdown(name: "stale-candidate", version: "base")
            _ = try skillStore.saveSkillFiles(files: [
                "SKILL.md": baseMarkdown,
                "references/state.txt": "base\n",
            ])
            settings.setSkillEnabled(name: "stale-candidate", enabled: true)
            try await writeWorkspaceText(
                skillMarkdown(name: "stale-candidate", version: "candidate-one"),
                path: "/workspace/skills/stale-candidate/SKILL.md",
                workspace: workspace
            )
            let service = makeSkillService(
                skillStore: skillStore,
                settings: settings,
                workspace: workspace
            )
            let prepared = try service.prepareSkillImport(
                arguments: #"{"workspace_path":"/workspace/skills/stale-candidate"}"#
            )
            let rollbackBeforeApply = try skillStore.rollbackAvailability(name: "stale-candidate")

            try await writeWorkspaceText(
                skillMarkdown(name: "stale-candidate", version: "candidate-two"),
                path: "/workspace/skills/stale-candidate/SKILL.md",
                workspace: workspace
            )
            let result = try service.applyPreparedSkillImport(prepared)
            XCTAssertEqual(try jsonObject(result)["code"] as? String, "stale_candidate")
            XCTAssertEqual(try skillStore.readSkillMarkdown(dirName: "stale-candidate"), baseMarkdown)
            XCTAssertEqual(
                try String(
                    contentsOf: skillStore.resolveSkillFile(
                        name: "stale-candidate",
                        relativePath: "references/state.txt"
                    ),
                    encoding: .utf8
                ),
                "base\n"
            )
            XCTAssertEqual(
                try skillStore.rollbackAvailability(name: "stale-candidate"),
                rollbackBeforeApply
            )
            XCTAssertTrue(settings.isSkillEnabled("stale-candidate"))
        }
    }

    func testSoulImportPrepareApplyStaleAndRollback() async throws {
        let settings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        settings.setAgentSoulMarkdown("# old soul\nbase")
        let workspace = IOSWorkspaceStore(
            baseDirectory: tempRoot().appendingPathComponent("soul-ws", isDirectory: true)
        )
        let previous = IOSSoulPreviousStore(
            userDefaults: isolatedDefaults(),
            key: "soul-prev-\(UUID().uuidString)"
        )
        let service = IOSSoulService(
            workspaceStore: workspace,
            sharedSettings: settings,
            previousStore: previous
        )
        try await writeWorkspaceText(
            "# new soul\ncandidate",
            path: "/workspace/SOUL.md",
            workspace: workspace
        )

        let prepared = try service.prepareImport()
        XCTAssertEqual(settings.agentRuntime.agentSoulMarkdown, "# old soul\nbase")
        XCTAssertNil(previous.load())

        try await writeWorkspaceText(
            "# changed candidate\n",
            path: "/workspace/SOUL.md",
            workspace: workspace
        )
        let staleCandidate = try service.applyPreparedImport(prepared)
        XCTAssertEqual(try jsonObject(staleCandidate)["code"] as? String, "stale_candidate")
        XCTAssertEqual(settings.agentRuntime.agentSoulMarkdown, "# old soul\nbase")

        try await writeWorkspaceText(
            "# new soul\ncandidate",
            path: "/workspace/SOUL.md",
            workspace: workspace
        )
        settings.setAgentSoulMarkdown("# manual change")
        let staleBase = try service.applyPreparedImport(prepared)
        XCTAssertEqual(try jsonObject(staleBase)["code"] as? String, "stale_base")
        XCTAssertEqual(settings.agentRuntime.agentSoulMarkdown, "# manual change")

        settings.setAgentSoulMarkdown("# old soul\nbase")
        let applied = try service.applyPreparedImport(prepared)
        XCTAssertEqual(try jsonObject(applied)["ok"] as? Bool, true)
        XCTAssertEqual(settings.agentRuntime.agentSoulMarkdown, "# new soul\ncandidate")
        XCTAssertEqual(previous.load()?.previousMarkdown, "# old soul\nbase")

        try service.rollbackPrevious()
        XCTAssertEqual(settings.agentRuntime.agentSoulMarkdown, "# old soul\nbase")
        XCTAssertNil(previous.load())
    }

    private func writeWorkspaceText(
        _ content: String,
        path: String,
        workspace: IOSWorkspaceStore
    ) async throws {
        let input = try JSONSerialization.data(
            withJSONObject: [
                "path": path,
                "content": content,
                "overwrite": true,
            ] as [String: Any],
            options: []
        )
        let result = await workspace.executeTool(
            toolName: "workspace_file_write",
            input: String(data: input, encoding: .utf8) ?? "{}"
        )
        XCTAssertTrue(result.contains(#""ok":true"#), result)
    }

    private func makeSkillService(
        skillStore: IOSSkillFileStore,
        settings: IOSSharedSettingsStore,
        workspace: IOSWorkspaceStore
    ) -> IOSSkillMcpToolService {
        let mcpStore = IOSMcpConfigStore(userDefaults: isolatedDefaults())
        return IOSSkillMcpToolService(
            skillStore: skillStore,
            sharedSettings: settings,
            workspaceStore: workspace,
            mcpConfigStore: mcpStore,
            mcpManager: IOSMcpManager(sharedSettings: settings, configStore: mcpStore)
        )
    }

    private func makeSkillImportPending(toolCall: UIMessagePart.Tool) -> ChatPendingToolApproval {
        let model = Model(
            modelId: "skill-import-contract",
            displayName: "Skill Import Contract",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let params = TextGenerationParams(
            model: model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let assistant = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolCall],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        return ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: IOSCouncilRoomRunner.makeProviderSetting(
                baseUrl: "https://example.com/v1",
                apiKey: "test-key"
            ),
            params: params,
            runId: "run-skill-import-contract",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            baseMessages: [assistant]
        )
    }

    private func skillMarkdown(name: String, version: String) -> String {
        """
        ---
        name: \(name)
        description: \(version) package.
        ---

        # \(version)
        """
    }

    func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func withAutoApproveFlags(
        global: Bool,
        highRisk: Bool,
        _ body: () async throws -> Void
    ) async rethrows {
        let globalKey = "app.amber.ios.globalAutoApprove"
        let highRiskKey = "app.amber.ios.highRiskAutoApprove"
        let standardDefaults = UserDefaults.standard
        let previousGlobal = standardDefaults.object(forKey: globalKey)
        let previousHighRisk = standardDefaults.object(forKey: highRiskKey)
        defer {
            restore(previousGlobal, forKey: globalKey, in: standardDefaults)
            restore(previousHighRisk, forKey: highRiskKey, in: standardDefaults)
        }
        standardDefaults.set(global, forKey: globalKey)
        standardDefaults.set(highRisk, forKey: highRiskKey)
        try await body()
    }

    func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-skill-mcp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "IOSSkillMcpToolsTests-\(UUID().uuidString)")!
    }
}

private final class UncheckedSkillToolExecutorBox: @unchecked Sendable {
    private let base: any IOSToolExecutor

    init(_ base: any IOSToolExecutor) {
        self.base = base
    }

    func execute(
        name: String,
        arguments: String,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        await base.execute(
            name: name,
            arguments: arguments,
            isUserInitiated: isUserInitiated
        )
    }
}
