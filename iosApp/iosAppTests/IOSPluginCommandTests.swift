import XCTest
@testable import iosApp

@MainActor
final class IOSPluginCommandTests: XCTestCase {
    func testManifestRequiresStringStdinFieldInStructuredInputSchema() throws {
        for (properties, expectedValid) in [
            (#"{"text":{"type":"string"}}"#, true),
            (#"{"text":{"type":"integer"}}"#, false),
            (#"{}"#, false),
        ] {
            let schema = try IOSPluginJSONSchema.decode(Data(
                "{\"type\":\"object\",\"properties\":\(properties)}".utf8
            ))
            let manifest = IOSPluginManifest(
                id: "stdin_schema", name: "标准输入校验", version: "1.0.0",
                description: "校验命令标准输入字段。",
                tools: [IOSPluginToolManifest(
                    name: "read_text", inputSchema: schema,
                    command: IOSPluginCommandManifest(runtime: .amberShell, entry: "scripts/read.sh", stdinInput: "text")
                )],
                capabilities: IOSPluginCapabilities(localRuntimes: [.amberShell])
            )
            let result = IOSPluginValidator.validate(
                manifest: manifest, recipes: [:], scripts: ["scripts/read.sh": "cat"],
                catalog: IOSDynamicToolRegistry.primitiveCatalogEntry
            )
            XCTAssertEqual(result.isValid, expectedValid, result.issues.joined(separator: "\n"))
            if !expectedValid {
                XCTAssertTrue(result.issues.contains { $0.contains("stdin_input") })
            }
        }
    }

    func testAmberShellInvocationPreservesQuotedInputThroughTheProductionExecutor() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSPluginCommandTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)
        let input = "quote '\n$(touch should-not-run) \"$HOME\""
        let manifest = IOSPluginCommandManifest(
            runtime: .amberShell,
            entry: "scripts/cat.sh",
            stdinInput: "text"
        )

        let invocation = try IOSPluginCommandBuilder.build(
            source: "cat",
            manifest: manifest,
            inputObject: ["text": input],
            timeoutMs: 1_234
        )
        let arguments = try jsonObject(invocation.argumentsJSON)
        XCTAssertEqual(arguments["command"] as? String, "cat")
        XCTAssertEqual(arguments["stdin"] as? String, input)
        XCTAssertEqual((arguments["timeout_seconds"] as? NSNumber)?.intValue, 2)

        let rawOutput = await IOSAmberShellExecuteExecutor.execute(
            input: invocation.argumentsJSON,
            workspaceStore: store
        )
        let parsedOutput = try IOSPluginCommandBuilder.parseOutput(rawOutput, outputType: .string)
        let parsedData = try XCTUnwrap(parsedOutput.data(using: .utf8))
        let parsedInput = try XCTUnwrap(
            JSONSerialization.jsonObject(with: parsedData, options: [.fragmentsAllowed]) as? String
        )
        XCTAssertEqual(parsedInput, input)
        XCTAssertNil(store.fileRecord(idOrPath: "/workspace/should-not-run"))
    }

    func testAmberShellPythonPluginExecutesMultilineSourceWithQuotedData() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSPluginCommandPythonTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)
        let source = """
        import json
        lines = json.loads(input())["text"].splitlines()
        print(json.dumps({"message": "single quote: '", "lines": lines}, separators=(",", ":")))
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = "first line with ' quote\nsecond line"
        let invocation = try IOSPluginCommandBuilder.build(
            source: source,
            manifest: IOSPluginCommandManifest(
                runtime: .amberShell,
                entry: "scripts/transform.py"
            ),
            inputObject: ["text": input],
            timeoutMs: 5_000
        )

        let rawOutput = await IOSAmberShellExecuteExecutor.execute(
            input: invocation.argumentsJSON,
            workspaceStore: store
        )
        XCTAssertEqual(try jsonObject(rawOutput)["ok"] as? Bool, true, rawOutput)
        let parsedOutput = try IOSPluginCommandBuilder.parseOutput(rawOutput, outputType: .object)
        let parsedObject = try jsonObject(parsedOutput)
        XCTAssertEqual(parsedObject["message"] as? String, "single quote: '")
        XCTAssertEqual(parsedObject["lines"] as? [String], ["first line with ' quote", "second line"])
    }

    func testBuilderRejectsInvalidEntryAndUnsafeSourceOrInput() {
        XCTAssertThrowsError(
            try IOSPluginCommandBuilder.build(
                source: "cat",
                manifest: IOSPluginCommandManifest(runtime: .ish, entry: "scripts/tool.py"),
                inputObject: [:],
                timeoutMs: 1_000
            )
        ) { error in
            XCTAssertEqual(
                error as? IOSPluginCommandError,
                .unsupportedEntry(runtime: .ish, entry: "scripts/tool.py")
            )
        }

        XCTAssertThrowsError(
            try IOSPluginCommandBuilder.build(
                source: "cat",
                manifest: IOSPluginCommandManifest(
                    runtime: .amberShell,
                    entry: "scripts/cat.sh",
                    stdinInput: "text"
                ),
                inputObject: ["text": 42],
                timeoutMs: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .inputMustBeString("text"))
        }

        XCTAssertThrowsError(
            try IOSPluginCommandBuilder.build(
                source: "echo a\necho b",
                manifest: IOSPluginCommandManifest(runtime: .amberShell, entry: "scripts/tool.sh"),
                inputObject: [:],
                timeoutMs: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .sourceContainsLineBreaks)
        }

        XCTAssertThrowsError(
            try IOSPluginCommandBuilder.build(
                source: "print(\"bad\0source\")",
                manifest: IOSPluginCommandManifest(runtime: .amberShell, entry: "scripts/tool.py"),
                inputObject: [:],
                timeoutMs: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .sourceContainsNUL)
        }

        XCTAssertThrowsError(
            try IOSPluginCommandBuilder.build(
                source: "printf '%s' \"$1\"",
                manifest: IOSPluginCommandManifest(
                    runtime: .ish,
                    entry: "scripts/tool.sh",
                    stdinInput: "value"
                ),
                inputObject: ["value": "bad\0argument"],
                timeoutMs: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .inputContainsNUL)
        }
    }

    func testOutputParserFailsClosedForRuntimeOutcomesAndDeclaredTypes() throws {
        let timedOut = IOSWorkspaceStore.json([
            "status": "timed_out",
            "timed_out": true,
        ])
        XCTAssertThrowsError(try IOSPluginCommandBuilder.parseOutput(timedOut, outputType: .string)) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .outputTimedOut)
        }

        let cancelled = IOSWorkspaceStore.json([
            "status": "cancelled",
            "timed_out": false,
            "cancelled": true,
        ])
        XCTAssertThrowsError(try IOSPluginCommandBuilder.parseOutput(cancelled, outputType: .string)) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .outputCancelled)
        }

        let unknown = IOSWorkspaceStore.json([
            "status": "unknown_after_action",
            "timed_out": false,
            "may_have_applied": true,
        ])
        XCTAssertThrowsError(try IOSPluginCommandBuilder.parseOutput(unknown, outputType: .string)) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .outputOutcomeUnknown)
        }

        let numericBoolean = IOSWorkspaceStore.json([
            "status": "timed_out",
            "timed_out": 1,
        ])
        XCTAssertThrowsError(try IOSPluginCommandBuilder.parseOutput(numericBoolean, outputType: .string)) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .missingOutputField("timed_out"))
        }

        let truncated = successfulEnvelope(stdout: "partial", stdoutTruncated: true)
        XCTAssertThrowsError(try IOSPluginCommandBuilder.parseOutput(truncated, outputType: .string)) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .outputTruncated(stream: "stdout"))
        }

        let invalidJSON = successfulEnvelope(stdout: "not json")
        XCTAssertThrowsError(try IOSPluginCommandBuilder.parseOutput(invalidJSON, outputType: .object)) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .outputNotJSON)
        }
    }

    func testNonZeroAmberShellExitIsNotAcceptedAsPluginOutput() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSPluginCommandFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = IOSWorkspaceStore(baseDirectory: baseDirectory)
        let rawOutput = await IOSAmberShellExecuteExecutor.execute(
            input: IOSWorkspaceStore.json([
                "command": "command-that-does-not-exist",
                "timeout_seconds": 1,
            ]),
            workspaceStore: store
        )

        XCTAssertThrowsError(try IOSPluginCommandBuilder.parseOutput(rawOutput, outputType: .string)) { error in
            XCTAssertEqual(error as? IOSPluginCommandError, .outputNonZeroExit(127))
        }
    }

    private func successfulEnvelope(
        stdout: String,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) -> String {
        IOSWorkspaceStore.json([
            "status": "completed",
            "ok": true,
            "timed_out": false,
            "cancelled": false,
            "exit_code": 0,
            "stdout_available": true,
            "stderr_available": true,
            "exit_code_available": true,
            "stdout_truncated": stdoutTruncated,
            "stderr_truncated": stderrTruncated,
            "stdout": stdout,
            "stderr": "",
        ])
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
