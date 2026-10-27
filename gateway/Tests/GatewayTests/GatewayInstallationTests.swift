import Foundation
import Testing
@testable import GatewayCore

@Suite("Gateway installation (shared by CLI and Amber)")
struct GatewayInstallationTests {
    func home() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gw-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func linkFollowsBinaryAndNeverClobbersARegularFile() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let install = GatewayInstallation(home: home)
        let a = home.appendingPathComponent("A.app/Contents/MacOS/amber-gateway")
        let b = home.appendingPathComponent("B.app/Contents/MacOS/amber-gateway")
        try install.linkBinary(a)
        #expect(install.linkTarget?.path == a.path)
        try install.linkBinary(b)
        #expect(install.linkTarget?.path == b.path, "moving the app re-points the link")
        try install.removeLink()
        #expect(install.linkTarget == nil)
        try FileManager.default.createSymbolicLink(atPath: install.link.path, withDestinationPath: "../../A.app/Contents/MacOS/amber-gateway")
        #expect(install.linkTarget?.path == a.path, "relative links resolve against the link's directory")
        try install.removeLink()
        try Data("x".utf8).write(to: install.link)
        #expect(throws: GatewayInstallation.Failure.self) { try install.linkBinary(a) }
    }

    @Test func hooksUseTheStableLinkPathAndRoundTrip() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let install = GatewayInstallation(home: home)
        let changes = try install.installHooks()
        #expect(changes.allSatisfy { $0.changed })
        let codex = try String(contentsOf: install.codexHooks, encoding: .utf8)
        #expect(codex.contains(install.link.path + "' hook codex"))
        let again = try install.installHooks()
        #expect(again.allSatisfy { !$0.changed }, "idempotent")
        let removed = try install.removeHooks()
        #expect(removed.allSatisfy { $0.changed })
    }

    @Test func cliDeploymentIsDetectedAndRemovedWithoutTouchingState() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let install = GatewayInstallation(home: home)
        #expect(!install.hasCLIDeployment)
        try FileManager.default.createDirectory(at: install.cliPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: install.cliPlist)
        #expect(install.hasCLIDeployment)
        install.removeCLIDeployment(manageLaunchd: false)
        #expect(!install.hasCLIDeployment)
    }
}
