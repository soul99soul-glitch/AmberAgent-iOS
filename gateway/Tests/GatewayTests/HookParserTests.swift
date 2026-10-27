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
        // Push bodies and stored state carry metadata only (design doc section 2 hard constraint).
        let encoded = String(decoding: try GatewayJSON.encoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("SECRET"))
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
