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
            return status()
        case "theme_pack_import":
            return importNow(argumentsJSON: argumentsJSON)
        default:
            return fail(toolName, "未知的主题工具。")
        }
    }

    func status() -> String {
        let currentDocument: AmberThemePackDocument
        var tryOn: [String: Any]?
        if let session = runtime.tryOnSession {
            currentDocument = session.baseline
            tryOn = Self.slotJSON(session.candidate)
        } else {
            currentDocument = AmberThemePackTransfer.document(from: runtime)
        }
        return Self.ok([
            "tool": "theme_pack_status",
            "current": Self.slotJSON(currentDocument),
            "try_on": tryOn as Any? ?? NSNull(),
            "installed_ids": library.installed.map(\.id),
            "builtin_ids": AmberThemePack.builtins.map(\.id),
            "allowed": Self.allowedSlots,
            "contrast_min": AmberColorContrast.minimumAccentInkRatio,
            "rules": Self.rules,
        ])
    }

    /// Validate, try-on immediately, stash for 套用. Does not persist.
    func prepareImport(argumentsJSON: String, approval: AmberThemeTryOnApproval? = nil) throws -> AmberThemePackDocument {
        let args = Self.jsonObject(argumentsJSON) ?? [:]
        let document = try AmberThemePackTransfer.document(fromToolArguments: args)
        preparedSessionID = try runtime.beginTryOn(document, approval: approval)
        return document
    }

    func commitPreparedImport() throws -> String {
        guard let preparedSessionID else {
            throw AmberThemeTryOnError.noActiveTryOn
        }
        guard let session = runtime.tryOnSession, session.id == preparedSessionID else {
            throw AmberThemeTryOnError.replacedTryOn
        }
        let document = session.candidate
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
            discardPreparedImport()
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
        "Use design for a complete visual direction: separate light/dark palettes, gradients, composable patterns, and component geometry.",
        "design.light and design.dark each require background, surface, foreground, mutedForeground, and border hex colors.",
        "Palette foreground contrast must be at least 4.5:1 against background and surface; mutedForeground must be at least 3:1.",
        "gradient.colors is the light ramp and gradient.darkColors is the dark ramp; each has 2...4 colors and only needs to match its mode.",
        "patterns may combine up to three dots, grid, diagonal, crosses, waves, or rings layers within the allowed ranges.",
        "components is optional; it can tune card/bubble/control radii, borders, shadows, and custom brand text within the allowed ranges.",
        "Do not change list layout, appearance mode, or chat body fonts.",
        "Default canvas_scope to shell; use appWide when the user explicitly asks for the design across the whole app.",
        "High-luminance accent_hex needs a dark ink_hex; contrast must be at least 3.0.",
        "id must be a new slug, not sit-terracotta, pi-steel, or notion-blue.",
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
            "canvas_scope": document.canvasScope ?? AmberCanvasScope.shell.rawValue,
            "bubble_chrome": document.bubbleChrome ?? AmberBubbleChrome.standard.rawValue,
            "glass_chrome": document.glassChrome ?? AmberGlassChrome.standard.rawValue,
            "empty_art": document.emptyArt ?? AmberEmptyArtStyle.none.rawValue,
            "settings_chrome": document.settingsChrome ?? false,
            "launch_brand": document.launchBrand ?? AmberLaunchBrandStyle.none.rawValue,
            "design": Self.designJSON(document.design),
        ]
    }

    private static func designJSON(_ design: AmberThemeDesign?) -> Any {
        guard let design else { return NSNull() }

        var payload: [String: Any] = [
            "light": [
                "background": design.light.background,
                "surface": design.light.surface,
                "foreground": design.light.foreground,
                "mutedForeground": design.light.mutedForeground,
                "border": design.light.border,
            ],
            "dark": [
                "background": design.dark.background,
                "surface": design.dark.surface,
                "foreground": design.dark.foreground,
                "mutedForeground": design.dark.mutedForeground,
                "border": design.dark.border,
            ],
            "patterns": design.patterns.map { pattern in
                [
                    "kind": pattern.kind,
                    "color": pattern.color,
                    "opacity": pattern.opacity,
                    "spacing": pattern.spacing,
                    "size": pattern.size,
                ]
            },
        ]
        if let gradient = design.gradient {
            payload["gradient"] = [
                "colors": gradient.colors,
                "darkColors": gradient.darkColors,
                "angle": gradient.angle,
            ]
        } else {
            payload["gradient"] = NSNull()
        }
        if let components = design.components {
            var componentPayload: [String: Any] = [:]
            if let value = components.cardRadius { componentPayload["cardRadius"] = value }
            if let value = components.bubbleRadius { componentPayload["bubbleRadius"] = value }
            if let value = components.controlRadius { componentPayload["controlRadius"] = value }
            if let value = components.borderWidth { componentPayload["borderWidth"] = value }
            if let value = components.shadowOpacity { componentPayload["shadowOpacity"] = value }
            if let value = components.shadowRadius { componentPayload["shadowRadius"] = value }
            if let value = components.brandText { componentPayload["brandText"] = value }
            if let value = components.brandSize { componentPayload["brandSize"] = value }
            if let value = components.brandTracking { componentPayload["brandTracking"] = value }
            payload["components"] = componentPayload
        } else {
            payload["components"] = NSNull()
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
    static func generationPrompt(style: String) -> String? {
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty else { return nil }
        return IOSAppDeepLink.normalizedPrompt("""
            请为 Amber 生成一个主题并直接在 App 中试穿。
            先调用 tool_search 搜索“生成主题”，再调用 theme_pack_status 读取当前主题和允许的选项，最后根据我的风格要求设计配方并调用 theme_pack_import；不要只输出 JSON 或操作说明。
            尽量使用 design 做完整设计，而不只改变 accent_hex：为浅色和深色分别设计 background、surface、foreground、mutedForeground、border；需要时加入分别适配浅深的 gradient colors/darkColors（各 2 到 4 色）、最多 3 层可组合纹理（dots、grid、diagonal、crosses、waves、rings），并用 components 调整圆角、边框、阴影和品牌文字。需要主题覆盖全 app 时将 canvas_scope 设为 appWide，否则默认 shell。
            使用新的主题 id，保持文字对比度，不修改列表布局、浅深模式和聊天正文字体。试穿后由我选择“套用”保存或“还原”，未确认前不要声称已经保存。

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

    static func approvalReason(displayName: String) -> String {
        "正在试穿「\(displayName)」，尚未保存。套用后写入主题库；还原回到试穿前。"
    }

    static func argumentsPreview(for document: AmberThemePackDocument) -> String {
        "\(document.displayName) · \(document.paper) · \(document.accentHex)"
    }
}
