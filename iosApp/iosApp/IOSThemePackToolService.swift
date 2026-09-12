import Foundation

/// Host-side theme pack tools. Status is a pure catalog; import try-on is
/// in-memory until the user taps 套用. Library writes happen only on commit.
@MainActor
final class IOSThemePackToolService {
    private let runtime: AmberThemeRuntime
    private let library: AmberThemePackLibrary
    private var preparedSessionID: UUID?

    init(
        runtime: AmberThemeRuntime = .shared,
        library: AmberThemePackLibrary = .shared
    ) {
        self.runtime = runtime
        self.library = library
    }

    func execute(toolName: String, argumentsJSON: String) -> String {
        switch toolName {
        case "theme_pack_status":
            return status(argumentsJSON: argumentsJSON)
        case "theme_pack_import":
            return importNow(argumentsJSON: argumentsJSON)
        default:
            return fail(toolName, "未知的主题工具。")
        }
    }

    func status(argumentsJSON: String = "{}") -> String {
        guard let args = Self.jsonObject(argumentsJSON) else {
            return fail("theme_pack_status", "无法解析 JSON")
        }
        let base: AmberThemePackDocument
        do {
            let id = try Self.themeID(args["id"] ?? "current")
            base = try resolveBase(id)
        } catch {
            return fail("theme_pack_status", error.localizedDescription)
        }
        let currentDocument: AmberThemePackDocument
        var tryOn: [String: Any]?
        if let session = runtime.tryOnSession {
            currentDocument = session.baseline
            tryOn = Self.slotJSON(session.candidate)
        } else {
            currentDocument = currentRecipe()
        }
        return Self.ok([
            "tool": "theme_pack_status",
            "current": Self.slotJSON(currentDocument),
            "try_on": tryOn as Any? ?? NSNull(),
            "base": Self.slotJSON(base),
            "installed_ids": library.installed.map(\.id),
            "installed": library.installed.map { ["id": $0.id, "display_name": $0.displayName] },
            "builtin_ids": AmberThemePack.builtins.map(\.id),
            "allowed": Self.allowedSlots,
            "contrast_min": AmberColorContrast.minimumAccentInkRatio,
            "rules": Self.rules,
        ])
    }

    /// Validate, try-on immediately, stash for 套用. Does not persist.
    func prepareImport(argumentsJSON: String, approval: AmberThemeTryOnApproval? = nil) throws -> AmberThemePackDocument {
        guard let args = Self.jsonObject(argumentsJSON) else {
            throw AmberThemePackTransferError.invalidJSON
        }
        let document: AmberThemePackDocument
        if let rawID = args["base_id"] {
            let base = try resolveBase(Self.themeID(rawID))
            document = try Self.patching(base, with: args)
        } else {
            document = try AmberThemePackTransfer.document(fromToolArguments: args)
        }
        preparedSessionID = try runtime.beginTryOn(document, approval: approval)
        return document
    }

    private func currentRecipe() -> AmberThemePackDocument {
        // Use this service's library, including injected libraries, to retain
        // the saved identity rather than exporting a generic "custom" snapshot.
        library.installed.first { $0.id == runtime.selectedThemeID && $0.matches(runtime: runtime) }
            ?? AmberThemePackTransfer.document(from: runtime)
    }

    private func resolveBase(_ id: String) throws -> AmberThemePackDocument {
        if let candidate = runtime.tryOnSession?.candidate, id == "current" || id == candidate.id {
            return candidate
        }
        let current = currentRecipe()
        if id == "current" || id == current.id { return current }
        if let installed = library.installed.first(where: { $0.id == id }) { return installed }
        if let builtin = AmberThemePack.builtins.first(where: { $0.id == id }) {
            return AmberThemePackTransfer.document(from: builtin)
        }
        throw ThemeEditError.invalidPatch("找不到主题「\(id)」，请先调用 theme_pack_status 查看可用主题。")
    }

    private static func themeID(_ value: Any) throws -> String {
        guard let id = value as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThemeEditError.invalidPatch("主题 id 必须是非空字符串。")
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merge only explicitly supplied fields into the portable document. Encoding
    /// the document first preserves legacy nil slots and fields outside the tool
    /// surface; a full argument round-trip would replace them with create defaults.
    private static func patching(_ base: AmberThemePackDocument, with args: [String: Any]) throws -> AmberThemePackDocument {
        let names = [
            "display_name": "displayName", "paper": "paper", "accent_hex": "accentHex", "ink_hex": "inkHex",
            "canvas_style": "canvasStyle", "brand_mark": "brandMark", "shortcut_icon_style": "shortcutIconStyle",
            "chrome_typeface": "chromeTypeface", "canvas_scope": "canvasScope", "bubble_chrome": "bubbleChrome",
            "glass_chrome": "glassChrome", "empty_art": "emptyArt", "settings_chrome": "settingsChrome",
            "launch_brand": "launchBrand", "design": "design",
        ]
        try checkKeys(args, allowed: Set(names.keys).union(["base_id", "id"]), path: "theme")
        if let id = args["id"], try themeID(id) != base.id {
            throw ThemeEditError.invalidPatch("修改主题时请保留原 id「\(base.id)」或省略 id；新建主题时才使用新 id。")
        }
        var changes = args.filter { names[$0.key] != nil }
        guard !changes.isEmpty else {
            throw ThemeEditError.invalidPatch("请提供至少一个要修改的主题字段，其余字段会保留。")
        }
        for (key, value) in changes where key != "design" {
            if key == "settings_chrome" {
                guard !(value is NSNull) else {
                    throw ThemeEditError.invalidPatch("字段 \(key) 不能设为 null。")
                }
            } else {
                guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ThemeEditError.invalidPatch("字段 \(key) 必须是非空字符串。")
                }
                changes[key] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let design = changes["design"] as? [String: Any] {
            try checkKeys(design, allowed: ["light", "dark", "gradient", "patterns", "components"], path: "design")
            for mode in ["light", "dark"] {
                if let palette = design[mode] as? [String: Any] {
                    try checkKeys(palette, allowed: ["background", "surface", "foreground", "mutedForeground", "border"], path: "design.\(mode)")
                }
            }
            if let gradient = design["gradient"] as? [String: Any] {
                try checkKeys(gradient, allowed: ["colors", "darkColors", "angle"], path: "design.gradient")
            }
            if let components = design["components"] as? [String: Any] {
                try checkKeys(components, allowed: ["cardRadius", "bubbleRadius", "controlRadius", "borderWidth", "shadowOpacity", "shadowRadius", "brandText", "brandSize", "brandTracking"], path: "design.components")
            }
            if let patterns = design["patterns"] as? [[String: Any]] {
                for pattern in patterns {
                    try checkKeys(pattern, allowed: ["kind", "color", "opacity", "spacing", "size"], path: "design.patterns")
                }
            }
        }
        guard var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any] else {
            throw AmberThemePackTransferError.invalidJSON
        }
        if base.design == nil, changes["design"] is [String: Any] {
            encoded["design"] = ["patterns": []]
        }
        let patch = Dictionary(uniqueKeysWithValues: changes.map { (names[$0.key]!, $0.value) })
        let merged = merge(encoded, patch: patch)
        var document: AmberThemePackDocument
        do {
            document = try JSONDecoder().decode(AmberThemePackDocument.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch {
            throw ThemeEditError.invalidPatch("修改后的主题字段不完整或类型不正确。组件可单独修改；首次添加浅色或深色配色时，请提供该配色的五个颜色字段。")
        }
        try AmberThemePackTransfer.validate(document)
        if AmberThemePackLibrary.isBuiltinId(base.id) {
            document.id = "\(base.id)-custom-\(UUID().uuidString.prefix(8).lowercased())"
        }
        return document
    }

    private static func checkKeys(_ object: [String: Any], allowed: Set<String>, path: String) throws {
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
            throw ThemeEditError.invalidPatch("未知主题字段 \(path).\(unknown)，请按 theme_pack_status 返回的字段修改。")
        }
    }

    private static func merge(_ base: [String: Any], patch: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in patch {
            if value is NSNull {
                result.removeValue(forKey: key)
            } else if let nested = value as? [String: Any] {
                result[key] = merge(result[key] as? [String: Any] ?? [:], patch: nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private enum ThemeEditError: LocalizedError {
        case invalidPatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidPatch(let reason): reason
            }
        }
    }

    func commitPreparedImport() throws -> String {
        guard let preparedSessionID else {
            throw AmberThemeTryOnError.noActiveTryOn
        }
        guard let session = runtime.tryOnSession, session.id == preparedSessionID else {
            throw AmberThemeTryOnError.replacedTryOn
        }
        let document = session.candidate
        let replacesInstalled = library.contains(id: document.id)
        do {
            try library.upsert(document)
            try runtime.commitTryOn()
            self.preparedSessionID = nil
        } catch {
            discardPreparedImport()
            throw error
        }
        return Self.ok([
            "tool": "theme_pack_import",
            "id": document.id,
            "display_name": document.displayName,
            "persisted": true,
            "installed": true,
            "operation": replacesInstalled ? "updated" : "created",
        ])
    }

    func discardPreparedImport() {
        if let preparedSessionID, runtime.tryOnSession?.id == preparedSessionID {
            runtime.discardTryOn()
        }
        preparedSessionID = nil
    }

    /// Recipe / dispatch fallback: try-on then persist in one shot.
    private func importNow(argumentsJSON: String) -> String {
        do {
            _ = try prepareImport(argumentsJSON: argumentsJSON)
            return try commitPreparedImport()
        } catch {
            return fail(
                "theme_pack_import",
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private static let allowedPalette: [String: Any] = [
        "required": ["background", "surface", "foreground", "mutedForeground", "border"],
        "color": "#RRGGBB or 0xRRGGBB",
        "foreground_contrast_min": 4.5,
        "muted_foreground_contrast_min": 3.0,
    ]

    private static let allowedDesign: [String: Any] = [
        "required": ["light", "dark", "patterns"],
        "light": allowedPalette,
        "dark": allowedPalette,
        "gradient": [
            "optional": true,
            "colors": ["mode": "light", "type": "hex[]", "min_items": 2, "max_items": 4],
            "darkColors": ["mode": "dark", "type": "hex[]", "min_items": 2, "max_items": 4],
            "angle": "number (degrees)",
            "readability": "Each ramp must keep at least 4.5:1 contrast with its matching mode foreground.",
        ],
        "patterns": [
            "required": true,
            "max_items": 3,
            "kind": ["dots", "grid", "diagonal", "crosses", "waves", "rings"],
            "color": "#RRGGBB or 0xRRGGBB",
            "opacity": ["min": 0.0, "max": 0.3],
            "spacing": ["min": 12.0, "max": 120.0],
            "size": ["min": 0.5, "max": 8.0],
        ],
        "components": [
            "optional": true,
            "cardRadius": ["min": 0.0, "max": 32.0],
            "bubbleRadius": ["min": 0.0, "max": 28.0],
            "controlRadius": ["min": 0.0, "max": 28.0],
            "borderWidth": ["min": 0.0, "max": 3.0],
            "shadowOpacity": ["min": 0.0, "max": 0.35],
            "shadowRadius": ["min": 0.0, "max": 24.0],
            "brandText": ["type": "string", "min_length": 1, "max_length": 16],
            "brandSize": ["min": 20.0, "max": 40.0],
            "brandTracking": ["min": -2.0, "max": 6.0],
        ],
    ]

    private static let allowedSlots: [String: Any] = [
        "paper": ["paper", "neutral", "white", "pi", "notion"],
        "canvas_style": AmberCanvasStyle.allCases.map(\.rawValue),
        "brand_mark": AmberBrandMarkStyle.allCases.map(\.rawValue),
        "shortcut_icon_style": AmberShortcutIconStyle.allCases.map(\.rawValue),
        "chrome_typeface": AmberChromeTypeface.allCases.map(\.rawValue),
        "canvas_scope": AmberCanvasScope.allCases.map(\.rawValue),
        "bubble_chrome": AmberBubbleChrome.allCases.map(\.rawValue),
        "glass_chrome": AmberGlassChrome.allCases.map(\.rawValue),
        "empty_art": AmberEmptyArtStyle.allCases.map(\.rawValue),
        "launch_brand": AmberLaunchBrandStyle.allCases.map(\.rawValue),
        "design": allowedDesign,
    ]

    private static let rules: [String] = [
        "For requests to modify, refine, or continue a theme (修改主题、微调、在此基础上), call theme_pack_import with base_id and ONLY the changed fields. Do not redesign unspecified fields or invent a new id.",
        "base is the recipe to edit. With no status id, base is the currently visible try-on or applied theme; pass an installed/builtin id to inspect another theme.",
        "base_id may be current or an id returned here. Edits keep a custom theme's id and replace its library entry only after 套用; builtin edits create an editable copy once.",
        "Omitted fields are preserved; nested design objects merge by field, arrays replace as a whole. Use null to remove design, light/dark palette overrides, gradient, components, or an optional component field; use [] to clear patterns.",
        "When creating a new theme, use design for a complete visual direction: separate light/dark palettes, gradients, composable patterns, and component geometry.",
        "Component-only edits work on builtin and legacy themes without supplying palettes: absent light/dark palettes inherit the original paper colors and home chrome. Newly supplied palette objects need all five color fields; gradients require both palettes for contrast validation.",
        "Palette foreground contrast must be at least 4.5:1 against background and surface; mutedForeground must be at least 3:1.",
        "gradient.colors is the light ramp and gradient.darkColors is the dark ramp; each has 2...4 colors and only needs to match its mode.",
        "patterns may combine up to three dots, grid, diagonal, crosses, waves, or rings layers within the allowed ranges.",
        "components is optional; it can tune card/bubble/control radii, borders, shadows, and custom brand text within the allowed ranges.",
        "Do not change list layout, appearance mode, or chat body fonts.",
        "For new themes default canvas_scope to shell; edits preserve the existing scope unless the user asks to change it.",
        "High-luminance accent_hex needs a dark ink_hex; contrast must be at least 3.0.",
        "Only new themes need a new id. For an edit, omit id and keep base_id; sit-terracotta, pi-steel, and notion-blue themselves remain immutable.",
        "Try-on is visible immediately but not saved until the user taps 套用.",
    ]

    static func slotJSON(_ document: AmberThemePackDocument) -> [String: Any] {
        [
            "id": document.id,
            "display_name": document.displayName,
            "paper": document.paper,
            "accent_hex": document.accentHex,
            "ink_hex": document.inkHex,
            "canvas_style": document.canvasStyle,
            "brand_mark": document.brandMark,
            "shortcut_icon_style": document.shortcutIconStyle,
            "chrome_typeface": document.chromeTypeface,
            "canvas_scope": document.canvasScope ?? AmberCanvasScope.homeOnly.rawValue,
            "bubble_chrome": document.bubbleChrome ?? AmberBubbleChrome.standard.rawValue,
            "glass_chrome": document.glassChrome ?? AmberGlassChrome.standard.rawValue,
            "empty_art": document.emptyArt ?? AmberEmptyArtStyle.none.rawValue,
            "settings_chrome": document.settingsChrome ?? false,
            "launch_brand": document.launchBrand ?? AmberLaunchBrandStyle.none.rawValue,
            "design": Self.designJSON(document.design),
        ]
    }

    private static func designJSON(_ design: AmberThemeDesign?) -> Any {
        guard let design,
              let data = try? JSONEncoder().encode(design),
              var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return NSNull()
        }
        for key in ["light", "dark", "gradient", "components"] where payload[key] == nil {
            payload[key] = NSNull()
        }
        return payload
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func ok(_ payload: [String: Any]) -> String {
        var body = payload
        body["ok"] = true
        body["status"] = body["status"] ?? "ok"
        return IOSWorkspaceStore.json(body)
    }

    private func fail(_ tool: String, _ reason: String) -> String {
        ChatToolOutputFormatter.toolFailureJSON(toolName: tool, reason: reason, status: "failed")
    }
}

enum IOSThemePackToolCatalog {
    @MainActor
    static func editingPrompt(style: String, baseID: String) -> String? {
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseID = baseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty, !baseID.isEmpty else { return nil }
        return IOSAppDeepLink.normalizedPrompt("""
            请在我指定的 Amber 主题上局部修改并直接试穿，保留没有要求修改的部分。
            先调用 tool_search 搜索“主题”，再调用 theme_pack_status，参数为 \(IOSWorkspaceStore.json(["id": baseID]))，读取返回的 base 完整配方。
            调用 theme_pack_import 时以 \(IOSWorkspaceStore.json(["base_id": baseID])) 为参数基础，只添加我要求修改的字段。design 内也只发送变化的子字段，未提供的配色、渐变、纹理、组件和主题名称都保留；不要重新生成整套配方，不要另起 id。数组会整体替换，修改其中一项时保留其它项。
            自定义主题套用后更新原条目；内置主题会保存为可编辑副本。若继续调整正在试穿的效果，以最新 try_on 或 base_id=current 为基础。
            保持文字对比度，不修改列表布局、浅深模式和聊天正文字体。试穿后由我选择“套用”保存或“还原”，未确认前不要声称已经保存。

            修改要求：
            \(style)
            """)
    }

    static func generationPrompt(style: String) -> String? {
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty else { return nil }
        return IOSAppDeepLink.normalizedPrompt("""
            请为 Amber 生成一个主题并直接在 App 中试穿。
            先调用 tool_search 搜索“生成主题”，再调用 theme_pack_status 读取当前主题和允许的选项，最后根据我的风格要求设计配方并调用 theme_pack_import；不要只输出 JSON 或操作说明。
            尽量使用 design 做完整设计，而不只改变 accent_hex：为浅色和深色分别设计 background、surface、foreground、mutedForeground、border；需要时加入分别适配浅深的 gradient colors/darkColors（各 2 到 4 色）、最多 3 层可组合纹理（dots、grid、diagonal、crosses、waves、rings），并用 components 调整圆角、边框、阴影和品牌文字。需要主题覆盖全 app 时将 canvas_scope 设为 appWide，否则默认 shell。
            使用新的主题 id，保持文字对比度，不修改列表布局、浅深模式和聊天正文字体。试穿后由我选择“套用”保存或“还原”，未确认前不要声称已经保存。
            只有这次新建需要新 id；后续若我要求微调这个主题，使用 theme_pack_import 的 base_id 局部修改，保持原 id 和未提及的设计。

            风格要求：
            \(style)
            """)
    }

    static let toolNames: Set<String> = [
        "theme_pack_status",
        "theme_pack_import",
    ]
    static let mutatingToolNames: Set<String> = [
        "theme_pack_import",
    ]
    /// Import always requires a foreground try-on card (even with high-risk auto-approve).
    static let highRiskToolNames: Set<String> = [
        "theme_pack_import",
    ]
    static let backgroundAllowedToolNames: Set<String> = [
        "theme_pack_status",
    ]

    static func approvalReason(displayName: String, replacesInstalled: Bool = false) -> String {
        let action = replacesInstalled ? "更新原主题" : "写入主题库"
        return "正在试穿「\(displayName)」，尚未保存。套用后\(action)；还原回到试穿前。"
    }

    static func argumentsPreview(for document: AmberThemePackDocument) -> String {
        "\(document.displayName) · \(document.paper) · \(document.accentHex)"
    }
}
