import AppKit
import XCTest
@testable import AmberMac

/// M3.2 layout guard: the capability matrix gives the name column 84pt and the badge column 64pt. A label that does
/// not fit would be truncated in the real view, and this picture-based page has no screenshot in CI to catch it —
/// so the widths are measured here with the same fonts the view uses.
@MainActor final class DesktopPluginCapabilityLayoutTests: XCTestCase {
    /// Keep a few points for the frame's own leading/trailing padding so text never sits flush on the edge.
    private let slack: CGFloat = 2

    private func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    private func plugin(id: String, builtIn: Bool, domains: [String] = [], write: [String] = [],
                        modules: [String] = []) -> DesktopInstalledPlugin {
        let capabilities = DesktopPluginCapabilities(networkDomains: domains, workspaceWritePrefixes: write,
            hostModules: modules)
        let manifest = DesktopPluginManifest(id: id, name: id, version: "1", description: "",
            capabilities: capabilities, settingsSchema: [], tools: [], ui: DesktopPluginUIManifest())
        return DesktopInstalledPlugin(manifest: manifest, scriptSource: "", enabled: true, isBuiltIn: builtIn)
    }

    /// Every row the three built-in plugins render, in the widest configuration a user can reach.
    private func allRows() -> [(title: String, badge: String)] {
        let cases = [
            plugin(id: "feishu_calendar", builtIn: true,
                domains: ["caldav.feishu.cn", "caldav.larksuite.com", "open.feishu.cn", "open.larksuite.com"],
                write: ["meetings/", "feishu/"]),
            plugin(id: "apple_schedule", builtIn: true, modules: ["calendar"]),
            plugin(id: "watchtower", builtIn: true),
            plugin(id: "note_helper", builtIn: false, domains: ["news.example.com"], write: ["notes/"])
        ]
        return cases.flatMap { plugin in
            DesktopPluginSettingsPresentation.capabilityRows(for: plugin).map { ($0.title, $0.badge) }
        }
    }

    func testCapabilityNamesFitTheNameColumn() {
        for row in allRows() {
            let measured = width(row.title, size: 12, weight: .medium)
            XCTAssertLessThanOrEqual(measured + slack, 84, "能力名「\(row.title)」在 84pt 列里会被截断（实测 \(measured)pt）")
        }
    }

    func testCapabilityBadgesFitTheBadgeColumn() {
        for row in allRows() {
            // 64pt frame minus the capsule's 6pt horizontal padding on both sides.
            let measured = width(row.badge, size: 10.5, weight: .medium)
            XCTAssertLessThanOrEqual(measured + slack, 64 - 12, "徽章「\(row.badge)」在 64pt 列里会被截断（实测 \(measured)pt）")
        }
    }

    /// A disabled host plugin must say so inside the detail column instead of inventing a longer badge.
    func testEveryRowKeepsTheSameBadgeVocabulary() {
        let badges = Set(allRows().map(\.badge))
        XCTAssertEqual(badges, ["已接线", "未接线", "宿主原生"])
    }
}
