import Foundation
import Testing
@testable import GatewayCore

@Suite("Hook installer merge")
struct HookInstallerTests {
    /// Shape copied from a real ~/.codex/hooks.json with another integration (Otty) already installed.
    let existing: [String: Any] = [
        "hooks": [
            "Stop": [
                ["hooks": []],
                ["_otty": true, "hooks": [["type": "command", "command": "otty-hook.sh idle"]]],
            ],
            "PreToolUse": [
                ["matcher": "Bash", "hooks": [["type": "command", "command": "policy.py"]]],
            ],
        ],
        "description": "user file",
    ]
    let command = "'/Users/me/.local/bin/amber-gateway' hook codex"

    func groups(_ root: [String: Any], _ event: String) -> [[String: Any]] {
        ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    @Test func appendsAfterExistingGroupsSoCodexTrustIndicesSurvive() {
        let merged = HookInstaller.installing(into: existing, events: HookInstaller.codexEvents, command: command)
        let stop = groups(merged, "Stop")
        #expect(stop.count == 3)
        #expect(stop[1]["_otty"] as? Bool == true)
        #expect(HookInstaller.isOurs(stop[2]))
        #expect(groups(merged, "PreToolUse").count == 1, "events we don't hook are untouched")
        #expect(merged["description"] as? String == "user file")
        for event in HookInstaller.codexEvents {
            #expect(groups(merged, event).filter(HookInstaller.isOurs).count == 1, "\(event)")
            let hook = (groups(merged, event).first(where: HookInstaller.isOurs)?["hooks"] as? [[String: Any]])?.first
            #expect((hook?["async"] as? Bool == true) == (event == "PostToolUse"), "only the per-tool-call hook runs async: \(event)")
        }
    }

    @Test func installIsIdempotent() {
        let once = HookInstaller.installing(into: existing, events: HookInstaller.codexEvents, command: command)
        let twice = HookInstaller.installing(into: once, events: HookInstaller.codexEvents, command: command)
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
    }

    @Test func changedCommandIsUpdatedInPlaceNotMoved() {
        var root = HookInstaller.installing(into: existing, events: ["Stop"], command: command)
        var hooks = root["hooks"] as! [String: Any]
        var stop = hooks["Stop"] as! [Any]
        stop.append(["hooks": [["type": "command", "command": "added-later.sh"]]])
        hooks["Stop"] = stop
        root["hooks"] = hooks

        let updated = HookInstaller.installing(into: root, events: ["Stop"], command: "'/new/path' hook codex")
        let result = groups(updated, "Stop")
        #expect(result.count == 4)
        #expect(HookInstaller.isOurs(result[2]))
        #expect(((result[2]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "'/new/path' hook codex")
        #expect(((result[3]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "added-later.sh")
    }

    @Test func uninstallRemovesOnlyOurGroups() {
        let merged = HookInstaller.installing(into: existing, events: HookInstaller.codexEvents, command: command)
        let removed = HookInstaller.removing(from: merged)
        #expect(NSDictionary(dictionary: removed).isEqual(to: existing))
    }

    @Test func updateFileBacksUpAndSkipsNoOpWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: file)

        let install = { (root: [String: Any]) in
            HookInstaller.installing(into: root, events: HookInstaller.codexEvents, command: self.command)
        }
        let dry = try HookInstaller.updateFile(at: file, dryRun: true, transform: install)
        #expect(dry.changed && dry.backup == nil)
        #expect(try Data(contentsOf: file) == JSONSerialization.data(withJSONObject: existing), "dry run must not write")

        let first = try HookInstaller.updateFile(at: file, transform: install)
        let backup = try #require(first.backup)
        #expect(first.changed)
        let backedUp = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as! [String: Any]
        #expect(NSDictionary(dictionary: backedUp).isEqual(to: existing))

        let second = try HookInstaller.updateFile(at: file, transform: install)
        #expect(!second.changed && second.backup == nil)
    }

    @Test func backupsWithinTheSameSecondDoNotOverwriteEachOther() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hooks.json")
        let original = try JSONSerialization.data(withJSONObject: existing)
        try original.write(to: file)
        let now = Date()

        let installed = try HookInstaller.updateFile(at: file, now: now) {
            HookInstaller.installing(into: $0, events: ["Stop"], command: self.command)
        }
        let removed = try HookInstaller.updateFile(at: file, now: now, transform: HookInstaller.removing)
        let first = try #require(installed.backup), second = try #require(removed.backup)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == original, "the pristine backup must survive")
    }

    @Test func missingFileIsCreated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".codex/hooks.json")
        let result = try HookInstaller.updateFile(at: file) {
            HookInstaller.installing(into: $0, events: ["Stop"], command: self.command)
        }
        #expect(result.changed && result.backup == nil)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        #expect(groups(root, "Stop").count == 1)
    }

    @Test func refusesNonObjectJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try Data("[1,2]".utf8).write(to: file)
        #expect(throws: HookInstaller.InstallError.self) {
            try HookInstaller.updateFile(at: file) { $0 }
        }
    }
}
