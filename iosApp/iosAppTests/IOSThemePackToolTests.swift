import XCTest
import SwiftUI
import UIKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSThemePackToolTests: XCTestCase {
    private var runtime: AmberThemeRuntime { .shared }
    private var savedPaper: AmberThemeRuntime.Paper!
    private var savedAccent: UInt32 = 0
    private var savedInk: UInt32 = 0
    private var savedCanvas: AmberCanvasStyle = .flat
    private var savedBrand: AmberBrandMarkStyle = .systemWordmark
    private var savedShortcut: AmberShortcutIconStyle = .phosphorFill
    private var savedChrome: AmberChromeTypeface = .system
    private var savedCanvasScope: AmberCanvasScope = .homeOnly
    private var savedBubble: AmberBubbleChrome = .standard
    private var savedGlass: AmberGlassChrome = .standard
    private var savedEmpty: AmberEmptyArtStyle = .none
    private var savedSettingsChrome = false
    private var savedLaunch: AmberLaunchBrandStyle = .none
    private var savedAsset: AmberThemeAssetMode = .builtinOnly
    private var savedImmersive: AmberImmersivePolicy = .hidden
    private var savedDesign: AmberThemeDesign?
    private var savedThemeID: String?
    private var savedThemeName: String?
    private var libraryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        savedPaper = runtime.paper
        savedAccent = runtime.accentHex
        savedInk = runtime.accentInkHex
        savedCanvas = runtime.canvasStyle
        savedBrand = runtime.brandMarkStyle
        savedShortcut = runtime.shortcutIconStyle
        savedChrome = runtime.chromeTypeface
        savedCanvasScope = runtime.canvasScope
        savedBubble = runtime.bubbleChrome
        savedGlass = runtime.glassChrome
        savedEmpty = runtime.emptyArt
        savedSettingsChrome = runtime.settingsChrome
        savedLaunch = runtime.launchBrand
        savedAsset = runtime.assetMode
        savedImmersive = runtime.immersivePolicy
        savedDesign = runtime.design
        savedThemeID = runtime.selectedThemeID
        savedThemeName = runtime.selectedThemeName
        libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-pack-tool-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        runtime.discardTryOn()
        runtime.paper = savedPaper
        runtime.accentHex = savedAccent
        runtime.accentInkHex = savedInk
        runtime.canvasStyle = savedCanvas
        runtime.brandMarkStyle = savedBrand
        runtime.shortcutIconStyle = savedShortcut
        runtime.chromeTypeface = savedChrome
        runtime.canvasScope = savedCanvasScope
        runtime.bubbleChrome = savedBubble
        runtime.glassChrome = savedGlass
        runtime.emptyArt = savedEmpty
        runtime.settingsChrome = savedSettingsChrome
        runtime.launchBrand = savedLaunch
        runtime.assetMode = savedAsset
        runtime.immersivePolicy = savedImmersive
        runtime.design = savedDesign
        runtime.rememberThemeIdentity(id: savedThemeID, displayName: savedThemeName)
        try? FileManager.default.removeItem(at: libraryRoot)
        try await super.tearDown()
    }

    private func makeLibrary() -> AmberThemePackLibrary {
        AmberThemePackLibrary(
            fileURL: libraryRoot.appendingPathComponent("library.json")
        )
    }

    private func makeService() -> IOSThemePackToolService {
        IOSThemePackToolService(runtime: runtime, library: makeLibrary())
    }

    private func makeRuntime() -> ChatToolRuntime {
        ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(
                userDefaults: UserDefaults(suiteName: "IOSThemePackToolTests-\(UUID().uuidString)")!
            ),
            localToolExecutor: nil,
            searchTransport: ThemePackCountingSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
    }

    private func makeParams(toolNames: [String]) -> TextGenerationParams {
        let model = Model(
            modelId: "test-model",
            displayName: "test-model",
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
        return TextGenerationParams(
            model: model,
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: nil,
            tools: ToolKt.iosToolDeclarations(names: toolNames),
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    private func makeProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "theme-pack-test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    private func importJSON(
        id: String = "rain-bookstore",
        displayName: String = "雨天书店",
        paper: String = "paper",
        accent: AmberAccentOption = .terracotta,
        canvasStyle: String = "dotGrid",
        extra: [String: Any] = [:]
    ) -> String {
        var body: [String: Any] = [
            "id": id,
            "display_name": displayName,
            "paper": paper,
            "accent_hex": AmberThemePackTransfer.hexString(accent.accentHex),
            "ink_hex": AmberThemePackTransfer.hexString(accent.inkHex),
            "canvas_style": canvasStyle,
            "brand_mark": "serifWordmark",
            "shortcut_icon_style": "phosphorFill",
            "chrome_typeface": "serif",
        ]
        extra.forEach { body[$0.key] = $0.value }
        return IOSWorkspaceStore.json(body)
    }

    private func parseJSON(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("输出必须是可解析 JSON，实际: \(text.prefix(200))")
            return [:]
        }
        return object
    }

    func testStatusReportsCurrentRecipeAndAllowedSlots() {
        runtime.apply(AmberThemePack.builtins.first { $0.id == "notion-blue" }!)
        let payload = parseJSON(makeService().status())
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual((payload["contrast_min"] as? NSNumber)?.doubleValue, 3.0)
        let current = payload["current"] as? [String: Any]
        XCTAssertEqual(current?["paper"] as? String, "notion")
        XCTAssertTrue(current?["design"] is NSNull)
        XCTAssertTrue(payload["try_on"] is NSNull)
        let allowed = payload["allowed"] as? [String: Any]
        let papers = allowed?["paper"] as? [String]
        XCTAssertEqual(papers, ["paper", "neutral", "white", "pi", "notion"])
        XCTAssertFalse(papers?.contains("garnet") == true)
        let design = allowed?["design"] as? [String: Any]
        XCTAssertEqual(design?["required"] as? [String], ["light", "dark", "patterns"])
        XCTAssertNotNil(design?["light"] as? [String: Any])
        XCTAssertNotNil(design?["dark"] as? [String: Any])
        let patterns = design?["patterns"] as? [String: Any]
        XCTAssertEqual((patterns?["max_items"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(patterns?["kind"] as? [String], ["dots", "grid", "diagonal", "crosses", "waves", "rings"])
        let builtins = payload["builtin_ids"] as? [String]
        XCTAssertEqual(builtins, ["sit-terracotta", "pi-steel", "notion-blue"])
        let rules = payload["rules"] as? [String] ?? []
        XCTAssertTrue(rules.contains { $0.contains("套用") }, "rules: \(rules)")
    }

    func testPrepareTryOnDoesNotPersistUntilCommit() throws {
        runtime.apply(AmberThemePack.builtins.first { $0.id == "notion-blue" }!)
        let paperKey = "app.amber.ios.theme.paper"
        let accentKey = "app.amber.ios.theme.accentHex"
        let persistedPaper = UserDefaults.standard.string(forKey: paperKey)
        let persistedAccent = UserDefaults.standard.object(forKey: accentKey) as? Int
        let identityKey = "app.amber.ios.theme.selectedThemeID"
        let persistedID = UserDefaults.standard.string(forKey: identityKey)
        let library = makeLibrary()
        let service = IOSThemePackToolService(runtime: runtime, library: library)

        let document = try service.prepareImport(argumentsJSON: importJSON())
        XCTAssertEqual(document.id, "rain-bookstore")
        XCTAssertTrue(runtime.isTryOnActive)
        XCTAssertEqual(runtime.paper, .paper)
        XCTAssertEqual(UserDefaults.standard.string(forKey: paperKey), persistedPaper)
        XCTAssertEqual(UserDefaults.standard.object(forKey: accentKey) as? Int, persistedAccent)
        XCTAssertEqual(UserDefaults.standard.string(forKey: identityKey), persistedID)

        let status = parseJSON(service.status())
        let tryOn = status["try_on"] as? [String: Any]
        XCTAssertEqual(tryOn?["id"] as? String, "rain-bookstore")
        let current = status["current"] as? [String: Any]
        XCTAssertEqual(current?["paper"] as? String, "notion")

        let committed = parseJSON(try service.commitPreparedImport())
        XCTAssertEqual(committed["ok"] as? Bool, true)
        XCTAssertEqual(committed["installed"] as? Bool, true)
        XCTAssertFalse(runtime.isTryOnActive)
        XCTAssertEqual(UserDefaults.standard.string(forKey: paperKey), "paper")
        XCTAssertEqual(UserDefaults.standard.string(forKey: identityKey), document.id)
        XCTAssertTrue(library.contains(id: "rain-bookstore"))
        XCTAssertTrue(parseJSON(service.status())["try_on"] is NSNull)
    }

    func testDiscardRestoresBaselineWithoutLibraryWrite() throws {
        runtime.apply(AmberThemePack.builtins.first { $0.id == "notion-blue" }!)
        let library = makeLibrary()
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        _ = try service.prepareImport(argumentsJSON: importJSON())
        service.discardPreparedImport()
        XCTAssertFalse(runtime.isTryOnActive)
        XCTAssertEqual(runtime.paper, .notion)
        XCTAssertTrue(library.installed.isEmpty)
    }

    func testStaleServiceCannotCommitOrDiscardTheCurrentTryOn() throws {
        runtime.apply(AmberThemePack.builtins.first { $0.id == "notion-blue" }!)
        let library = makeLibrary()
        let serviceA = IOSThemePackToolService(runtime: runtime, library: library)
        let serviceB = IOSThemePackToolService(runtime: runtime, library: library)

        _ = try serviceA.prepareImport(
            argumentsJSON: importJSON(id: "theme-a", displayName: "主题 A", accent: .terracotta)
        )
        _ = try serviceB.prepareImport(
            argumentsJSON: importJSON(id: "theme-b", displayName: "主题 B", accent: .mistBlue, canvasStyle: "lineGrid")
        )
        XCTAssertEqual(runtime.tryOnSession?.candidate.id, "theme-b")

        XCTAssertThrowsError(try serviceA.commitPreparedImport()) { error in
            XCTAssertEqual(error as? AmberThemeTryOnError, .replacedTryOn)
        }
        serviceA.discardPreparedImport()
        XCTAssertEqual(runtime.tryOnSession?.candidate.id, "theme-b")
        XCTAssertFalse(library.contains(id: "theme-a"))

        let committed = parseJSON(try serviceB.commitPreparedImport())
        XCTAssertEqual(committed["ok"] as? Bool, true)
        XCTAssertEqual(committed["id"] as? String, "theme-b")
        XCTAssertFalse(runtime.isTryOnActive)
        XCTAssertTrue(library.contains(id: "theme-b"))
        XCTAssertEqual(runtime.accentHex, AmberAccentOption.mistBlue.accentHex)
    }

    func testCommitWriteFailureRestoresBaselineAndClearsTryOn() throws {
        runtime.apply(AmberThemePack.builtins.first { $0.id == "notion-blue" }!)
        let baseline = AmberThemePackTransfer.document(from: runtime)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-pack-tool-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let blocker = root.appendingPathComponent("no-such-dir")
        try Data("not-a-dir".utf8).write(to: blocker)
        let library = AmberThemePackLibrary(
            fileURL: blocker.appendingPathComponent("library.json")
        )
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        _ = try service.prepareImport(argumentsJSON: importJSON(id: "write-failure"))
        XCTAssertTrue(runtime.isTryOnActive)

        XCTAssertThrowsError(try service.commitPreparedImport())
        XCTAssertFalse(runtime.isTryOnActive)
        XCTAssertNil(runtime.tryOnSession)
        XCTAssertTrue(baseline.matches(runtime: runtime))
        XCTAssertTrue(library.installed.isEmpty)
    }

    func testImportRejectsBuiltinIdWithoutTryOn() {
        let service = makeService()
        runtime.apply(AmberThemePack.builtins.first { $0.id == "notion-blue" }!)
        let output = service.execute(
            toolName: "theme_pack_import",
            argumentsJSON: importJSON(id: "sit-terracotta", displayName: "点阵")
        )
        let payload = parseJSON(output)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertTrue((payload["reason"] as? String ?? "").contains("内置"))
        XCTAssertFalse(runtime.isTryOnActive)
        XCTAssertEqual(runtime.paper, .notion)
    }

    func testImportRejectsImmersivePaperAndLowContrast() {
        let service = makeService()
        runtime.apply(AmberThemePack.builtins.first { $0.id == "notion-blue" }!)

        let immersive = parseJSON(service.execute(
            toolName: "theme_pack_import",
            argumentsJSON: importJSON(paper: "garnet")
        ))
        XCTAssertEqual(immersive["ok"] as? Bool, false)
        XCTAssertFalse(runtime.isTryOnActive)

        let contrast = parseJSON(service.execute(
            toolName: "theme_pack_import",
            argumentsJSON: importJSON(extra: [
                "accent_hex": "0x808080",
                "ink_hex": "0x909090",
            ])
        ))
        XCTAssertEqual(contrast["ok"] as? Bool, false)
        XCTAssertTrue((contrast["reason"] as? String ?? "").contains("对比度"))
        XCTAssertFalse(runtime.isTryOnActive)
    }

    func testDefaultCanvasScopeIsShell() throws {
        let service = makeService()
        let document = try service.prepareImport(argumentsJSON: importJSON())
        XCTAssertEqual(document.canvasScope, AmberCanvasScope.shell.rawValue)
        service.discardPreparedImport()
    }

    private func editableTheme() throws -> AmberThemePackDocument {
        var document = try AmberThemePackTransfer.document(fromToolArguments: parseJSON(importJSON()))
        document.canvasScope = "appWide"
        document.design = AmberThemeDesign(
            light: .init(background: "#FFFFFF", surface: "#F8F8F8", foreground: "#111111", mutedForeground: "#666666", border: "#CCCCCC"),
            dark: .init(background: "#111111", surface: "#222222", foreground: "#FFFFFF", mutedForeground: "#AAAAAA", border: "#444444"),
            gradient: .init(colors: ["#FFFFFF", "#EEEEEE"], darkColors: ["#111111", "#222222"], angle: 45),
            patterns: [.init(kind: "dots", color: "#888888", opacity: 0.1, spacing: 24, size: 1)],
            components: .init(cardRadius: 20, borderWidth: 1, brandText: "书店")
        )
        return document
    }

    func testPatchPreservesRecipeAndReplacesTheSameLibraryEntryOnlyAfterCommit() throws {
        runtime.apply(AmberThemePack.builtins[0])
        let library = makeLibrary()
        let original = try editableTheme()
        try library.upsert(original)
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        let status = parseJSON(service.execute(toolName: "theme_pack_status", argumentsJSON: #"{"id":"rain-bookstore"}"#))
        XCTAssertEqual((status["base"] as? [String: Any])?["id"] as? String, original.id)

        let candidate = try service.prepareImport(argumentsJSON: ##"{"base_id":"rain-bookstore","design":{"light":{"border":"#BBBBBB"},"components":{"cardRadius":12}}}"##)
        var expected = original
        expected.design?.light?.border = "#BBBBBB"
        expected.design?.components?.cardRadius = 12
        XCTAssertEqual(candidate, expected, "未提供的深色配方、渐变、纹理、品牌和槽位必须原样保留")
        XCTAssertEqual(library.installed, [original], "试穿不能提前覆盖原主题")
        let committed = parseJSON(try service.commitPreparedImport())
        XCTAssertEqual(committed["operation"] as? String, "updated")
        XCTAssertEqual(library.installed, [expected])
        XCTAssertEqual(makeLibrary().installed, [expected], "保存和重载仍只有原来的主题 id")
    }

    func testPatchCurrentUsesLatestTryOnAndDiscardRestoresOriginal() throws {
        let library = makeLibrary()
        let original = try editableTheme()
        try library.upsert(original)
        try runtime.apply(original)
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        _ = try service.prepareImport(argumentsJSON: #"{"base_id":"current","design":{"components":{"cardRadius":12}}}"#)
        let status = parseJSON(service.status())
        XCTAssertEqual((status["base"] as? [String: Any])?["id"] as? String, original.id)
        let second = try service.prepareImport(argumentsJSON: #"{"base_id":"current","design":{"components":{"brandText":"雨天"}}}"#)
        XCTAssertEqual(second.id, original.id)
        XCTAssertEqual(second.design?.components?.cardRadius, 12)
        XCTAssertEqual(second.design?.components?.brandText, "雨天")
        service.discardPreparedImport()
        XCTAssertTrue(original.matches(runtime: runtime))
        XCTAssertEqual(library.installed, [original])
    }

    func testLegacyScopeAndUneditedGradientStopsArePreserved() throws {
        let library = makeLibrary()
        var original = try editableTheme()
        original.canvasScope = nil
        try library.upsert(original)
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        let status = parseJSON(service.execute(toolName: "theme_pack_status", argumentsJSON: #"{"id":"rain-bookstore"}"#))
        XCTAssertEqual((status["base"] as? [String: Any])?["canvas_scope"] as? String, "homeOnly")
        let candidate = try service.prepareImport(argumentsJSON: ##"{"base_id":"rain-bookstore","design":{"gradient":{"colors":["#FAFAFA","#EEEEEE","#FFFFFF"]}}}"##)
        var expected = original
        expected.design?.gradient?.colors = ["#FAFAFA", "#EEEEEE", "#FFFFFF"]
        XCTAssertEqual(candidate, expected, "只替换浅色渐变数组，保留暗色渐变、方向和旧配方缺省范围")
    }

    func testPatchNullClearsOnlyRequestedOptionalFieldsAndArraysReplace() throws {
        let library = makeLibrary()
        let original = try editableTheme()
        try library.upsert(original)
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        let candidate = try service.prepareImport(argumentsJSON: #"{"base_id":"rain-bookstore","design":{"gradient":null,"patterns":[],"components":{"borderWidth":null}}}"#)
        var expected = original
        expected.design?.gradient = nil
        expected.design?.patterns = []
        expected.design?.components?.borderWidth = nil
        XCTAssertEqual(candidate, expected)
    }

    func testInvalidPatchCannotChangeIdentityOrReplaceAnActivePreview() throws {
        let library = makeLibrary()
        let original = try editableTheme()
        try library.upsert(original)
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        let visible = try service.prepareImport(argumentsJSON: importJSON(id: "preview"))
        let sessionID = runtime.tryOnSession?.id
        for json in [
            #"{"base_id":"missing","display_name":"丢失"}"#,
            #"{"base_id":"rain-bookstore","id":"a-new-theme","display_name":"改名"}"#,
            #"{"base_id":"rain-bookstore","design":{"components":{"cardRaduis":12}}}"#,
            ##"{"base_id":"rain-bookstore","design":{"light":{"foreground":"#FFFFFF"}}}"##,
            #"{"base_id":"rain-bookstore","design":{"components":{"cardRadius":100}}}"#,
            #"{"base_id":"rain-bookstore","display_name":"  "}"#,
            #"{"base_id":"rain-bookstore"}"#,
        ] {
            XCTAssertThrowsError(try service.prepareImport(argumentsJSON: json), json)
            XCTAssertEqual(runtime.tryOnSession?.id, sessionID)
            XCTAssertEqual(runtime.tryOnSession?.candidate, visible)
            XCTAssertEqual(library.installed, [original])
        }
        let unknown = parseJSON(service.execute(toolName: "theme_pack_status", argumentsJSON: #"{"id":"missing"}"#))
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        let invalid = parseJSON(service.execute(toolName: "theme_pack_import", argumentsJSON: #"{"base_id":"missing","display_name":"丢失"}"#))
        XCTAssertEqual(invalid["ok"] as? Bool, false)
        XCTAssertEqual(runtime.tryOnSession?.id, sessionID, "失败的修改不能撤掉已经可见的试穿")
    }

    func testBuiltinPatchCreatesAnEditableCopyAndKeepsBuiltinUnchanged() throws {
        let builtin = AmberThemePack.builtins[0]
        let original = AmberThemePackTransfer.document(from: builtin)
        runtime.apply(builtin)
        let library = makeLibrary()
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        let candidate = try service.prepareImport(argumentsJSON: #"{"base_id":"current","canvas_style":"lineGrid"}"#)
        var expected = original
        expected.id = candidate.id
        expected.canvasStyle = "lineGrid"
        XCTAssertEqual(candidate, expected)
        XCTAssertFalse(AmberThemePackLibrary.isBuiltinId(candidate.id))
        _ = try service.commitPreparedImport()
        let updated = try service.prepareImport(argumentsJSON: #"{"base_id":"current","chrome_typeface":"rounded"}"#)
        XCTAssertEqual(updated.id, candidate.id)
        _ = try service.commitPreparedImport()
        XCTAssertEqual(library.installed.count, 1)
        XCTAssertEqual(AmberThemePackTransfer.document(from: builtin), original)
    }

    func testBuiltinComponentOnlyPatchPreservesBothModeColorsAndSurvivesReload() throws {
        let library = makeLibrary()
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        func colors() -> [UIColor] {
            let tokens: [Color] = [AmberTheme.background, AmberTheme.surface, AmberTheme.surface2,
                AmberTheme.foreground, AmberTheme.foreground2, AmberTheme.muted, AmberTheme.muted2,
                AmberTheme.border, AmberTheme.borderSoft, AmberTheme.section, AmberTheme.avatarIdle,
                AmberTheme.avatarIdleInk, AmberTheme.homeGlassShadowAmbient]
            return [UIUserInterfaceStyle.light, .dark].flatMap { style in
                tokens.map { UIColor($0).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)) }
            }
        }
        for builtin in AmberThemePack.builtins {
            runtime.apply(builtin)
            let before = colors()
            let candidate = try service.prepareImport(argumentsJSON: #"{"base_id":"current","design":{"components":{"cardRadius":12}}}"#)
            XCTAssertNil(candidate.design?.light)
            XCTAssertNil(candidate.design?.dark)
            XCTAssertEqual(candidate.design?.patterns, [])
            XCTAssertEqual(AmberTheme.homeCardRadius, 12)
            XCTAssertEqual(colors(), before, "只改圆角不能重新推导原有浅深色及首页次级颜色：\(builtin.id)")
            XCTAssertEqual(runtime.canvasStyle, builtin.canvasStyle)
            _ = try service.commitPreparedImport()
            let reloaded = try XCTUnwrap(makeLibrary().installed.first { $0.id == candidate.id })
            XCTAssertEqual(reloaded, candidate)
            try runtime.apply(reloaded)
            XCTAssertEqual(colors(), before)
            let updated = try service.prepareImport(argumentsJSON: #"{"base_id":"current","design":{"components":{"brandText":"自定义"}}}"#)
            XCTAssertEqual(updated.id, candidate.id)
            XCTAssertEqual(updated.design?.components?.cardRadius, 12)
            service.discardPreparedImport()
        }
    }

    func testToolsDeferredAndChineseSearchHit() throws {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(
                userDefaults: UserDefaults(suiteName: "IOSThemePackToolSearch-\(UUID().uuidString)")!
            ),
            localToolExecutor: IOSLocalToolExecutor(
                permissionStore: IOSPermissionStore(
                    userDefaults: UserDefaults(suiteName: "IOSThemePackToolPerm-\(UUID().uuidString)")!
                ),
                documentStore: DocumentAccessStore(),
                workspaceStore: IOSWorkspaceStore(
                    baseDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                )
            ),
            autoGenerateResponses: false
        )
        _ = viewModel.currentToolDeclarationNames()
        let bridge = try XCTUnwrap(viewModel.toolExposureBridgeForTesting())
        let full = Set(bridge.fullToolDeclarations().map(\.name))
        for name in IOSThemePackToolCatalog.toolNames {
            XCTAssertTrue(full.contains(name), "\(name) must be in bridge catalog")
            XCTAssertFalse(Set(bridge.visibleTools().map(\.name)).contains(name), "\(name) deferred")
        }
        let payload = bridge.executeToolSearch(argumentsJson: #"{"query":"主题","limit":12}"#)
        XCTAssertTrue(payload.contains("theme_pack_status"), payload)
        XCTAssertTrue(payload.contains("theme_pack_import"), payload)
    }

    func testThemeGenerationHandsStyleAndToolWorkflowToChat() throws {
        XCTAssertNil(IOSThemePackToolCatalog.generationPrompt(style: "  \n"))
        XCTAssertNil(IOSThemePackToolCatalog.generationPrompt(style: String(repeating: "色", count: 2_001)))
        let prompt = try XCTUnwrap(IOSThemePackToolCatalog.generationPrompt(style: "  雨天书店，墨绿色  "))
        XCTAssertTrue(prompt.hasSuffix("雨天书店，墨绿色"))
        XCTAssertTrue(prompt.contains("theme_pack_status"))
        XCTAssertTrue(prompt.contains("theme_pack_import"))
        let inbox = IOSDeepLinkInbox()
        let destination = try XCTUnwrap(inbox.preparePromptHandoff(prompt))
        let url = try XCTUnwrap(IOSAppDeepLink.url(for: destination))
        var delivered: IOSAppDeepLink.Destination?
        inbox.installHandler { delivered = IOSAppDeepLink.parse($0) }
        inbox.submit(url)
        XCTAssertEqual(delivered, destination)
        guard case .agentPrompt(let id) = try XCTUnwrap(delivered) else {
            return XCTFail("Generation must enter the existing agent chat flow")
        }
        XCTAssertEqual(inbox.consumePromptHandoff(id: id), prompt)
        XCTAssertNil(inbox.consumePromptHandoff(id: id))
        let appearance = try source("iosApp/AppearanceSettingsView.swift")
        XCTAssertTrue(appearance.contains("生成并试穿"))
        XCTAssertTrue(appearance.contains("IOSThemePackToolCatalog.generationPrompt(style: themeDescription)"))
        XCTAssertTrue(appearance.contains("IOSDeepLinkInbox.shared.submit(url)"))
        let preflight = try XCTUnwrap(appearance.range(of: "if let error = prepareGeneration()"))
        let handoff = try XCTUnwrap(appearance.range(of: "IOSDeepLinkInbox.shared.preparePromptHandoff(prompt)"))
        XCTAssertLessThan(preflight.lowerBound, handoff.lowerBound)
        let shell = try source("iosApp/AppShell.swift")
        XCTAssertTrue(shell.contains("AppearanceSettingsView(prepareGeneration: chatViewModel.prepareForThemeGeneration)"))
    }

    func testThemeEditingHandsBaseIdentityAndPartialChangesToChat() throws {
        XCTAssertNil(IOSThemePackToolCatalog.editingPrompt(style: " \n", baseID: "rain-bookstore"))
        XCTAssertNil(IOSThemePackToolCatalog.editingPrompt(style: String(repeating: "色", count: 2_001), baseID: "rain-bookstore"))
        let prompt = try XCTUnwrap(IOSThemePackToolCatalog.editingPrompt(style: "  只把圆角缩小  ", baseID: "rain-bookstore"))
        XCTAssertTrue(prompt.hasSuffix("只把圆角缩小"))
        XCTAssertTrue(prompt.contains("rain-bookstore"))
        XCTAssertTrue(prompt.contains("base_id"))
        XCTAssertTrue(prompt.contains("theme_pack_status"))
        XCTAssertTrue(prompt.contains("theme_pack_import"))
        let inbox = IOSDeepLinkInbox()
        guard case .agentPrompt(let id) = try XCTUnwrap(inbox.preparePromptHandoff(prompt)) else {
            return XCTFail("Edit must use the existing agent chat handoff")
        }
        XCTAssertEqual(inbox.consumePromptHandoff(id: id), prompt)
        let appearance = try source("iosApp/AppearanceSettingsView.swift")
        XCTAssertTrue(appearance.contains("修改并试穿"))
        XCTAssertTrue(appearance.contains("IOSThemePackToolCatalog.editingPrompt(style: themeDescription, baseID: base.id)"))
    }

    func testBackgroundRegistersStatusOnlyDeniesImport() async {
        let chatRuntime = makeRuntime()
        let params = makeParams(toolNames: Array(IOSThemePackToolCatalog.toolNames).sorted())
        let executors = chatRuntime.backgroundToolExecutors(
            providerSetting: makeProviderSetting(),
            params: params,
            runId: "bg-theme-pack",
            conversationId: nil
        )
        XCTAssertNotNil(executors["theme_pack_status"])
        XCTAssertNotNil(executors["theme_pack_import"])

        let statusBox = ThemePackUncheckedToolExecutorBox(try! XCTUnwrap(executors["theme_pack_status"]))
        let statusOutcome = await statusBox.execute(
            name: "theme_pack_status",
            arguments: "{}",
            isUserInitiated: false
        )
        guard case .filled(let statusText) = statusOutcome else {
            return XCTFail("status should fill: \(statusOutcome)")
        }
        XCTAssertTrue(parseJSON(statusText)["ok"] as? Bool == true)

        let importBox = ThemePackUncheckedToolExecutorBox(try! XCTUnwrap(executors["theme_pack_import"]))
        let importOutcome = await importBox.execute(
            name: "theme_pack_import",
            arguments: importJSON(),
            isUserInitiated: false
        )
        guard case .denied(let reason) = importOutcome else {
            return XCTFail("background import must deny: \(importOutcome)")
        }
        XCTAssertTrue(reason.contains("前台"), reason)
        XCTAssertFalse(runtime.isTryOnActive)
    }

    func testApprovalCardAndShellUseApplyRevertCopy() throws {
        let card = try source("iosApp/MemoryToolApprovalCard.swift")
        XCTAssertTrue(card.contains("套用"))
        XCTAssertTrue(card.contains("还原"))
        XCTAssertTrue(card.contains("struct AmberThemeTryOnBar"))
        XCTAssertTrue(card.contains("arrow.uturn.backward"))
        XCTAssertTrue(card.contains(".chatApprovalHitTarget()"))
        XCTAssertTrue(card.contains(".frame(width: 180, height: 120)"))
        let support = try source("iosApp/ChatToolSupport.swift")
        XCTAssertTrue(support.contains("swatchpalette"))
        XCTAssertTrue(support.contains("试穿主题"))
        let shell = try source("iosApp/AppShell.swift")
        XCTAssertTrue(shell.contains("AmberThemeTryOnBar"))
        XCTAssertTrue(shell.contains("amberThemeTryOnTakenOver"))
        XCTAssertTrue(shell.contains("isResolvingThemeTryOn"))
        let upsertIndex = shell.range(of: "AmberThemePackLibrary.shared.upsert")?.lowerBound
        let commitIndex = shell.range(of: "AmberThemeRuntime.shared.commitTryOn")?.lowerBound
        XCTAssertNotNil(upsertIndex)
        XCTAssertNotNil(commitIndex)
        if let upsertIndex, let commitIndex {
            XCTAssertTrue(upsertIndex < commitIndex, "orphan 套用 must upsert before commitTryOn")
        }
        let appearance = try source("iosApp/AppearanceSettingsView.swift")
        XCTAssertTrue(appearance.contains("applyTakingOverTryOn { runtime.apply(option) }"))
        XCTAssertTrue(appearance.contains("AmberThemePackTransfer.document(from: runtime)"))
    }

    func testTimelineTitles() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: IOSAppLanguagePreference.defaultsKey)
        defaults.set("zh-Hans", forKey: IOSAppLanguagePreference.defaultsKey)
        defer { defaults.set(saved, forKey: IOSAppLanguagePreference.defaultsKey) }
        XCTAssertEqual(ChatToolStepModel(tool: makeTool("theme_pack_status")).title, "查看主题")
        XCTAssertEqual(ChatToolStepModel(tool: makeTool("theme_pack_import")).title, "试穿主题")
    }

    private func makeTool(_ name: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "theme-\(name)",
            toolName: name,
            input: "{}",
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func source(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.deletingLastPathComponent().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private final class ThemePackCountingSearchTransport: IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        return (http, Data())
    }
}

private final class ThemePackUncheckedToolExecutorBox: @unchecked Sendable {
    private let base: any IOSToolExecutor
    init(_ base: any IOSToolExecutor) { self.base = base }
    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        await base.execute(name: name, arguments: arguments, isUserInitiated: isUserInitiated)
    }
}
