import XCTest
@testable import iosApp

@MainActor
final class IOSAmberShellTests: XCTestCase {
    func testCoreFileCommandsStayInsideInjectedWorkspaceAndKeepIndex() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAmberShellTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)

        try await assertSuccess("mkdir notes", store: store)
        try await assertSuccess("touch notes/empty.txt", store: store)
        let seeded = await store.executeTool(
            toolName: "workspace_file_write",
            input: IOSWorkspaceStore.json([
                "path": "/workspace/notes/source.txt",
                "content": "one two\nthree\n",
            ])
        )
        XCTAssertEqual(try jsonObject(seeded)["ok"] as? Bool, true)

        let pwd = try await output("pwd", store: store)
        let echo = try await output(#"echo "hello world""#, store: store)
        let cat = try await output("cat notes/source.txt", store: store)
        let head = try await output("head -n 1 notes/source.txt", store: store)
        let tail = try await output("tail -n 1 notes/source.txt", store: store)
        let wc = try await output("wc -l notes/source.txt", store: store)
        XCTAssertEqual(pwd, "/workspace\n")
        XCTAssertEqual(echo, "hello world\n")
        XCTAssertEqual(cat, "one two\nthree\n")
        XCTAssertEqual(head, "one two\n")
        XCTAssertEqual(tail, "three\n")
        XCTAssertEqual(wc, "2 notes/source.txt\n")

        let pipeline = try await output(
            "cat | grep needle | sort",
            stdin: "z\nneedle two\nneedle\n",
            store: store
        )
        XCTAssertEqual(pipeline, "needle\nneedle two\n")

        let redirected = await IOSAmberShellEngine.execute(
            command: "cat < notes/source.txt > notes/stdout.txt 2> notes/stderr.txt",
            workspaceStore: store
        )
        XCTAssertEqual(redirected.exitCode, 0, redirected.stderr)
        XCTAssertEqual(redirected.stdout, "")
        XCTAssertEqual(redirected.stderr, "")
        XCTAssertEqual(try store.amberShellReadText(path: "notes/stdout.txt", maxBytes: 64 * 1024), "one two\nthree\n")
        XCTAssertEqual(try store.amberShellReadText(path: "notes/stderr.txt", maxBytes: 64 * 1024), "")

        let formatted = try await output(#"printf "%s:%d:%%\n" amber 7"#, store: store)
        let counted = try await output("uniq -c", stdin: "a\na\nb\n", store: store)
        let cut = try await output("cut -d , -f 2", stdin: "a,b\nc,d\n", store: store)
        let translated = try await output("tr ab AB", stdin: "a cab\n", store: store)
        let expanded = try await output("echo $PWD", store: store)
        let basename = try await output("basename /workspace/notes/source.txt", store: store)
        let dirname = try await output("dirname /workspace/notes/source.txt", store: store)
        let environment = try await output("env", store: store)
        let uname = try await output("uname -s", store: store)
        XCTAssertEqual(formatted, "amber:7:%\n")
        XCTAssertEqual(counted, "2 a\n1 b\n")
        XCTAssertEqual(cut, "b\nd\n")
        XCTAssertEqual(translated, "A cAB\n")
        XCTAssertEqual(expanded, "/workspace\n")
        XCTAssertEqual(basename, "source.txt\n")
        XCTAssertEqual(dirname, "/workspace/notes\n")
        XCTAssertTrue(environment.contains("PWD=/workspace\n"))
        XCTAssertEqual(uname, "Darwin\n")

        try await assertSuccess("touch notes/source.txt", store: store)
        let contentAfterTouch = try await output("cat notes/source.txt", store: store)
        XCTAssertEqual(contentAfterTouch, "one two\nthree\n")
        try await assertSuccess("cp notes/source.txt notes/copied.txt", store: store)
        try await assertSuccess("mv notes/copied.txt notes/moved.txt", store: store)
        let listing = try await output("ls notes", store: store)
        XCTAssertTrue(listing.contains("empty.txt"))
        XCTAssertTrue(listing.contains("moved.txt"))
        XCTAssertTrue(listing.contains("source.txt"))
        try await assertSuccess("rm notes/moved.txt", store: store)

        let reloaded = IOSWorkspaceStore(baseDirectory: baseDirectory)
        XCTAssertNotNil(reloaded.fileRecord(idOrPath: "/workspace/notes/source.txt"))
        XCTAssertNotNil(reloaded.fileRecord(idOrPath: "/workspace/notes/empty.txt"))
        XCTAssertNil(reloaded.fileRecord(idOrPath: "/workspace/notes/moved.txt"))
    }

    func testParserRejectsUnsafeSyntaxAndEnforcesStreamBounds() async {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAmberShellSafetyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)

        let traversal = await IOSAmberShellEngine.execute(command: "cat ../secret", workspaceStore: store)
        XCTAssertNotEqual(traversal.exitCode, 0)
        XCTAssertTrue(traversal.stderr.contains("..") || traversal.stderr.contains("路径"))

        let unknown = await IOSAmberShellEngine.execute(command: "curl example.com", workspaceStore: store)
        XCTAssertEqual(unknown.exitCode, 127)
        XCTAssertTrue(unknown.stderr.contains("当前不支持命令"))

        for command in [
            "echo a || echo b", "echo a && echo b", "echo a; echo b", "echo a >> notes/out.txt",
            "cat << notes/source.txt", "echo a 2>&1", "echo `pwd`", "echo $(pwd)", "echo *.txt",
            "UNKNOWN=value echo ok", "echo \"unterminated",
        ] {
            let rejected = await IOSAmberShellEngine.execute(command: command, workspaceStore: store)
            XCTAssertNotEqual(rejected.exitCode, 0, command)
        }

        let exactInput = String(repeating: "x", count: 64 * 1024)
        let exact = await IOSAmberShellEngine.execute(
            command: "wc -c",
            stdin: exactInput,
            workspaceStore: store
        )
        XCTAssertEqual(exact.exitCode, 0, exact.stderr)
        XCTAssertEqual(exact.stdout, "65536\n")

        let oversized = await IOSAmberShellEngine.execute(
            command: "wc -c",
            stdin: exactInput + "x",
            workspaceStore: store
        )
        XCTAssertEqual(oversized.exitCode, 64)
        XCTAssertTrue(oversized.stderr.contains("65536 UTF-8 bytes"))

        let conflictingInput = await IOSAmberShellEngine.execute(
            command: "cat < notes/source.txt",
            stdin: "explicit",
            workspaceStore: store
        )
        XCTAssertEqual(conflictingInput.exitCode, 64)
        XCTAssertTrue(conflictingInput.stderr.contains("stdin"))

        let explicitEmptyInput = await IOSAmberShellEngine.execute(
            command: "cat < notes/source.txt",
            stdin: "",
            workspaceStore: store
        )
        XCTAssertEqual(explicitEmptyInput.exitCode, 64)
        XCTAssertTrue(explicitEmptyInput.stderr.contains("stdin"))

        let sameOutput = await IOSAmberShellEngine.execute(
            command: "echo x > notes/same.txt 2> /workspace/notes/same.txt",
            workspaceStore: store
        )
        XCTAssertEqual(sameOutput.exitCode, 64)
        XCTAssertTrue(sameOutput.stderr.contains("stdout 与 stderr"))

        let quotedFD = await IOSAmberShellEngine.execute(
            command: #"echo "2"> quoted.txt"#,
            workspaceStore: store
        )
        XCTAssertEqual(quotedFD.exitCode, 0, quotedFD.stderr)
        XCTAssertEqual(
            try? store.amberShellReadText(path: "quoted.txt", maxBytes: 64 * 1024),
            "2\n"
        )

        let invalidRedirect = await IOSAmberShellEngine.execute(
            command: "touch created-before-redirect.txt > missing/out.txt",
            workspaceStore: store
        )
        XCTAssertNotEqual(invalidRedirect.exitCode, 0)
        XCTAssertNil(store.fileRecord(idOrPath: "/workspace/created-before-redirect.txt"))
    }

    func testStdinUTF8ByteLimitUsesExactASCIIAndUnicodeBoundaries() async {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAmberShellUTF8LimitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)
        let cases: [(label: String, input: String, bytes: Int)] = [
            ("ASCII-65535", utf8String(using: "x", bytes: 65_535), 65_535),
            ("ASCII-65536", utf8String(using: "x", bytes: 65_536), 65_536),
            ("ASCII-65537", utf8String(using: "x", bytes: 65_537), 65_537),
            ("CJK-65535", utf8String(using: "中", bytes: 65_535), 65_535),
            ("CJK-65536", utf8String(using: "中", bytes: 65_536), 65_536),
            ("CJK-65537", utf8String(using: "中", bytes: 65_537), 65_537),
            ("emoji-65535", utf8String(using: "😀", bytes: 65_535), 65_535),
            ("emoji-65536", utf8String(using: "😀", bytes: 65_536), 65_536),
            ("emoji-65537", utf8String(using: "😀", bytes: 65_537), 65_537),
        ]

        for testCase in cases {
            XCTAssertEqual(testCase.input.utf8.count, testCase.bytes, testCase.label)
            let result = await IOSAmberShellEngine.execute(
                command: "wc -c",
                stdin: testCase.input,
                workspaceStore: store
            )
            if testCase.bytes <= IOSAmberShellInputContract.maxStdinBytes {
                XCTAssertEqual(result.exitCode, 0, testCase.label)
                XCTAssertEqual(result.stdout, "\(testCase.bytes)\n", testCase.label)
            } else {
                XCTAssertEqual(result.exitCode, 64, testCase.label)
                XCTAssertTrue(
                    result.stderr.contains("\(IOSAmberShellInputContract.maxStdinBytes) UTF-8 bytes"),
                    testCase.label
                )
            }
        }
    }

    func testEmbeddedPythonExecutesAllowlistedCodeAndRejectsHostModules() async {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAmberShellPythonTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)

        let math = await IOSAmberShellEngine.execute(
            command: #"python -c "from math import factorial; print(factorial(6))""#,
            workspaceStore: store
        )
        XCTAssertEqual(math.exitCode, 0, math.stderr)
        XCTAssertEqual(math.stdout, "720\n")

        let pipeline = await IOSAmberShellEngine.execute(
            command: #"printf "2 3\n" | python -c "print(sum(map(int, input().split())))""#,
            workspaceStore: store
        )
        XCTAssertEqual(pipeline.exitCode, 0, pipeline.stderr)
        XCTAssertEqual(pipeline.stdout, "5\n")

        let blocked = await IOSAmberShellEngine.execute(
            command: #"python -c "import os""#,
            workspaceStore: store
        )
        XCTAssertNotEqual(blocked.exitCode, 0)
        XCTAssertTrue(blocked.stderr.contains("not allowlisted"))
    }

    func testEmbeddedPythonRejectsModuleMutationAndDoesNotLeakAcrossJobs() async {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAmberShellPythonIsolationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)

        let jsonMutation = await IOSAmberShellEngine.execute(
            command: #"python -c "import json; json.amber_state = input()""#,
            stdin: "bridge-secret\n",
            workspaceStore: store
        )
        XCTAssertNotEqual(jsonMutation.exitCode, 0)
        XCTAssertTrue(jsonMutation.stderr.contains("module attributes are read-only"))

        let jsonRead = await IOSAmberShellEngine.execute(
            command: #"python -c "import json; print(json.amber_state)""#,
            workspaceStore: store
        )
        XCTAssertNotEqual(jsonRead.exitCode, 0)
        XCTAssertTrue(jsonRead.stderr.contains("AttributeError"), jsonRead.stderr)

        let mathMutation = await IOSAmberShellEngine.execute(
            command: #"python -c "import math; math.pi = 0""#,
            workspaceStore: store
        )
        XCTAssertNotEqual(mathMutation.exitCode, 0)
        XCTAssertTrue(mathMutation.stderr.contains("module attributes are read-only"))

        let mathRead = await IOSAmberShellEngine.execute(
            command: #"python -c "import math; print(math.pi > 3)""#,
            workspaceStore: store
        )
        XCTAssertEqual(mathRead.exitCode, 0, mathRead.stderr)
        XCTAssertEqual(mathRead.stdout, "True\n")
    }

    func testEmbeddedPythonTimeoutCancellationAndReuse() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAmberShellLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)
        let loopCommand = #"python -c "while True: pass""#

        let timedOutJSON = await IOSAmberShellExecuteExecutor.execute(
            input: IOSWorkspaceStore.json([
                "command": loopCommand,
                "timeout_seconds": 1,
            ]),
            workspaceStore: store
        )
        let timedOut = try jsonObject(timedOutJSON)
        XCTAssertEqual(timedOut["status"] as? String, IOSTerminalJobStatus.timedOut.rawValue)
        XCTAssertEqual(timedOut["timed_out"] as? Bool, true)
        XCTAssertTrue(timedOut["exit_code"] is NSNull)

        let cancelledTask = Task { @MainActor in
            await IOSAmberShellExecuteExecutor.execute(
                input: IOSWorkspaceStore.json([
                    "command": loopCommand,
                    "timeout_seconds": 60,
                ]),
                workspaceStore: store
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelledTask.cancel()
        let cancelled = try jsonObject(await cancelledTask.value)
        XCTAssertEqual(cancelled["status"] as? String, IOSTerminalJobStatus.cancelled.rawValue)
        XCTAssertEqual(cancelled["timed_out"] as? Bool, false)
        XCTAssertTrue(cancelled["exit_code"] is NSNull)

        let reused = await IOSAmberShellEngine.execute(
            command: #"python -c "print(6 * 7)""#,
            workspaceStore: store
        )
        XCTAssertEqual(reused.exitCode, 0, reused.stderr)
        XCTAssertEqual(reused.stdout, "42\n")
    }

    private func assertSuccess(
        _ command: String,
        store: IOSWorkspaceStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = await IOSAmberShellEngine.execute(command: command, workspaceStore: store)
        XCTAssertEqual(result.exitCode, 0, result.stderr, file: file, line: line)
    }

    private func output(_ command: String, store: IOSWorkspaceStore) async throws -> String {
        try await output(command, stdin: nil, store: store)
    }

    private func output(_ command: String, stdin: String?, store: IOSWorkspaceStore) async throws -> String {
        let result = await IOSAmberShellEngine.execute(command: command, stdin: stdin, workspaceStore: store)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        return result.stdout
    }

    private func utf8String(using scalar: String, bytes: Int) -> String {
        let scalarBytes = scalar.utf8.count
        let repetitions = bytes / scalarBytes
        let remainder = bytes % scalarBytes
        return String(repeating: scalar, count: repetitions)
            + String(repeating: "x", count: remainder)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
