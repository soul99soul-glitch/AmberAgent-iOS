import XCTest
@testable import AmberMac

/// M3.2: the settings page must not imply a permission the runtime cannot honour.
@MainActor final class DesktopPluginCapabilityTests: XCTestCase {
    private func plugin(id: String = "note_helper", builtIn: Bool = false,
                        domains: [String] = [], write: [String] = [], modules: [String] = []) -> DesktopInstalledPlugin {
        let capabilities = DesktopPluginCapabilities(networkDomains: domains, workspaceWritePrefixes: write,
            hostModules: modules)
        let manifest = DesktopPluginManifest(id: id, name: id, version: "1", description: "",
            capabilities: capabilities, settingsSchema: [], tools: [], ui: DesktopPluginUIManifest())
        return DesktopInstalledPlugin(manifest: manifest, scriptSource: "", enabled: true, isBuiltIn: builtIn)
    }

    func testSandboxNetworkAndFilesAreReportedAsDeclaredButNotWired() {
        let thirdParty = plugin(domains: ["news.example.com"], write: ["outputs"])
        let rows = DesktopPluginSettingsPresentation.capabilityRows(for: thirdParty)
        XCTAssertEqual(rows.map(\.id), ["compute", "storage", "host", "network", "files", "ui"])
        XCTAssertEqual(rows.first { $0.id == "network" }?.state, .declaredNotWired)
        XCTAssertTrue(rows.first { $0.id == "network" }?.detail.contains("沙箱没有 HTTP 能力") == true)
        XCTAssertEqual(rows.first { $0.id == "files" }?.state, .declaredNotWired)
        XCTAssertEqual(rows.first { $0.id == "storage" }?.state, .wired)
        XCTAssertEqual(rows.first { $0.id == "network" }?.badge, "未接线")
    }

    func testBuiltInPluginNetworkIsHostNativeWhileFilesStayUnwired() {
        let feishu = plugin(id: "feishu_calendar", builtIn: true,
            domains: ["caldav.feishu.cn", "open.feishu.cn"], write: ["outputs"])
        let rows = DesktopPluginSettingsPresentation.capabilityRows(for: feishu)
        XCTAssertEqual(rows.first { $0.id == "network" }?.state, .hostNative)
        XCTAssertTrue(rows.first { $0.id == "network" }?.detail.contains("不经过沙箱") == true)
        XCTAssertEqual(rows.first { $0.id == "files" }?.state, .declaredNotWired)
    }

    func testPluginWithoutDeclarationsClaimsNothing() {
        let bare = plugin()
        let rows = DesktopPluginSettingsPresentation.capabilityRows(for: bare)
        XCTAssertEqual(rows.first { $0.id == "network" }?.state, .declaredNotWired)
        XCTAssertTrue(rows.first { $0.id == "network" }?.detail.contains("未声明域名") == true)
        XCTAssertTrue(rows.first { $0.id == "ui" }?.detail.contains("仅提供工具") == true)
        XCTAssertFalse(rows.contains { $0.detail.localizedCaseInsensitiveContains("完整支持") })
        // A script cannot reach the user's calendar either, so silence is not an option.
        XCTAssertEqual(rows.first { $0.id == "host" }?.state, .declaredNotWired)
        XCTAssertTrue(rows.first { $0.id == "host" }?.detail.contains("无法访问日历") == true)
    }

    /// M3.4: a declared host module is only "wired" when this build actually implements it for the official built-in plugin.
    func testDeclaredHostModuleIsWiredOnlyWhenImplemented() throws {
        let apple = DesktopPluginStore.makeBuiltInAppleSchedulePlugin(enabled: true)
        let rows = DesktopPluginSettingsPresentation.capabilityRows(for: apple)
        let host = rows.first { $0.id == "host:calendar" }
        XCTAssertEqual(host?.state, .wired)
        XCTAssertEqual(host?.badge, "已接线")
        XCTAssertTrue(host?.detail.contains("EventKit") == true)
        // It reaches EventKit through the host, not a socket, so it must not claim network access.
        XCTAssertEqual(rows.first { $0.id == "network" }?.state, .declaredNotWired)
        XCTAssertTrue(rows.first { $0.id == "network" }?.detail.contains("未声明域名") == true)

        // A third-party plugin declaring hostModules: ["calendar"] must never be reported as wired, and importPlugin must reject it.
        let spoofed = plugin(id: "spoof_calendar", builtIn: false, modules: ["calendar"])
        let spoofedHost = DesktopPluginSettingsPresentation.capabilityRows(for: spoofed).first { $0.id == "host:calendar" }
        XCTAssertEqual(spoofedHost?.state, .declaredNotWired)
        XCTAssertEqual(spoofedHost?.badge, "未接线")
        let spoofedSummary = DesktopPluginSettingsPresentation.permissionSummary(for: spoofed)
        XCTAssertFalse(spoofedSummary.networkSummary.contains("本机日历经宿主直接读写"), spoofedSummary.networkSummary)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-cap-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pkgDir = tempDir.appendingPathComponent("spoof_calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        try Data("""
        {"schema":"amber.plugin.v2","id":"spoof_calendar","name":"伪造日历","version":"1.0.0","description":"d","capabilities":{"hostModules":["calendar"]}}
        """.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        let store = DesktopPluginStore(directory: tempDir.appendingPathComponent("installed", isDirectory: true),
            defaults: UserDefaults(suiteName: "amber.cap.import.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials(), calendarService: FakeCalendarService())
        XCTAssertThrowsError(try store.importPlugin(from: pkgDir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("hostModules 仅供官方内置插件使用"), error.localizedDescription)
        }
    }

    func testDisabledHostPluginSaysItsCapabilityIsInactive() {
        var apple = plugin(id: "apple_schedule", builtIn: true, modules: ["calendar"])
        apple.enabled = false
        let host = DesktopPluginSettingsPresentation.capabilityRows(for: apple).first { $0.id == "host:calendar" }
        XCTAssertEqual(host?.state, .declaredNotWired)
        XCTAssertTrue(host?.detail.contains("插件已停用") == true)
    }

    func testUnknownHostModuleFailsManifestValidation() {
        let manifest = DesktopPluginManifest(id: "odd_plugin", name: "odd", version: "1", description: "d",
            capabilities: DesktopPluginCapabilities(hostModules: ["photos"]), settingsSchema: [], tools: [],
            ui: DesktopPluginUIManifest())
        XCTAssertThrowsError(try manifest.validated()) { error in
            XCTAssertTrue(error.localizedDescription.contains("宿主模块未知"))
        }
    }

    /// The permission summary is the human-readable paragraph; it must not promise a network the sandbox lacks.
    func testPermissionSummaryDoesNotPromisUnsandboxedNetworkForThirdParty() {
        let thirdParty = plugin(id: "feed_watch", domains: ["news.example.com"], write: ["outputs"])
        let summary = DesktopPluginSettingsPresentation.permissionSummary(for: thirdParty)
        XCTAssertTrue(summary.networkSummary.contains("沙箱网络尚未接线"), summary.networkSummary)
        XCTAssertTrue(summary.workspaceSummary.contains("写入不会发生"), summary.workspaceSummary)

        let apple = DesktopPluginStore.makeBuiltInAppleSchedulePlugin(enabled: true)
        let appleSummary = DesktopPluginSettingsPresentation.permissionSummary(for: apple)
        XCTAssertTrue(appleSummary.networkSummary.contains("本机日历"), appleSummary.networkSummary)
        XCTAssertTrue(appleSummary.workspaceSummary.contains("禁止直接写入"), appleSummary.workspaceSummary)
        XCTAssertTrue(appleSummary.approvalSummary.contains("创建日程"), appleSummary.approvalSummary)
        XCTAssertFalse(appleSummary.approvalSummary.contains("发消息"), appleSummary.approvalSummary)
        XCTAssertFalse(appleSummary.approvalSummary.contains("建文档"), appleSummary.approvalSummary)

        let feishu = DesktopPluginStore.makeBuiltInFeishuPlugin(enabled: true)
        XCTAssertTrue(feishu.manifest.capabilities.workspaceWritePrefixes.isEmpty)
        let feishuSummary = DesktopPluginSettingsPresentation.permissionSummary(for: feishu)
        XCTAssertEqual(feishuSummary.workspaceSummary, "禁止直接写入当前会话工作区文件")
    }
}
