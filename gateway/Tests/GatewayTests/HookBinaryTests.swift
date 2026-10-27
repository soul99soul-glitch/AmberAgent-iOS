import Darwin
import Foundation
import Testing
@testable import GatewayCore
@testable import GatewayTransport

/// Runs the real `amber-gateway hook` executable the way an agent does.
@Suite("hook entry point (built binary)", .serialized)
struct HookBinaryTests {
    let codexPermission = TestSupport.payload([
        "session_id": "thr_1", "cwd": "/w/b", "hook_event_name": "PermissionRequest", "turn_id": "t1",
        "tool_name": "Bash", "tool_input": ["command": "rm -rf /tmp/x"],
    ])
    let claudeStop = TestSupport.payload([
        "session_id": "s1", "cwd": "/w/a", "hook_event_name": "Stop", "stop_hook_active": false,
        "last_assistant_message": "done",
    ])

    @Test func decisionEventsProduceNoOutputAndSpoolWhenDaemonIsAbsent() throws {
        let bin = try TestSupport.binary()
        let state = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: state) }

        for (source, payload, kind) in [("codex", codexPermission, EventKind.permissionRequest), ("claude", claudeStop, .turnStop)] {
            let r = try TestSupport.run(bin, ["hook", source], stateDir: state, stdin: payload)
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty, "stdout must stay empty: a JSON line here is a decision")
            #expect(r.stderr.isEmpty)
            let events = TestSupport.spooled(state)
            #expect(events.map(\.kind) == [kind])
        }
    }

    @Test func garbageAndUnknownInputIsSilent() throws {
        let bin = try TestSupport.binary()
        let state = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: state) }
        for (args, input) in [
            (["hook", "codex"], Data("{{{".utf8)),
            (["hook", "codex"], TestSupport.payload(["session_id": "x", "hook_event_name": "PreToolUse"])),
            (["hook", "nope"], claudeStop),
            (["hook"], claudeStop),
        ] {
            let r = try TestSupport.run(bin, args, stateDir: state, stdin: input)
            #expect(r.status == 0 && r.stdout.isEmpty && r.stderr.isEmpty, "\(args)")
        }
        #expect(TestSupport.spooled(state).isEmpty)
    }

    /// A daemon that is stopped (SIGSTOP) still has its socket in listen state: connect and write succeed
    /// into the kernel backlog, but no ack ever comes. The hook must give up at its deadline and spool.
    @Test func hungDaemonCostsAtMostTheDeadline() throws {
        let bin = try TestSupport.binary()
        let state = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: state) }
        let paths = GatewayPaths(stateDir: state)
        try paths.ensureDirectories()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd); unlink(paths.socket.path) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            paths.socket.path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 8) == 0)

        let r = try TestSupport.run(bin, ["hook", "claude"], stateDir: state, stdin: claudeStop)
        #expect(r.status == 0 && r.stdout.isEmpty && r.stderr.isEmpty)
        #expect(r.seconds < 0.6, "took \(r.seconds)s")
        #expect(TestSupport.spooled(state).map(\.kind) == [.turnStop])
    }

    /// Claude's native installer names the executable after its version and exposes it through a
    /// `~/.local/bin/claude` symlink; the kernel reports the resolved path (`.../claude/versions/2.1.283`).
    @Test func claudeNativeInstallLayoutIsRecognized() throws {
        let bin = try TestSupport.binary()
        let state = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: state) }
        let real = try TestSupport.fakeAgent(at: "share/claude/versions/2.1.283", in: state)
        let link = state.appendingPathComponent("local-bin/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let payloadFile = state.appendingPathComponent("payload.json")
        try claudeStop.write(to: payloadFile)

        let p = Process()
        p.executableURL = link
        p.arguments = ["-c", "/bin/sh -c '\"\(bin.path)\" hook claude < \"\(payloadFile.path)\"; true'; true"]
        p.environment = [GatewayPaths.stateDirEnv: state.path]
        try p.run()
        p.waitUntilExit()

        let event = try #require(TestSupport.spooled(state).first)
        #expect(event.process?.pid == p.processIdentifier)
        #expect(event.origin == .interactive)
    }

    @Test func processTreeWalkFindsAgentAboveIntermediateShells() throws {
        let bin = try TestSupport.binary()
        let state = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: state) }
        let fakeCodex = try TestSupport.fakeAgent(named: "codex", in: state)
        let payloadFile = state.appendingPathComponent("payload.json")
        try codexPermission.write(to: payloadFile)

        for (extraArgs, origin) in [([String](), SessionOrigin.interactive), (["exec"], .headless)] {
            // agent -> sh -c -> hook; trailing `; true` defeats sh's exec-the-last-command optimisation.
            let inner = "/bin/sh -c '\"\(bin.path)\" hook codex < \"\(payloadFile.path)\"; true'; true"
            let p = Process()
            p.executableURL = fakeCodex
            p.arguments = ["-c", inner] + extraArgs
            p.environment = [GatewayPaths.stateDirEnv: state.path]
            try p.run()
            p.waitUntilExit()

            let event = try #require(TestSupport.spooled(state).first)
            #expect(event.process?.pid == p.processIdentifier, "must resolve to the agent, not an intermediate shell")
            #expect(event.origin == origin)
        }
    }
}
