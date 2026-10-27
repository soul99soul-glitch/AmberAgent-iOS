import Darwin
import Foundation
import Testing
@testable import GatewayCore

/// End-to-end against the real daemon in a throwaway state dir (never touches the user's real state).
@Suite("daemon end-to-end (built binary)", .serialized)
final class DaemonIntegrationTests {
    let bin: URL
    let state: URL
    let paths: GatewayPaths
    let port = TestSupport.freePort()
    var daemon: Process?

    init() throws {
        bin = try TestSupport.binary()
        state = try TestSupport.tempDir()
        paths = GatewayPaths(stateDir: state)
        try TestSupport.payload(["port": Int(port)]).write(to: paths.config)
    }

    deinit {
        if let daemon, daemon.isRunning {
            daemon.terminate()
            daemon.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: state)
    }

    func startDaemon() throws {
        let p = Process()
        p.executableURL = bin
        p.arguments = ["daemon"]
        p.environment = [GatewayPaths.stateDirEnv: state.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        daemon = p
        try #require(TestSupport.eventually { FileManager.default.fileExists(atPath: self.paths.socket.path) })
    }

    func stopDaemon() {
        guard let daemon else { return }
        daemon.terminate()
        daemon.waitUntilExit()
        self.daemon = nil
    }

    func registry() -> Registry { RegistryStore(url: paths.registry).load() }

    func session(_ key: String) -> SessionRecord? { registry().sessions[key] }

    func runs() -> [SessionRecord] {
        registry().sessions.values.filter { $0.agent == .run }.sorted { $0.startedAt < $1.startedAt }
    }

    @Test func runWrapperOutcomes() throws {
        try startDaemon()
        #expect(try TestSupport.run(bin, ["run", "--", "true"], stateDir: state).status == 0)
        #expect(try TestSupport.run(bin, ["run", "--", "false"], stateDir: state).status == 1)
        #expect(try TestSupport.run(bin, ["run", "--", "sh", "-c", "kill -9 $$"], stateDir: state).status == 128 + 9)
        #expect(try TestSupport.run(bin, ["run", "--", "/nonexistent/cmd"], stateDir: state).status == 127)

        #expect(TestSupport.eventually { self.runs().count == 4 && !self.runs().contains(where: \.isOpen) })
        let outcomes = runs().map { "\($0.title ?? "?"):\($0.state.rawValue):\($0.abnormal)" }
        #expect(outcomes == ["true:completed:false", "false:stopped:true", "sh:stopped:true", "cmd:stopped:true"])
        #expect(TestSupport.spooled(state).isEmpty, "daemon was up: nothing should have been spooled")
    }

    @Test func killedInteractiveAgentIsDetectedInSeconds() throws {
        try startDaemon()
        let fakeClaude = try TestSupport.fakeAgent(named: "claude", in: state)
        let payloadFile = state.appendingPathComponent("start.json")
        try TestSupport.payload(["session_id": "live-1", "cwd": "/w/amber", "hook_event_name": "SessionStart", "source": "startup"])
            .write(to: payloadFile)

        let agent = Process()
        agent.executableURL = fakeClaude
        agent.arguments = ["-c", "\"\(bin.path)\" hook claude < \"\(payloadFile.path)\"; while :; do /bin/sleep 1; done"]
        agent.environment = [GatewayPaths.stateDirEnv: state.path]
        try agent.run()

        try #require(TestSupport.eventually { self.session("claude:live-1")?.process?.pid == agent.processIdentifier })
        #expect(session("claude:live-1")?.state == .running)

        let killedAt = Date()
        kill(agent.processIdentifier, SIGKILL)
        agent.waitUntilExit()
        #expect(TestSupport.eventually(timeout: 3) { self.session("claude:live-1")?.state == .stopped })
        #expect(Date().timeIntervalSince(killedAt) < 2)
        #expect(session("claude:live-1")?.abnormal == true)
        #expect(Outbox(url: paths.outbox).recent(limit: 5).contains { $0.sessionKey == "claude:live-1" && $0.abnormal })
    }

    @Test func spoolIsReplayedAndStateSurvivesRestart() throws {
        try startDaemon()
        #expect(try TestSupport.run(bin, ["run", "--", "true"], stateDir: state).status == 0)
        #expect(TestSupport.eventually { self.runs().count == 1 })
        stopDaemon()

        let payload = TestSupport.payload(["session_id": "offline-1", "cwd": "/w/x", "hook_event_name": "UserPromptSubmit", "prompt": "p"])
        #expect(try TestSupport.run(bin, ["hook", "codex"], stateDir: state, stdin: payload).status == 0)
        #expect(!Spool(dir: paths.spoolDir).isEmpty())

        try startDaemon()
        #expect(TestSupport.eventually { self.session("codex:offline-1")?.state == .running })
        #expect(Spool(dir: paths.spoolDir).isEmpty())
        #expect(runs().count == 1, "registry persisted across restart")
    }

    @Test func secondDaemonRefusesToStart() throws {
        try startDaemon()
        let r = try TestSupport.run(bin, ["daemon"], stateDir: state)
        #expect(r.status == 1)
        #expect(daemon?.isRunning == true)
    }

    @Test func statusJsonWorksWithDaemonDown() throws {
        let r = try TestSupport.run(bin, ["status", "--json"], stateDir: state)
        #expect(r.status == 0)
        let object = try JSONSerialization.jsonObject(with: r.stdout) as? [String: Any]
        #expect(object?["daemonRunning"] as? Bool == false)
    }
}
