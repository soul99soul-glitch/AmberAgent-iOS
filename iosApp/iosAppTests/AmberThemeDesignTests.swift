import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import iosApp

/// Theme-design contract tests.  The fixture deliberately exercises the
/// authored palette, gradient, and two composable pattern layers instead of
/// only checking the legacy paper/accent slots.
@MainActor
final class AmberThemeDesignTests: XCTestCase {
    private let designDefaultsKey = "app.amber.ios.theme.design"
    private var runtime: AmberThemeRuntime { .shared }
    private var savedRuntimeDocument: AmberThemePackDocument?
    private var savedDesignData: Data?
    private var savedThemeID: String?
    private var savedThemeName: String?

    override func setUp() async throws {
        try await super.setUp()
        runtime.discardTryOn()
        savedRuntimeDocument = AmberThemePackTransfer.document(from: runtime)
        savedDesignData = UserDefaults.standard.data(forKey: designDefaultsKey)
        savedThemeID = runtime.selectedThemeID
        savedThemeName = runtime.selectedThemeName
    }

    override func tearDown() async throws {
        runtime.discardTryOn()
        if let savedRuntimeDocument {
            try? runtime.apply(savedRuntimeDocument)
        }
        runtime.rememberThemeIdentity(id: savedThemeID, displayName: savedThemeName)
        if let savedDesignData {
            UserDefaults.standard.set(savedDesignData, forKey: designDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: designDefaultsKey)
        }
        try await super.tearDown()
    }

    func testToolArgumentsDecodeAndDocumentRoundTripPreserveDesign() throws {
        let arguments = try makeArguments()
        let document = try AmberThemePackTransfer.document(fromToolArguments: arguments)
        let design = try XCTUnwrap(document.design)

        XCTAssertEqual(design.light?.background, "#F4F0E8")
        XCTAssertEqual(design.dark?.foreground, "#F4EEE6")
        XCTAssertEqual(design.gradient?.darkColors, ["#17141A", "#3B2C31"])
        XCTAssertEqual(design.patterns.map(\.kind), ["dots", "waves"])
        XCTAssertEqual(design.patterns.first?.spacing, 18)
        try design.validate()

        let encoded = try AmberThemePackTransfer.encode(document)
        let decoded = try AmberThemePackTransfer.decode(encoded)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.design, document.design)
    }

    func testTryOnDiscardAndCommitKeepUserDefaultsTransactional() throws {
        let builtin = try XCTUnwrap(AmberThemePack.builtins.first { $0.id == "notion-blue" })
        runtime.apply(builtin)
        let baselineDocument = AmberThemePackTransfer.document(from: runtime)
        let baselineData = UserDefaults.standard.data(forKey: designDefaultsKey)
        let libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-theme-design-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.json")
        let library = AmberThemePackLibrary(fileURL: libraryURL)
        let service = IOSThemePackToolService(runtime: runtime, library: library)
        defer { try? FileManager.default.removeItem(at: libraryURL.deletingLastPathComponent()) }

        let candidate = try service.prepareImport(argumentsJSON: jsonString(try makeArguments()))
        XCTAssertEqual(runtime.design, candidate.design)
        XCTAssertNotEqual(runtime.paper.rawValue, baselineDocument.paper)
        XCTAssertEqual(AmberTheme.radiusLarge, 26)
        XCTAssertEqual(AmberTheme.radiusXLarge, 26)
        XCTAssertEqual(AmberTheme.controlRadius(99), 13)
        XCTAssertEqual(UserDefaults.standard.data(forKey: designDefaultsKey), baselineData)

        service.discardPreparedImport()
        XCTAssertEqual(AmberThemePackTransfer.document(from: runtime), baselineDocument)
        XCTAssertEqual(UserDefaults.standard.data(forKey: designDefaultsKey), baselineData)

        let committed = try service.prepareImport(argumentsJSON: jsonString(try makeArguments()))
        _ = try service.commitPreparedImport()
        XCTAssertEqual(runtime.design, committed.design)
        XCTAssertFalse(runtime.isTryOnActive)
        let persistedDesignData = try XCTUnwrap(UserDefaults.standard.data(forKey: designDefaultsKey))
        let persistedDesign = try JSONDecoder().decode(AmberThemeDesign.self, from: persistedDesignData)
        XCTAssertEqual(persistedDesign, try XCTUnwrap(committed.design))
        XCTAssertTrue(library.contains(id: committed.id))
        runtime.apply(AmberThemeRuntime.Paper.neutral)
        XCTAssertNil(runtime.design)
        XCTAssertEqual(runtime.paper, .neutral)
        XCTAssertNil(UserDefaults.standard.data(forKey: designDefaultsKey))
    }

    func testInvalidDesignIsRejectedAndLeavesOriginalThemeUntouched() throws {
        let builtin = try XCTUnwrap(AmberThemePack.builtins.first { $0.id == "notion-blue" })
        runtime.apply(builtin)
        let baseline = AmberThemePackTransfer.document(from: runtime)
        let baselineData = UserDefaults.standard.data(forKey: designDefaultsKey)
        let libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-theme-design-invalid-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.json")
        let service = IOSThemePackToolService(
            runtime: runtime,
            library: AmberThemePackLibrary(fileURL: libraryURL)
        )
        defer { try? FileManager.default.removeItem(at: libraryURL.deletingLastPathComponent()) }

        let invalidArguments: [[String: Any]] = [
            try makeArguments(lightBackground: "#GGGGGG"),
            try makeArguments(patternSpacing: 0),
            try makeArguments(lightForeground: "#F4F0E8"),
        ]
        for arguments in invalidArguments {
            let output = service.execute(
                toolName: "theme_pack_import",
                argumentsJSON: jsonString(arguments)
            )
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            )
            XCTAssertEqual(payload["ok"] as? Bool, false, output)
            XCTAssertFalse(runtime.isTryOnActive)
            XCTAssertEqual(AmberThemePackTransfer.document(from: runtime), baseline)
            XCTAssertEqual(UserDefaults.standard.data(forKey: designDefaultsKey), baselineData)
        }
    }

    func testLibraryReloadRejectsInvalidDrawingParameters() throws {
        var document = try AmberThemePackTransfer.document(fromToolArguments: makeArguments())
        document.design?.patterns[0].spacing = 0
        let object = try JSONSerialization.jsonObject(with: AmberThemePackTransfer.encode(document))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-invalid-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["version": 1, "packs": [object]]).write(to: url)
        XCTAssertTrue(AmberThemePackLibrary(fileURL: url).installed.isEmpty)
    }

    func testLightAndDarkDesignPreviewRenderAndAttachImages() throws {
        let document = try AmberThemePackTransfer.document(fromToolArguments: try makeArguments())
        let design = try XCTUnwrap(document.design)

        try renderPreview(design: design, appearance: .light, outputPath: "/tmp/amber-theme-design-light.png")
        try renderPreview(design: design, appearance: .dark, outputPath: "/tmp/amber-theme-design-dark.png")
    }

    // MARK: - Fixture

    private func makeArguments(
        lightBackground: String = "#F4F0E8",
        lightForeground: String = "#2A2420",
        patternSpacing: Double = 18
    ) throws -> [String: Any] {
        let design = designObject(
            lightBackground: lightBackground,
            lightForeground: lightForeground,
            patternSpacing: patternSpacing
        )
        // Keep this a JSON-compatible Foundation object: it is the same shape
        // delivered by the tool bridge, before Codable decoding on the host.
        guard JSONSerialization.isValidJSONObject(design) else {
            throw NSError(domain: "AmberThemeDesignTests", code: 1)
        }
        return [
            "id": "rain-bookstore-design",
            "display_name": "雨天书店 · 完整设计",
            "paper": "paper",
            "accent_hex": "0xB56A4A",
            "ink_hex": "0xFFF8F0",
            "canvas_style": "flat",
            "brand_mark": "serifWordmark",
            "shortcut_icon_style": "phosphorFill",
            "chrome_typeface": "serif",
            "design": design,
        ]
    }

    private func designObject(
        lightBackground: String,
        lightForeground: String,
        patternSpacing: Double
    ) -> [String: Any] {
        [
            "light": [
                "background": lightBackground,
                "surface": "#FCFAF4",
                "foreground": lightForeground,
                "mutedForeground": "#6B5D54",
                "border": "#D6C8BA",
            ],
            "dark": [
                "background": "#17141A",
                "surface": "#27232D",
                "foreground": "#F4EEE6",
                "mutedForeground": "#A9A0B2",
                "border": "#4B4150",
            ],
            "gradient": [
                "colors": ["#F4F0E8", "#D9B08C"],
                "darkColors": ["#17141A", "#3B2C31"],
                "angle": 135.0,
            ],
            "patterns": [
                [
                    "kind": "dots",
                    "color": "#8C6A48",
                    "opacity": 0.16,
                    "spacing": patternSpacing,
                    "size": 2.0,
                ],
                [
                    "kind": "waves",
                    "color": "#4A342A",
                    "opacity": 0.08,
                    "spacing": 24.0,
                    "size": 1.5,
                ],
            ],
            "components": [
                "cardRadius": 26.0,
                "bubbleRadius": 17.0,
                "controlRadius": 13.0,
                "borderWidth": 1.0,
                "shadowOpacity": 0.2,
                "shadowRadius": 10.0,
                "brandText": "Rain",
                "brandSize": 31.0,
                "brandTracking": 0.4,
            ],
        ]
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func renderPreview(
        design: AmberThemeDesign,
        appearance: ColorScheme,
        outputPath: String
    ) throws {
        let content = AmberThemePackMiniPreview(
            palette: AmberThemeRuntime.Paper.neutral.lightPalette,
            accent: Color(hex: 0xB56A4A),
            canvasStyle: .flat,
            design: design
        )
        .frame(width: 360, height: 240)
        .environment(\.colorScheme, appearance)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

        let attachment = XCTAttachment(image: image)
        attachment.name = URL(fileURLWithPath: outputPath).lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
