import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
final class IOSWorkspaceTerminalToolTests: IOSWebMountToolTestCase {
    func testAmberShellRequiresApprovalAndHighRiskAutoApproveRunsPwd() async throws {
        let executor = makeExecutor()
        let input = #"{"command":"pwd","purpose":"inspect workspace"}"#

        let blocked = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: IOSAmberShellToolCatalog.executeToolName,
                operation: input,
                scopeDigest: "scope",
                payloadDigest: "payload",
                isUserInitiated: false
            )
        )
        guard case .needsUserAction(let reason) = blocked else {
            return XCTFail("Expected AmberShell approval, got \(blocked)")
        }
        XCTAssertTrue(reason.contains("AmberShell"))

        let highRiskAutoApproved = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: IOSAmberShellToolCatalog.executeToolName,
                operation: input,
                scopeDigest: "scope",
                payloadDigest: "payload",
                isUserInitiated: false,
                executionPolicy: IOSExecutionPolicySnapshot(
                    capabilityPolicies: [:],
                    globalAutoApproveEnabled: false,
                    highRiskAutoApproveEnabled: true,
                    execJavaScriptEnabled: false,
                    webSearchEnabled: false
                )
            )
        )
        guard case .terminalResult(let autoApprovedResult) = highRiskAutoApproved else {
            return XCTFail("High-risk auto-approval must run AmberShell, got \(highRiskAutoApproved)")
        }
        XCTAssertEqual(try jsonObject(autoApprovedResult)["stdout"] as? String, "/workspace\n")

        let preview = try XCTUnwrap(
            executor.terminalApprovalPreview(
                toolName: IOSAmberShellToolCatalog.executeToolName,
                input: input
            )
        )
        XCTAssertEqual(preview.mode, .amberShell)
        XCTAssertEqual(preview.capabilityId, "ios.local.ambershell")
        XCTAssertEqual(preview.commandPreview, "pwd")
        XCTAssertEqual(
            preview.title,
            IOSAppLocalization.string("执行 AmberShell", defaultValue: "执行 AmberShell")
        )
        XCTAssertTrue(preview.contextLines.contains(
            IOSAppLocalization.formatted(
                "超时：%lld 秒（协作式）",
                defaultValue: "超时：%lld 秒（协作式）",
                arguments: [Int64(60)]
            )
        ))

        let output = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: IOSAmberShellToolCatalog.executeToolName,
                operation: input,
                scopeDigest: "scope",
                payloadDigest: "payload",
                isUserInitiated: true
            )
        )
        guard case .terminalResult(let result) = output else {
            return XCTFail("Expected AmberShell terminal result, got \(output)")
        }
        let object = try jsonObject(result)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["tool"] as? String, IOSAmberShellToolCatalog.executeToolName)
        XCTAssertEqual(object["runtime"] as? String, IOSTerminalRuntimeKind.localIOSTools.rawValue)
        XCTAssertEqual(object["cwd"] as? String, "/workspace")
        XCTAssertEqual(object["stdout"] as? String, "/workspace\n")
        XCTAssertEqual(object["stderr"] as? String, "")
        XCTAssertEqual(object["exit_code"] as? Int, 0)
    }

    func testAmberShellRejectsInvalidTimeoutValues() async throws {
        for timeout in ["true", "1.5", "0", "181"] {
            let result = await IOSAmberShellExecuteExecutor.execute(
                input: "{\"command\":\"pwd\",\"timeout_seconds\":\(timeout)}",
                workspaceStore: makeWorkspaceStore()
            )
            let object = try jsonObject(result)
            XCTAssertEqual(object["status"] as? String, IOSTerminalJobStatus.failed.rawValue, timeout)
            XCTAssertTrue((object["error"] as? String)?.contains("timeout_seconds") == true, timeout)
        }
    }

    func testAmberShellStdinUTF8BoundaryMatchesApprovalAndExecution() async throws {
        let store = makeWorkspaceStore()
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
            let input = IOSWorkspaceStore.json([
                "command": "wc -c",
                "stdin": testCase.input,
            ])
            let preview = IOSAmberShellExecuteExecutor.approvalPreview(input: input)
            let output = await IOSAmberShellExecuteExecutor.execute(
                input: input,
                workspaceStore: store
            )
            let object = try jsonObject(output)

            if testCase.bytes <= IOSAmberShellInputContract.maxStdinBytes {
                XCTAssertNotNil(preview, testCase.label)
                let previewByteDigits = preview?.contextLines
                    .last(where: { $0.lowercased().contains("stdin") })?
                    .filter { $0.isNumber }
                XCTAssertEqual(
                    previewByteDigits,
                    "\(testCase.bytes)",
                    "\(testCase.label): \(preview?.contextLines ?? [])"
                )
                XCTAssertEqual(object["status"] as? String, IOSTerminalJobStatus.completed.rawValue, testCase.label)
                XCTAssertEqual(object["stdout"] as? String, "\(testCase.bytes)\n", testCase.label)
            } else {
                XCTAssertNil(preview, testCase.label)
                XCTAssertEqual(object["status"] as? String, IOSTerminalJobStatus.failed.rawValue, testCase.label)
                XCTAssertTrue(
                    (object["error"] as? String)?.contains(
                        "\(IOSAmberShellInputContract.maxStdinBytes) UTF-8 bytes"
                    ) == true,
                    testCase.label
                )
            }
        }
    }

    func testAmberShellLsReadsTheWorkspaceRoot() async throws {
        let store = makeWorkspaceStore()
        let fileName = "ambershell-phase1-\(UUID().uuidString).txt"
        let writeResult = await store.executeTool(
            toolName: "workspace_file_write",
            input: IOSWorkspaceStore.json([
                "path": "/workspace/\(fileName)",
                "content": "phase1",
            ])
        )
        let fileId = try XCTUnwrap(jsonObject(writeResult)["id"] as? String)
        defer { try? store.removeFile(id: fileId) }

        let output = await makeExecutor(workspaceStore: store).execute(
            IOSLocalToolExecutionRequest(
                toolName: IOSAmberShellToolCatalog.executeToolName,
                operation: #"{"command":"ls"}"#,
                scopeDigest: "scope",
                payloadDigest: "payload",
                isUserInitiated: true
            )
        )
        guard case .terminalResult(let result) = output else {
            return XCTFail("Expected AmberShell ls result, got \(output)")
        }
        XCTAssertTrue((try jsonObject(result)["stdout"] as? String)?.contains(fileName) == true)
    }

    func testAmberShellPipelineUsesInjectedStdinAndWorkspace() async throws {
        let store = makeWorkspaceStore()
        try store.amberShellCreateDirectory(path: "notes")
        let input = IOSWorkspaceStore.json([
            "command": "sort | uniq -c > notes/counts.txt",
            "stdin": "b\na\nb\n",
            "purpose": "count sorted lines",
        ])

        let output = await makeExecutor(workspaceStore: store).execute(
            IOSLocalToolExecutionRequest(
                toolName: IOSAmberShellToolCatalog.executeToolName,
                operation: input,
                scopeDigest: "scope",
                payloadDigest: "payload",
                isUserInitiated: true
            )
        )
        guard case .terminalResult(let result) = output else {
            return XCTFail("Expected AmberShell terminal result, got \(output)")
        }
        let object = try jsonObject(result)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["stdout"] as? String, "")
        XCTAssertEqual(
            try store.amberShellReadText(path: "notes/counts.txt", maxBytes: 64 * 1024),
            "1 a\n2 b\n"
        )
    }

    func testWorkspaceReadRequiresApprovalAndReturnsImportedText() async throws {
        let workspaceStore = makeWorkspaceStore()
        let file = try makeTempFile(text: "# Workspace\nReadable file context.", extension: "md")
        let record = try await workspaceStore.importFile(url: file, source: "test")
        let executor = makeExecutor(workspaceStore: workspaceStore)

        let blocked = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_file_read",
                operation: #"{"file_id":"\#(record.id)"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )
        guard case .needsUserAction(let reason) = blocked else {
            return XCTFail("Expected approval requirement, got \(blocked)")
        }
        XCTAssertTrue(reason.contains("Workspace reads"))

        let allowed = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_file_read",
                operation: #"{"path":"/workspace/\#(record.workspacePath)"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: true
            )
        )
        guard case .workspaceResult(let text) = allowed else {
            return XCTFail("Expected Workspace result, got \(allowed)")
        }
        let object = try jsonObject(text)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertTrue((object["text"] as? String)?.contains("Readable file context") == true)
    }

    func testWorkspaceWriteRequiresApprovalAndRejectsTraversal() async throws {
        let workspaceStore = makeWorkspaceStore()
        let executor = makeExecutor(workspaceStore: workspaceStore)
        let input = #"{"path":"/workspace/notes/summary.md","content":"hello workspace"}"#

        let blocked = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_file_write",
                operation: input,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )
        guard case .needsUserAction(let reason) = blocked else {
            return XCTFail("Expected write approval requirement, got \(blocked)")
        }
        XCTAssertTrue(reason.contains("writes"))

        let written = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_file_write",
                operation: input,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: true
            )
        )
        guard case .workspaceResult(let writeText) = written else {
            return XCTFail("Expected write result, got \(written)")
        }
        XCTAssertEqual(try jsonObject(writeText)["ok"] as? Bool, true)

        let traversal = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_file_write",
                operation: #"{"path":"../secrets.txt","content":"nope"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: true
            )
        )
        guard case .workspaceResult(let traversalText) = traversal else {
            return XCTFail("Expected traversal failure result, got \(traversal)")
        }
        let traversalObject = try jsonObject(traversalText)
        XCTAssertEqual(traversalObject["ok"] as? Bool, false)
        XCTAssertTrue((traversalObject["error"] as? String)?.contains("traversal") == true)
    }

    /// Jev 自动批准复核收紧时依赖此事实：关闭自动批准的快照让写入回到审批卡。
    func testWithoutAutoApproveSnapshotRestoresWorkspaceWriteApproval() async throws {
        let executor = makeExecutor(workspaceStore: makeWorkspaceStore())
        let input = #"{"path":"/workspace/notes/gate.md","content":"gate"}"#
        let autoApprove = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:], globalAutoApproveEnabled: true,
            highRiskAutoApproveEnabled: true, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        func run(_ policy: IOSExecutionPolicySnapshot) async -> IOSLocalToolExecutionOutput {
            await executor.execute(IOSLocalToolExecutionRequest(
                toolName: "workspace_file_write", operation: input, scopeDigest: "", payloadDigest: "",
                isUserInitiated: false, executionPolicy: policy
            ))
        }
        guard case .workspaceResult = await run(autoApprove) else {
            return XCTFail("自动批准下写入应直接执行")
        }
        guard case .needsUserAction = await run(autoApprove.withoutAutoApprove()) else {
            return XCTFail("关闭自动批准后写入应回到审批")
        }
    }

    func testWorkspaceArtifactReadAndDeleteUseApproval() async throws {
        let workspaceStore = makeWorkspaceStore()
        let artifact = try workspaceStore.saveArtifact(
            title: "Report",
            content: "artifact body",
            type: .chat,
            sourceKind: "test"
        )
        let executor = makeExecutor(workspaceStore: workspaceStore)

        let blockedRead = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_artifact_read",
                operation: #"{"artifact_id":"\#(artifact.id)"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )
        guard case .needsUserAction = blockedRead else {
            return XCTFail("Expected read approval, got \(blockedRead)")
        }

        let read = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_artifact_read",
                operation: #"{"artifact_id":"\#(artifact.id)"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: true
            )
        )
        guard case .workspaceResult(let readText) = read else {
            return XCTFail("Expected artifact read, got \(read)")
        }
        XCTAssertEqual(try jsonObject(readText)["content"] as? String, "artifact body")

        let blockedDelete = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_artifact_delete",
                operation: #"{"artifact_id":"\#(artifact.id)"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )
        guard case .needsUserAction = blockedDelete else {
            return XCTFail("Expected delete approval, got \(blockedDelete)")
        }

        let deleted = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "workspace_artifact_delete",
                operation: #"{"artifact_id":"\#(artifact.id)"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: true
            )
        )
        guard case .workspaceResult(let deleteText) = deleted else {
            return XCTFail("Expected artifact delete, got \(deleted)")
        }
        XCTAssertEqual(try jsonObject(deleteText)["deleted"] as? Bool, true)
        XCTAssertThrowsError(try workspaceStore.artifactContent(id: artifact.id))
    }

    func testIshHandoffRequiresApprovalAndHighRiskAutoApprovePreparesClipboard() async throws {
        let executor = makeExecutor()
        let input = #"{"command":"echo amber-ish","filename":"demo.sh","purpose":"smoke"}"#

        let blocked = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "ish_handoff",
                operation: input,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )
        guard case .needsUserAction(let reason) = blocked else {
            return XCTFail("Expected iSH handoff approval requirement, got \(blocked)")
        }
        XCTAssertTrue(reason.contains("foreground approval"))

        let prepared = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "ish_handoff",
                operation: input,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: IOSExecutionPolicySnapshot(
                    capabilityPolicies: [:],
                    globalAutoApproveEnabled: false,
                    highRiskAutoApproveEnabled: true,
                    execJavaScriptEnabled: false,
                    webSearchEnabled: false
                )
            ),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        guard case .ishHandoffResult(let text) = prepared else {
            return XCTFail("Expected iSH handoff result, got \(prepared)")
        }

        let object = try jsonObject(text)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["status"] as? String, "handoff_prepared")
        XCTAssertEqual(object["mode"] as? String, "clipboard_handoff")
        XCTAssertEqual(object["script_file_name"] as? String, "demo.sh")
        XCTAssertEqual(object["copied_to_clipboard"] as? Bool, true)
        XCTAssertEqual(object["requires_user_paste"] as? Bool, true)
        XCTAssertEqual(object["open_ish_supported"] as? Bool, false)
        XCTAssertEqual(object["stdout_available"] as? Bool, false)
        XCTAssertEqual(object["stderr_available"] as? Bool, false)
        XCTAssertEqual(object["exit_code_available"] as? Bool, false)

        let paste = try XCTUnwrap(UIPasteboard.general.string)
        XCTAssertTrue(paste.contains("demo.sh"))
        XCTAssertTrue(paste.contains("echo amber-ish"))

        let scriptPath = try XCTUnwrap(object["amber_script_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))
        let savedScript = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertTrue(savedScript.contains("#!/bin/sh"))
        XCTAssertTrue(savedScript.contains("echo amber-ish"))
    }

    func testEmbeddedIshExecuteAvailabilityMatchesBuildTarget() async throws {
        let executor = makeExecutor()

        let blocked = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "ios_ish_execute",
                operation: #"{"command":"echo amber-ish","purpose":"smoke"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )

        if IOSEmbeddedIshToolCatalog.supportedToolNames.contains("ios_ish_execute") {
            guard case .needsUserAction(let reason) = blocked else {
                return XCTFail("Expected embedded iSH approval requirement, got \(blocked)")
            }
            XCTAssertTrue(reason.contains("stdout/stderr/exit code"))
        } else {
            guard case .denied(let reason) = blocked else {
                return XCTFail("Expected unavailable embedded iSH denial, got \(blocked)")
            }
            XCTAssertTrue(reason.contains("Unknown iOS tool"))
        }
    }

    func testTerminalJobReadUsesEmbeddedCapabilityForEmbeddedRecord() async throws {
        let defaults = isolatedDefaults()
        let permissionStore = IOSPermissionStore(userDefaults: defaults)
        let remoteCapability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.remote.command" }
        )
        permissionStore.setPolicy(.disabled, for: remoteCapability)
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "terminal-jobs")
        taskStore.startTask(
            id: "embedded-job",
            kind: .embeddedIsh,
            title: "Embedded job",
            objective: "echo amber",
            sourceToolName: "ios_ish_execute",
            metadata: [
                "terminal_job": "true",
                "runtime": IOSTerminalRuntimeKind.ishExperimental.rawValue,
                "stdout_tail": "amber\n",
            ]
        )
        taskStore.updateTask(id: "embedded-job", status: .completed)
        let executor = IOSLocalToolExecutor(
            permissionStore: permissionStore,
            documentStore: DocumentAccessStore(),
            terminalTaskStore: taskStore
        )

        let output = await executor.execute(IOSLocalToolExecutionRequest(
            toolName: IOSRemoteTerminalToolCatalog.jobReadToolName,
            operation: #"{"job_id":"embedded-job"}"#,
            scopeDigest: "",
            payloadDigest: "",
            isUserInitiated: false
        ))

        if IOSEmbeddedIshToolCatalog.supportedToolNames.isEmpty {
            guard case .denied = output else {
                return XCTFail("Stable target must fail closed for an embedded iSH job record")
            }
        } else {
            guard case .terminalResult(let text) = output else {
                return XCTFail("Embedded job read should not inherit the disabled Remote SSH policy: \(output)")
            }
            let object = try jsonObject(text)
            XCTAssertEqual(object["runtime"] as? String, IOSTerminalRuntimeKind.ishExperimental.rawValue)
            XCTAssertEqual(object["stdout"] as? String, "amber\n")
        }
    }

    func testRemoteTerminalApprovalPreviewUsesRemoteModeAndBoundedCommand() throws {
        let profile = IOSSSHProfile(
            id: "profile-1234567890",
            name: "Terminal Test",
            host: "example.com",
            username: "amber"
        )
        let settings = SettingsStore(userDefaults: isolatedDefaults(), storageKey: "terminal-preview")
        try settings.upsertSSHProfile(profile, password: nil)
        settings.sshDefaultProfileId = profile.id
        let preview = try XCTUnwrap(IOSRemoteTerminalExecuteExecutor.approvalPreview(
            input: #"{"command":"uname -a","profile_id":"profile-1234567890","purpose":"inspect host"}"#,
            settingsStore: settings
        ))

        XCTAssertEqual(preview.mode, .remoteSSH)
        XCTAssertEqual(preview.title, "执行 Remote SSH")
        XCTAssertEqual(preview.commandPreview, "uname -a")
        XCTAssertTrue(preview.filename.contains("Terminal Test"))
        XCTAssertTrue(preview.filename.contains("amber@example.com:22"))
        XCTAssertEqual(preview.remoteProfileId, profile.id)
        XCTAssertNotNil(preview.remoteTargetDigest)
        XCTAssertEqual(preview.primaryChip.title, "远程执行")
        XCTAssertEqual(preview.secondaryChip.title, "回传输出")
    }

}
