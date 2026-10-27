import Foundation
import Testing
@testable import GatewayCore
@testable import HookIngest

struct HookMappingCase: Sendable, CustomTestStringConvertible {
    var source: AgentKind
    var expect: EventKind?
    var payload: Data
    var label: String

    var testDescription: String { label }
}

private func loadMappings() throws -> [HookMappingCase] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/hooks/hook-mapping", withExtension: "json"))
    let array = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    return try array.map { item in
        let payload = try #require(item["payload"] as? [String: Any])
        let source = try #require(AgentKind(rawValue: item["source"] as? String ?? ""))
        let expect = (item["expect"] as? String).flatMap(EventKind.init(rawValue:))
        let name = payload["hook_event_name"] as? String ?? "?"
        let type = payload["notification_type"] as? String
        return HookMappingCase(
            source: source,
            expect: expect,
            payload: try JSONSerialization.data(withJSONObject: payload),
            label: "\(source.rawValue) \(name)\(type.map { "/\($0)" } ?? "") -> \(expect?.rawValue ?? "ignored")"
        )
    }
}

@Suite("Hook payload mapping")
struct HookParserTests {
    @Test(arguments: try loadMappings())
    func mapping(_ c: HookMappingCase) throws {
        let event = HookParser.parse(source: c.source, payload: c.payload)
        #expect(event?.kind == c.expect)
        guard let event else { return }
        #expect(event.agent == c.source)
        // Metadata only, except the prompt excerpt that names the task on the phone.
        var stripped = event
        stripped.summary = nil
        stripped.opening = nil
        let encoded = String(decoding: try GatewayJSON.encoder().encode(stripped), as: UTF8.self)
        #expect(!encoded.contains("SECRET"))
        #expect((event.summary != nil) == (event.kind == .promptSubmit))
    }

    @Test func promptSummaryNamesTheTaskButNeverReachesAPush() throws {
        let long = "  在 /Users/mi/Downloads/AI/amber-macos（分支 feat/macos）实现「定时任务」功能，\n\n先读这些计划文档再动手  "
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": "s", "cwd": "/Users/mi", "hook_event_name": "UserPromptSubmit", "prompt": long])
        let event = try #require(HookParser.parse(source: .claude, payload: payload))
        let summary = try #require(event.summary)
        #expect(summary.count == HookParser.summaryLimit && summary.hasSuffix("…") && summary.hasPrefix("在 /Users/mi"))
        #expect(!summary.contains("\n"))

        var registry = Registry()
        let away = { Presence(screenLocked: true, idleSeconds: 999) }
        _ = registry.ingest(event, config: GatewayConfig(), now: Date(), presence: away)
        var second = event
        second.id = "second"; second.summary = "后来的一句"; second.timestamp = event.timestamp.addingTimeInterval(1)
        _ = registry.ingest(second, config: GatewayConfig(), now: Date(), presence: away)
        #expect(registry.sessions["claude:s"]?.summary == summary, "the first prompt keeps naming the task")
        #expect(HookParser.summary("<task-notification> <task-id>b1</task-id> completed") == nil, "host-injected turns are not titles")
        #expect(registry.sessions["claude:s"]?.opening?.hasPrefix("在 /Users/mi/Downloads/AI/amber-macos（分支 feat/macos）实现「定时任务」功能， 先读这些") == true)

        let before = try #require(registry.sessions["claude:s"])
        var retitle = GatewayEvent(agent: .claude, kind: .retitle, sessionId: "s", timestamp: event.timestamp.addingTimeInterval(-60), title: "Amber 定时任务实现")
        retitle.id = "retitle"
        #expect(registry.ingest(retitle, config: GatewayConfig(), now: Date(), presence: away).isEmpty)
        let after = try #require(registry.sessions["claude:s"])
        #expect(after.generatedTitle == "Amber 定时任务实现")
        #expect(after.updatedAt == before.updatedAt && after.state == before.state, "a title never reorders or reopens a task")
        var stray = retitle
        stray.id = "stray"; stray.sessionId = "unknown"
        _ = registry.ingest(stray, config: GatewayConfig(), now: Date(), presence: away)
        #expect(registry.sessions["claude:unknown"] == nil)

        var stop = event
        stop.id = "stop"; stop.kind = .turnStop; stop.summary = nil; stop.timestamp = event.timestamp.addingTimeInterval(2)
        let effects = registry.ingest(stop, config: GatewayConfig(), now: Date(), presence: away)
        let pushes = effects.compactMap { if case .push(let p) = $0 { p } else { nil } }
        #expect(pushes.count == 1)
        let text = PushContent.render(pushes[0], gatewayName: "Mac")
        #expect(text.title == "Claude Code · mi", "the lock screen still names the directory, never the prompt")
        #expect(!(text.title + text.body).contains("定时任务"))
    }

    @Test func malformedPayloadIsIgnored() {
        #expect(HookParser.parse(source: .codex, payload: Data("not json".utf8)) == nil)
        #expect(HookParser.parse(source: .codex, payload: Data()) == nil)
    }

    @Test func originClassification() {
        let appServer = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                         "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"]
        #expect(AgentProcess.origin(source: .codex, arguments: appServer) == .host)
        // Codex ≥ 0.157 runs terminal (TUI) sessions inside a CLI-managed app-server daemon: still a human at a terminal.
        let managedDaemon = ["/Users/u/.codex/packages/app-server-daemon/releases/0.158.0-aarch64-apple-darwin/bin/codex",
                             "app-server", "--listen", "unix://", "--managed-daemon"]
        #expect(AgentProcess.origin(source: .codex, arguments: managedDaemon) == .interactive)
        // Shared by every TUI session and replaced on upgrade: its exit says nothing about any one session.
        #expect(!AgentProcess.ownsSession(arguments: managedDaemon))
        #expect(AgentProcess.ownsSession(arguments: ["codex"]))
        #expect(AgentProcess.origin(source: .codex, arguments: ["codex", "exec", "fix it"]) == .headless)
        #expect(AgentProcess.origin(source: .codex, arguments: ["codex"]) == .interactive)
        #expect(AgentProcess.origin(source: .codex, arguments: ["codex", "resume", "--last"]) == .interactive)
        #expect(AgentProcess.origin(source: .claude, arguments: ["claude", "-p", "hi"]) == .headless)
        #expect(AgentProcess.origin(source: .claude, arguments: ["claude", "--print"]) == .headless)
        #expect(AgentProcess.origin(source: .claude, arguments: ["claude", "--output-format", "stream-json", "--input-format", "stream-json", "-p"]) == .host)
        #expect(AgentProcess.origin(source: .claude, arguments: ["claude", "--continue"]) == .interactive)
    }

    /// The outermost bundle names the host, so a session spawned from a helper still reads as its app.
    @Test func hostAppName() {
        #expect(AgentProcess.hostApp(path: "/Applications/Synara.app/Contents/MacOS/Synara") == "Synara")
        #expect(AgentProcess.hostApp(path: "/Applications/Synara.app/Contents/Frameworks/Synara Helper.app/Contents/MacOS/Synara Helper") == "Synara")
        #expect(AgentProcess.hostApp(path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex") == "ChatGPT")
        #expect(AgentProcess.hostApp(path: "/usr/local/bin/node") == nil)
    }
}
