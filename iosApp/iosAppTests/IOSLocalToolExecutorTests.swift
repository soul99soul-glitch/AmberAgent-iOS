import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
final class IOSLocalToolExecutorTests: IOSWebMountToolTestCase {
    func testPermissionsStatusReturnsIOSSnapshot() async throws {
        let defaults = isolatedDefaults()
        let permissionStore = IOSPermissionStore(userDefaults: defaults)
        let fileCapability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.files.selected_read" }
        )
        permissionStore.setPolicy(.disabled, for: fileCapability)
        let executor = makeExecutor(permissionStore: permissionStore)

        let output = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "permissions_status",
                operation: "status",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )

        guard case .permissionsStatus(let snapshot) = output else {
            return XCTFail("Expected permissions status, got \(output)")
        }
        XCTAssertEqual(snapshot.platform, "iOS")
        XCTAssertFalse(snapshot.capabilities.isEmpty)
        let selectedFile = snapshot.capabilities.first { $0.id == "ios.files.selected_read" }
        XCTAssertEqual(selectedFile?.policy, IOSAgentPermissionPolicy.disabled.title)
    }

    func testPermissionsStatusIncludesAdvancedExecutionApprovals() async throws {
        let permissionStore = IOSPermissionStore(userDefaults: isolatedDefaults(), taskStore: nil)
        permissionStore.recordApproval(
            capabilityId: "ios.agent.subagent_dispatch",
            toolName: "subagent_dispatch",
            action: .allowed,
            reason: "role=explorer token=secret",
            runId: "run-subagent"
        )
        let executor = makeExecutor(permissionStore: permissionStore)

        let output = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "permissions_status",
                operation: "status",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )

        guard case .permissionsStatus(let snapshot) = output else {
            return XCTFail("Expected permissions status, got \(output)")
        }
        let subAgent = try XCTUnwrap(snapshot.capabilities.first { $0.id == "ios.agent.subagent_dispatch" })
        let remote = try XCTUnwrap(snapshot.capabilities.first { $0.id == "ios.remote.command" })

        XCTAssertTrue(subAgent.modelToolNames.contains("subagent_dispatch"))
        XCTAssertEqual(subAgent.lastApprovalAction, IOSToolApprovalAction.allowed.title)
        XCTAssertFalse(subAgent.lastApprovalReason?.contains("secret") == true)
        XCTAssertTrue(remote.uiActionNames.contains("remote_command_cancel"))
        XCTAssertTrue(remote.modelToolNames.contains("terminal_execute"))
    }

    func testFilePickIsDeniedBecauseItIsUIOnly() async {
        let output = await makeExecutor().execute(
            IOSLocalToolExecutionRequest(
                toolName: "file_pick",
                operation: "pick",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: true
            )
        )

        guard case .denied(let reason) = output else {
            return XCTFail("Expected denied, got \(output)")
        }
        XCTAssertTrue(reason.contains("foreground UI action"))
    }

    func testUnknownPlannedAndBlockedToolsAreDenied() async {
        let executor = makeExecutor()
        let toolNames = [
            "unknown_tool",
            "location_current",
            "sms_read",
            "notification_list",
            "terminal_session_exec"
        ]

        for toolName in toolNames {
            let output = await executor.execute(
                IOSLocalToolExecutionRequest(
                    toolName: toolName,
                    operation: "test",
                    scopeDigest: "",
                    payloadDigest: "",
                    isUserInitiated: true
                )
            )
            guard case .denied = output else {
                return XCTFail("Expected denied for \(toolName), got \(output)")
            }
        }
    }

    func testFileReadWithoutGrantNeedsUserAction() async {
        let output = await makeExecutor().execute(
            IOSLocalToolExecutionRequest(
                toolName: "file_read_selected",
                operation: "read_preview",
                scopeDigest: "missing",
                payloadDigest: "missing",
                isUserInitiated: true
            )
        )

        guard case .needsUserAction = output else {
            return XCTFail("Expected needsUserAction, got \(output)")
        }
    }

    func testValidGrantReturnsPreviewOnlyOnce() async throws {
        let documentStore = DocumentAccessStore()
        let grant = documentStore.registerPickedFile(try makeTempFile(size: 16))
        let permissionStore = IOSPermissionStore(userDefaults: isolatedDefaults())
        let fileCapability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.files.selected_read" }
        )
        permissionStore.setPolicy(.askEveryTime, for: fileCapability)
        let executor = makeExecutor(permissionStore: permissionStore, documentStore: documentStore)
        let request = IOSLocalToolExecutionRequest(
            toolName: grant.toolName,
            operation: grant.operation,
            scopeDigest: grant.scopeDigest,
            payloadDigest: grant.payloadDigest,
            isUserInitiated: true
        )

        let first = await executor.execute(request)
        guard case .selectedFilePreview(let result) = first else {
            return XCTFail("Expected selectedFilePreview, got \(first)")
        }
        XCTAssertEqual(result.bytesRead, 16)

        let second = await executor.execute(request)
        guard case .denied = second else {
            return XCTFail("Expected second execution to deny, got \(second)")
        }
    }

    func testSelectedFileReadUsesFrozenExecutionPolicy() async throws {
        let documentStore = DocumentAccessStore()
        _ = documentStore.registerPickedFile(try makeTempFile(size: 16))
        let permissionStore = IOSPermissionStore(userDefaults: isolatedDefaults())
        let capability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.files.selected_read" }
        )
        permissionStore.setPolicy(.disabled, for: capability)
        let executor = makeExecutor(permissionStore: permissionStore, documentStore: documentStore)
        let snapshot = executor.executionPolicySnapshot(
            execJavaScriptEnabled: false,
            webSearchEnabled: false
        )
        permissionStore.setPolicy(.autoApprove, for: capability)

        let output = await executor.execute(
            executor.executionRequest(
                toolName: "file_read_selected",
                operation: "read_preview",
                isUserInitiated: true,
                runId: "run-frozen-file-policy",
                executionPolicy: snapshot
            )
        )

        guard case .denied(let reason) = output else {
            return XCTFail("Expected frozen disabled policy to deny, got \(output)")
        }
        XCTAssertTrue(reason.contains("Disabled"))
    }

    func testScopeToolOrPayloadMismatchCannotSucceed() async throws {
        let documentStore = DocumentAccessStore()
        let grant = documentStore.registerPickedFile(try makeTempFile(size: 16))
        let executor = makeExecutor(documentStore: documentStore)
        let requests = [
            IOSLocalToolExecutionRequest(
                toolName: "unknown_tool",
                operation: grant.operation,
                scopeDigest: grant.scopeDigest,
                payloadDigest: grant.payloadDigest,
                isUserInitiated: true
            ),
            IOSLocalToolExecutionRequest(
                toolName: grant.toolName,
                operation: grant.operation,
                scopeDigest: "wrong-scope",
                payloadDigest: grant.payloadDigest,
                isUserInitiated: true
            ),
            IOSLocalToolExecutionRequest(
                toolName: grant.toolName,
                operation: grant.operation,
                scopeDigest: grant.scopeDigest,
                payloadDigest: "wrong-payload",
                isUserInitiated: true
            )
        ]

        for request in requests {
            let output = await executor.execute(request)
            guard case .denied = output else {
                XCTFail("Expected denied for mismatched request \(request), got \(output)")
                continue
            }
        }
    }

    func testAskEveryTimeRequiresForegroundUserAction() async throws {
        let documentStore = DocumentAccessStore()
        let grant = documentStore.registerPickedFile(try makeTempFile(size: 16))
        let executor = makeExecutor(documentStore: documentStore)

        let output = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: grant.toolName,
                operation: grant.operation,
                scopeDigest: grant.scopeDigest,
                payloadDigest: grant.payloadDigest,
                isUserInitiated: false
            )
        )

        guard case .needsUserAction(let reason) = output else {
            return XCTFail("Expected needsUserAction, got \(output)")
        }
        XCTAssertTrue(reason.contains("Ask every time"))
    }

    func testMemoryToolWritePolicyRequiresForegroundAndRespectsDisabled() throws {
        let defaults = isolatedDefaults()
        let permissionStore = IOSPermissionStore(userDefaults: defaults)
        let executor = makeExecutor(permissionStore: permissionStore)
        let input = #"{"action":"create","content":"remember this"}"#

        XCTAssertEqual(
            executor.memoryToolWritePolicy(input: #"{"action":"list"}"#, isUserInitiated: false),
            .allow
        )
        guard case .needsUserAction(let reason) = executor.memoryToolWritePolicy(
            input: input,
            isUserInitiated: false
        ) else {
            return XCTFail("Expected foreground approval requirement")
        }
        XCTAssertTrue(reason.contains("foreground approval"))
        XCTAssertEqual(executor.memoryToolWritePolicy(input: input, isUserInitiated: true), .allow)

        let capability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.agent.memory_write" }
        )
        permissionStore.setPolicy(.disabled, for: capability)
        guard case .denied(let disabledReason) = executor.memoryToolWritePolicy(
            input: input,
            isUserInitiated: true
        ) else {
            return XCTFail("Expected disabled policy to deny")
        }
        XCTAssertTrue(disabledReason.contains("disabled"))
    }

    func testExecutionPolicySnapshotFreezesMemoryDecisionAndHasStableDigest() throws {
        let permissionStore = IOSPermissionStore(userDefaults: isolatedDefaults())
        let executor = makeExecutor(permissionStore: permissionStore)
        let input = #"{"action":"create","content":"remember this"}"#
        let snapshot = executor.executionPolicySnapshot(
            execJavaScriptEnabled: false,
            webSearchEnabled: true,
            mcpEnabled: false
        )
        let decoded = try XCTUnwrap(snapshot.encodedJSON.flatMap(IOSExecutionPolicySnapshot.decode(json:)))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.digest, snapshot.digest)
        XCTAssertEqual(decoded.mcpEnabled, false)

        let capability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.agent.memory_write" }
        )
        permissionStore.setPolicy(.disabled, for: capability)

        guard case .denied = executor.memoryToolWritePolicy(
            input: input,
            isUserInitiated: true
        ) else {
            return XCTFail("Live disabled policy should deny")
        }
        XCTAssertEqual(
            executor.memoryToolWritePolicy(
                input: input,
                isUserInitiated: true,
                executionPolicy: snapshot
            ),
            .allow,
            "An in-flight run must keep the policy captured at its start"
        )
        XCTAssertNotEqual(
            snapshot.digest,
            executor.executionPolicySnapshot(
                execJavaScriptEnabled: false,
                webSearchEnabled: true
            ).digest
        )
    }

    func testExecutionRequestDigestsSeparateScopeFromPayload() {
        let executor = makeExecutor()
        let first = executor.executionRequest(
            toolName: "workspace_file_write",
            operation: #"{"path":"/workspace/a.md","content":"one"}"#,
            isUserInitiated: false,
            runId: "run-policy"
        )
        let sameScope = executor.executionRequest(
            toolName: "workspace_file_write",
            operation: #"{"path":"/workspace/a.md","content":"two"}"#,
            isUserInitiated: false,
            runId: "run-policy"
        )
        let otherScope = executor.executionRequest(
            toolName: "workspace_file_write",
            operation: #"{"path":"/workspace/b.md","content":"one"}"#,
            isUserInitiated: false,
            runId: "run-policy"
        )

        XCTAssertEqual(first.scopeDigest, sameScope.scopeDigest)
        XCTAssertNotEqual(first.payloadDigest, sameScope.payloadDigest)
        XCTAssertNotEqual(first.scopeDigest, otherScope.scopeDigest)
        XCTAssertEqual(first.runId, "run-policy")
    }

}
