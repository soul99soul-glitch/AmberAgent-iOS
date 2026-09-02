import XCTest
import UIKit
import WebKit
@testable import iosApp

@MainActor
final class IOSLocalToolExecutorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Reset the shared mock session-id counter so each test starts from a
        // deterministic base (prevents the cross-test pollution that made
        // testWebMountTabLifecycleAndClosedSessionFailure order-dependent).
        MockWebMountRuntime.resetSessionCounter()
    }

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

    func testWebMountRegistrySeedsAndPersists() throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)

        XCTAssertEqual(Set(registry.sites.map(\.id)), [
            "hackernews",
            "reddit",
            "github",
            "bilibili",
            "x_com",
            "weibo",
            "juejin",
            "zhihu",
            "feishu_docs"
        ])

        registry.setEnabled(id: "github", enabled: true)
        let reloaded = IOSWebMountRegistry(userDefaults: defaults)
        XCTAssertEqual(reloaded.site(id: "github")?.enabled, true)
    }

    func testWebMountDisabledStationStillAllowsExplicitForegroundUserOpen() async throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let site = try XCTUnwrap(registry.site(id: "hackernews"))
        XCTAssertFalse(site.enabled)
        let runtime = MockWebMountRuntime(sessionId: "foreground-disabled-station")
        let controller = IOSWebMountController(
            registry: registry,
            settings: IOSWebMountSettings(userDefaults: defaults),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )

        let snapshot = await controller.openForUser(site: site, sessionId: runtime.snapshot.sessionId)

        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(runtime.openedURLs, [URL(string: "https://news.ycombinator.com")!])
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: runtime.snapshot.sessionId)?.controlOwner,
            .user
        )
    }

    func testWebMountRegistryRestoresSeedsWhenPersistedPayloadIsUnreadable() throws {
        let defaults = isolatedDefaults()
        defaults.set(Data([0x7b]), forKey: "app.amber.ios.webmount.sites.v1")
        defaults.set(true, forKey: "app.amber.ios.webmount.seeded.v1")

        let registry = IOSWebMountRegistry(userDefaults: defaults)

        XCTAssertEqual(registry.sites.count, 9)
        XCTAssertNotNil(registry.site(id: "github"))
    }

    func testWebMountRegistryAddRemoveRestore() throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)

        let custom = try registry.addCustomSite(
            displayName: "Example Docs",
            homepageURL: "https://docs.example.com/start?token=secret",
            needsLogin: true,
            loginCookieName: "sid"
        )
        XCTAssertTrue(custom.id.hasPrefix("user_"))
        XCTAssertEqual(custom.allowedHosts, ["docs.example.com"])
        XCTAssertTrue(registry.remove(id: "github"))
        XCTAssertNil(registry.site(id: "github"))
        XCTAssertEqual(registry.restoreMissingSeeds(), 1)
        XCTAssertNotNil(registry.site(id: "github"))
    }

    func testWebMountSettingsDefaults() {
        let settings = IOSWebMountSettings(userDefaults: isolatedDefaults())

        XCTAssertTrue(settings.globalEnabled)
        XCTAssertTrue(settings.allowedHosts.contains("github.com"))
        XCTAssertTrue(settings.allowedSchemes.contains("http"))
        XCTAssertTrue(settings.allowedSchemes.contains("https"))
    }

    func testWebMountURLPolicyRejectsSchemeAndHostOutsideAllowlist() async throws {
        let settings = IOSWebMountSettings(userDefaults: isolatedDefaults())
        let policy = IOSWebMountURLPolicy(settings: settings)
        let highRiskPolicy = IOSWebMountURLPolicy(settings: settings, allowUnlistedHosts: true)

        XCTAssertNotNil(try? policy.validate("https://github.com/login").get())
        XCTAssertEqual(
            policy.validate("javascript:alert(1)").failure,
            .unsupportedScheme("javascript")
        )
        XCTAssertEqual(
            policy.validate("data:text/html,hi").failure,
            .unsupportedScheme("data")
        )
        XCTAssertEqual(
            policy.validate("https://evil.example.com/").failure,
            .hostNotAllowed("evil.example.com")
        )
        XCTAssertNotNil(try? highRiskPolicy.validate("https://evil.example.com/").get())
        XCTAssertEqual(
            highRiskPolicy.validate("https://127.0.0.1/admin").failure,
            .privateHostNotAllowed("127.0.0.1")
        )
        XCTAssertEqual(
            highRiskPolicy.validate("https://user:secret@evil.example.com/").failure,
            .embeddedCredentialsNotAllowed
        )
        XCTAssertEqual(
            policy.validate("https://user:secret@github.com/").failure,
            .embeddedCredentialsNotAllowed
        )
        let privateResolution = await highRiskPolicy.validateResolvedPublicHost(
            "https://internal.example/",
            resolveHost: { _ in ["10.0.0.8"] }
        )
        XCTAssertEqual(privateResolution.failure, .privateHostNotAllowed("internal.example"))
    }

    func testWebMountRedactionRemovesSensitiveValuesAndURLQuery() throws {
        let redacted = IOSWebMountRedactor.redactedJSONObject([
            "url": "https://example.com/path?token=secret#frag",
            "href": "https://example.com/next?auth=secret",
            "cookie": "sid=secret",
            "nested": [
                "Authorization": "Bearer secret",
                "verificationCode": "654321",
                "otpCode": "123456",
                "cardNumber": "4111111111111111",
                "cvv2": "123",
                "billingAddress": "private address",
                "验证码": "999999",
                "卡号": "5555555555554444"
            ]
        ])
        let json = IOSWebMountController.json(redacted)
        let object = try jsonObject(json)

        XCTAssertEqual(object["url"] as? String, "https://example.com/path")
        XCTAssertEqual(object["href"] as? String, "https://example.com/next")
        XCTAssertEqual(IOSWebMountRedactor.redactedURL("not a URL with token=secret"), "[redacted-url]")
        XCTAssertFalse(json.contains("token=secret"))
        XCTAssertFalse(json.contains("auth=secret"))
        XCTAssertFalse(json.contains("sid=secret"))
        XCTAssertFalse(json.contains("Bearer secret"))
        XCTAssertFalse(json.contains("654321"))
        XCTAssertFalse(json.contains("123456"))
        XCTAssertFalse(json.contains("4111111111111111"))
        XCTAssertFalse(json.contains("private address"))
        XCTAssertFalse(json.contains("999999"))
        XCTAssertFalse(json.contains("5555555555554444"))
    }

    func testWebMountRedactionScrubsSensitivePlainStrings() {
        let text = IOSWebMountRedactor.redactedText(
            #"Visit https://example.com/reset/token-opaque?token=secret, use Authorization: Bearer abcdef123456, Password: hunter2, OTP: 123456, 验证码 654321, Card Number: 4111 1111 1111 1111, CVV: 123, and {"password":"json-secret"}"#
        )

        XCTAssertFalse(text.contains("token=secret"))
        XCTAssertFalse(text.contains("token-opaque"))
        XCTAssertFalse(text.contains("abcdef123456"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("123456"))
        XCTAssertFalse(text.contains("654321"))
        XCTAssertFalse(text.contains("4111 1111 1111 1111"))
        XCTAssertFalse(text.contains("CVV: 123"))
        XCTAssertFalse(text.contains("json-secret"))
        XCTAssertTrue(text.contains("https://example.com/redacted"))
    }

    func testWebMountScreenshotArtifactsExpireAndDeleteWithSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webmount-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = IOSWebMountScreenshotCapture(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            width: 20,
            height: 10,
            format: "png"
        )
        let now: Int64 = 1_000
        let first = try IOSWebMountScreenshotArtifactStore.save(
            capture,
            sessionId: "session-a",
            rootDirectory: root,
            nowMillis: now
        )
        _ = try IOSWebMountScreenshotArtifactStore.save(
            capture,
            sessionId: "session-b",
            rootDirectory: root,
            nowMillis: now
        )
        let directory = root
            .appendingPathComponent("AmberWorkspace/WebMount/screenshots", isDirectory: true)
        XCTAssertEqual(first["expires_at_ms"] as? Int64, now + IOSWebMountScreenshotArtifactStore.retentionMillis)
        XCTAssertEqual(first["contains_unredacted_viewport"] as? Bool, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)

        IOSWebMountScreenshotArtifactStore.deleteArtifacts(sessionId: "session-a", rootDirectory: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        IOSWebMountScreenshotArtifactStore.cleanupExpired(
            rootDirectory: root,
            nowMillis: now + IOSWebMountScreenshotArtifactStore.retentionMillis
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testWebMountToolCatalogAndUnsupportedResult() {
        XCTAssertEqual(IOSWebMountToolCatalog.supportedToolNames.count, 24)
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_open"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_tab_list"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_tab_new"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_tab_close"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_observe"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_visual_snapshot"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_screenshot"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_site_add"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_site_remove"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_click"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_tap"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_type"))
        XCTAssertTrue(IOSWebMountToolCatalog.supportedToolNames.contains("wm_keys"))
        XCTAssertTrue(IOSWebMountToolCatalog.unsupportedToolNames.contains("wm_eval"))
        XCTAssertTrue(IOSWebMountToolCatalog.unsupportedToolNames.contains("wm_visual_read"))
        XCTAssertTrue(IOSWebMountToolCatalog.unsupportedToolNames.contains("wm_signed_fetch"))
        XCTAssertTrue(IOSWebMountController.unsupportedToolResult(toolName: "wm_eval").contains("unsupported"))
    }

    func testWebMountInteractionAcceptsDeclaredArgumentAliases() async throws {
        let runtime = MockWebMountRuntime()
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )

        _ = await controller.execute(
            toolName: "wm_scroll",
            input: ##"{"target":"#main","by_y":240}"##,
            isUserInitiated: true
        )
        XCTAssertEqual(runtime.lastInteraction?.method, "scroll")
        XCTAssertEqual(runtime.lastInteraction?.selector, "#main")
        XCTAssertEqual(runtime.lastInteraction?.options["dy"] as? Int, 240)

        let tapOutput = await controller.execute(
            toolName: "wm_tap",
            input: #"{"x":48,"y":96,"snapshot_id":"mock-document:0"}"#,
            isUserInitiated: true
        )
        let tap = try jsonObject(tapOutput)
        XCTAssertEqual(runtime.lastInteraction?.method, "tap")
        XCTAssertEqual(runtime.lastInteraction?.options["x"] as? Int, 48)
        XCTAssertEqual(runtime.lastInteraction?.options["y"] as? Int, 96)
        XCTAssertEqual(tap["status"] as? String, "dispatched_unverified")
        XCTAssertEqual(tap["verified"] as? Bool, false)
        XCTAssertEqual(tap["may_have_applied"] as? Bool, true)
        let tapReceipt = try XCTUnwrap(tap["action_receipt"] as? [String: Any])
        XCTAssertEqual(tapReceipt["outcome"] as? String, "ambiguous")
        XCTAssertEqual(tapReceipt["dispatched"] as? Bool, true)
        let tapDiff = try XCTUnwrap(tap["diff"] as? [String: Any])
        XCTAssertEqual(tapDiff["changed"] as? Bool, false)
        XCTAssertEqual(tapDiff["revision_changed"] as? Bool, true)

        _ = await controller.execute(
            toolName: "wm_keys",
            input: #"{"text":"Enter"}"#,
            isUserInitiated: true
        )
        XCTAssertEqual(runtime.lastInteraction?.method, "keys")
        XCTAssertEqual(runtime.lastInteraction?.text, "Enter")

        _ = await controller.execute(
            toolName: "wm_find",
            input: #"{"text":"sign in","max_results":3}"#,
            isUserInitiated: true
        )
        XCTAssertEqual(runtime.lastInteraction?.method, "find")
        XCTAssertEqual(runtime.lastInteraction?.text, "sign in")
        XCTAssertEqual(runtime.lastInteraction?.options["max_results"] as? Int, 3)

        _ = await controller.execute(
            toolName: "wm_wait",
            input: ##"{"condition":"selector","selector":"#ready","timeout_ms":1200}"##,
            isUserInitiated: true
        )
        XCTAssertEqual(runtime.lastInteraction?.method, "wait")
        XCTAssertEqual(runtime.lastInteraction?.options["condition"] as? String, "selector")
        XCTAssertEqual(runtime.lastInteraction?.options["wait_ms"] as? Int, 1200)

        let interactionsBeforeInvalidPostcondition = runtime.interactionCallCount
        let invalidPostcondition = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "target": "css:button",
                "snapshot_id": "mock-document:\(runtime.pageRevision)",
                "postcondition": [
                    "condition": "ready_state",
                    "value": "loading"
                ]
            ]),
            isUserInitiated: true
        ))
        XCTAssertEqual(invalidPostcondition["error_code"] as? String, "invalid_postcondition")
        XCTAssertEqual(runtime.interactionCallCount, interactionsBeforeInvalidPostcondition)
    }

    func testWebMountPreexistingPostconditionCannotVerifyMutation() async throws {
        let runtime = MockWebMountRuntime(sessionId: "preexisting-postcondition")
        runtime.waitMatched = true
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )

        let output = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "target": "css:button",
                "snapshot_id": "mock-document:0",
                "postcondition": [
                    "condition": "text",
                    "value": "already present",
                    "timeout_ms": 500
                ]
            ]),
            isUserInitiated: true
        ))

        XCTAssertEqual(output["ok"] as? Bool, false)
        XCTAssertEqual(output["status"] as? String, "ambiguous")
        XCTAssertEqual(output["error_code"] as? String, "postcondition_preexisting")
        XCTAssertEqual(output["may_have_applied"] as? Bool, true)
        XCTAssertEqual(output["verified"] as? Bool, false)
        let receipt = try XCTUnwrap(output["action_receipt"] as? [String: Any])
        XCTAssertEqual((receipt["precondition"] as? [String: Any])?["matched"] as? Bool, true)
    }

    func testWebMountWKRuntimeStableRefsKeysFindWaitAndStaleSnapshot() async throws {
        let runtime = IOSWebMountWKRuntime()
        let webView = try XCTUnwrap(runtime.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        webView.loadHTMLString(
            """
            <!doctype html><html><body>
              <script>window.__amberWebMountBridgeV1={document:document,documentId:"forged-page-world",revision:999};</script>
              <label for="field">Name</label><input id="field" value="A">
              <span id="editor-label">Notes</span><div id="editor" contenteditable="true" aria-labelledby="editor-label"></div>
              <span id="choice-label">Accept terms</span><input id="choice" type="checkbox" aria-labelledby="choice-label">
              <button id="inert-action" inert>Ignored action</button>
              <input id="hidden" type="hidden" value="opaque-token">
              <input id="password" type="password" value="">
              <input id="otp" name="otp" autocomplete="one-time-code" value="">
              <input id="card-number" autocomplete="cc-number" value="">
              <div id="hidden-secret" style="display:none">opaque-hidden-text</div>
              <div id="visible-shell" style="width:10px;height:10px"><span style="display:none">nested-hidden-text</span></div>
              <div style="opacity:0"><button id="transparent-secret">transparent-hidden-text</button></div>
              <a id="hidden-link" style="display:none" href="https://example.com/private">private-link</a>
              <button id="go" onclick="document.getElementById('status').textContent='clicked'">Go</button>
              <button id="pay" onclick="document.getElementById('status').textContent='paid'">Pay now</button>
              <form onsubmit="event.preventDefault();document.getElementById('status').textContent='submitted'">
                <button id="default-submit">Continue</button>
              </form>
              <form onsubmit="event.preventDefault();document.getElementById('status').textContent='otp-submitted'">
                <button id="verify-otp">Verify OTP</button>
              </form>
              <div id="status">idle</div>
            </body></html>
            """,
            baseURL: URL(string: "https://github.com/")
        )

        var ready = false
        for _ in 0..<60 {
            if let state = try? await runtime.state(),
               state["ready_state"] as? String == "complete",
               (state["text_length"] as? Int ?? 0) > 0 {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready)

        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )
        let observation = try jsonObject(await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: false))
        XCTAssertEqual(observation["ok"] as? Bool, true, "Unexpected observation payload: \(observation)")
        XCTAssertEqual(observation["observation_consistency"] as? String, "atomic")
        XCTAssertEqual(observation["untrusted_page_content"] as? Bool, true)
        let snapshotId = try XCTUnwrap(observation["snapshot_id"] as? String)
        let observedPage = try XCTUnwrap(observation["page"] as? [String: Any])
        XCTAssertEqual(observedPage["snapshot_id"] as? String, snapshotId)
        XCTAssertEqual(observedPage["page_revision"] as? Int, observation["page_revision"] as? Int)
        XCTAssertFalse(snapshotId.hasPrefix("forged-page-world:"))
        let pageWorldDocumentId = try await webView.evaluateJavaScript(
            "window.__amberWebMountBridgeV1.documentId"
        ) as? String
        XCTAssertEqual(pageWorldDocumentId, "forged-page-world")
        let elements = try XCTUnwrap(observation["interactive_elements"] as? [[String: Any]])
        let fieldRef = try XCTUnwrap(elements.first { ($0["tag"] as? String) == "input" }?["ref"] as? String)
        let checkboxRef = try XCTUnwrap(
            elements.first { ($0["selector"] as? String)?.contains("#choice") == true }?["ref"] as? String
        )
        XCTAssertEqual(elements.first { ($0["selector"] as? String)?.contains("#editor") == true }?["role"] as? String, "textbox")
        XCTAssertEqual(elements.first { ($0["selector"] as? String)?.contains("#editor") == true }?["name"] as? String, "Notes")
        XCTAssertEqual(elements.first { ($0["selector"] as? String)?.contains("#choice") == true }?["role"] as? String, "checkbox")
        XCTAssertEqual(elements.first { ($0["selector"] as? String)?.contains("#inert-action") == true }?["actionable"] as? Bool, false)
        XCTAssertFalse(elements.contains { ($0["selector"] as? String)?.contains("#hidden") == true })

        let hidden = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: ##"{"selector":"#hidden","kind":"value"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(hidden["ok"] as? Bool, false)
        XCTAssertFalse(IOSWebMountController.json(hidden).contains("opaque-token"))
        XCTAssertFalse(IOSWebMountController.json(observation).contains("private-link"))

        let hiddenFind = try jsonObject(await controller.execute(
            toolName: "wm_find",
            input: ##"{"selector":"#hidden-secret"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(hiddenFind["status"] as? String, "not_found")
        XCTAssertEqual(hiddenFind["verified"] as? Bool, false)
        XCTAssertFalse(IOSWebMountController.json(hiddenFind).contains("opaque-hidden-text"))

        let nestedHiddenText = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: ##"{"selector":"#visible-shell","kind":"text"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(nestedHiddenText["ok"] as? Bool, true)
        let nestedResult = try XCTUnwrap(nestedHiddenText["result"] as? [String: Any])
        XCTAssertEqual(nestedResult["value"] as? String, "")

        let transparentFind = try jsonObject(await controller.execute(
            toolName: "wm_find",
            input: ##"{"selector":"#transparent-secret"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(transparentFind["status"] as? String, "not_found")
        XCTAssertFalse(IOSWebMountController.json(transparentFind).contains("transparent-hidden-text"))

        let passwordWrite = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: ##"{"selector":"#password","text":"do-not-write"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(passwordWrite["ok"] as? Bool, false)
        XCTAssertEqual(passwordWrite["error_code"] as? String, "sensitive_field_requires_human")
        XCTAssertFalse(IOSWebMountController.json(passwordWrite).contains("do-not-write"))

        let otpWrite = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: ##"{"selector":"#otp","text":"123456"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(otpWrite["error_code"] as? String, "sensitive_field_requires_human")

        let otpRead = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: ##"{"selector":"#otp","kind":"value"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(otpRead["ok"] as? Bool, false)

        let checkboxType = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: IOSWebMountController.json([
                "target": checkboxRef,
                "snapshot_id": snapshotId,
                "text": "not-applicable"
            ]),
            isUserInitiated: false
        ))
        XCTAssertEqual(checkboxType["ok"] as? Bool, false)
        XCTAssertEqual(checkboxType["error_code"] as? String, "target_not_typeable")

        let keysInput = IOSWebMountController.json([
            "target": fieldRef,
            "snapshot_id": snapshotId,
            "text": "Z"
        ])
        let keys = try jsonObject(await controller.execute(toolName: "wm_keys", input: keysInput, isUserInitiated: false))
        XCTAssertEqual(keys["ok"] as? Bool, true)
        XCTAssertEqual(keys["verified"] as? Bool, true)
        XCTAssertFalse(keysInput.contains("css:"))

        let value = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: IOSWebMountController.json(["target": fieldRef, "kind": "value"]),
            isUserInitiated: false
        ))
        let valueResult = try XCTUnwrap(value["result"] as? [String: Any])
        XCTAssertEqual(valueResult["value"] as? String, "AZ")

        let stale = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json(["target": fieldRef, "snapshot_id": snapshotId]),
            isUserInitiated: false
        ))
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error_code"] as? String, "stale_snapshot")

        let editorObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: false)
        )
        let editorSnapshot = try XCTUnwrap(editorObservation["snapshot_id"] as? String)
        let editorElements = try XCTUnwrap(editorObservation["interactive_elements"] as? [[String: Any]])
        let editorRef = try XCTUnwrap(
            editorElements.first { ($0["selector"] as? String)?.contains("#editor") == true }?["ref"] as? String
        )
        let editorType = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: IOSWebMountController.json([
                "target": editorRef,
                "snapshot_id": editorSnapshot,
                "text": "Hello editor",
                "postcondition": [
                    "condition": "text",
                    "value": "Hello editor",
                    "timeout_ms": 500
                ]
            ]),
            isUserInitiated: false
        ))
        XCTAssertEqual(editorType["status"] as? String, "verified")
        let editorValue = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: IOSWebMountController.json(["target": editorRef, "kind": "text"]),
            isUserInitiated: false
        ))
        XCTAssertEqual((editorValue["result"] as? [String: Any])?["value"] as? String, "Hello editor")

        let inertObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: false)
        )
        let inertSnapshot = try XCTUnwrap(inertObservation["snapshot_id"] as? String)
        let inertElements = try XCTUnwrap(inertObservation["interactive_elements"] as? [[String: Any]])
        let inertRef = try XCTUnwrap(
            inertElements.first { ($0["selector"] as? String)?.contains("#inert-action") == true }?["ref"] as? String
        )
        let inertClick = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json(["target": inertRef, "snapshot_id": inertSnapshot]),
            isUserInitiated: false
        ))
        XCTAssertEqual(inertClick["error_code"] as? String, "target_not_actionable")

        let found = try jsonObject(await controller.execute(
            toolName: "wm_find",
            input: #"{"text":"idle","max_results":2}"#,
            isUserInitiated: false
        ))
        XCTAssertEqual(found["ok"] as? Bool, true)
        let foundAction = try XCTUnwrap(found["action"] as? [String: Any])
        XCTAssertEqual(foundAction["found"] as? Bool, true)

        _ = try await webView.evaluateJavaScript(
            "setTimeout(function(){document.getElementById('status').textContent='ready';},80)"
        )
        let waited = try jsonObject(await controller.execute(
            toolName: "wm_wait",
            input: #"{"condition":"text","text":"ready","timeout_ms":1500}"#,
            isUserInitiated: false
        ))
        XCTAssertEqual(waited["ok"] as? Bool, true)
        let waitedAction = try XCTUnwrap(waited["action"] as? [String: Any])
        XCTAssertEqual(waitedAction["matched"] as? Bool, true)

        let timedOut = try jsonObject(await controller.execute(
            toolName: "wm_wait",
            input: #"{"condition":"text","text":"never-present","timeout_ms":100}"#,
            isUserInitiated: false
        ))
        XCTAssertEqual(timedOut["status"] as? String, "timed_out")
        let timeoutReceipt = try XCTUnwrap(timedOut["action_receipt"] as? [String: Any])
        XCTAssertEqual(timeoutReceipt["outcome"] as? String, "timed_out")

        let clickObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: false)
        )
        let clickSnapshot = try XCTUnwrap(clickObservation["snapshot_id"] as? String)
        let clickElements = try XCTUnwrap(clickObservation["interactive_elements"] as? [[String: Any]])
        let goRef = try XCTUnwrap(clickElements.first { ($0["name"] as? String) == "Go" }?["ref"] as? String)
        let verifiedClick = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "target": goRef,
                "snapshot_id": clickSnapshot,
                "postcondition": [
                    "condition": "text",
                    "value": "clicked",
                    "timeout_ms": 1_000
                ]
            ]),
            isUserInitiated: false
        ))
        XCTAssertEqual(verifiedClick["ok"] as? Bool, true)
        XCTAssertEqual(verifiedClick["status"] as? String, "verified")
        let clickReceipt = try XCTUnwrap(verifiedClick["action_receipt"] as? [String: Any])
        XCTAssertEqual(clickReceipt["outcome"] as? String, "verified")
        XCTAssertEqual(clickReceipt["verification_source"] as? String, "postcondition")
        let clickPostcondition = try XCTUnwrap(clickReceipt["postcondition"] as? [String: Any])
        XCTAssertEqual(clickPostcondition["matched"] as? Bool, true)

        let executor = makeExecutor(webMountController: controller)
        let submitObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        )
        let submitSnapshot = try XCTUnwrap(submitObservation["snapshot_id"] as? String)
        let submitElements = try XCTUnwrap(submitObservation["interactive_elements"] as? [[String: Any]])
        let submitRef = try XCTUnwrap(submitElements.first { ($0["name"] as? String) == "Continue" }?["ref"] as? String)
        let submitInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "target": submitRef,
            "snapshot_id": submitSnapshot
        ])
        guard case .needsUserAction = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: submitInput,
            isUserInitiated: false,
            runId: "submit-run",
            conversationId: "submit-conversation"
        )) else {
            return XCTFail("Expected default form button to require fresh approval")
        }
        let statusBeforeSubmit = try await webView.evaluateJavaScript(
            "document.getElementById('status').textContent"
        ) as? String
        XCTAssertNotEqual(statusBeforeSubmit, "submitted")
        guard case .webMountResult = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: submitInput,
            isUserInitiated: true,
            runId: "submit-run",
            conversationId: "submit-conversation"
        )) else {
            return XCTFail("Expected approved default form submit")
        }
        let statusAfterSubmit = try await webView.evaluateJavaScript(
            "document.getElementById('status').textContent"
        ) as? String
        XCTAssertEqual(statusAfterSubmit, "submitted")

        let otpButtonObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        )
        let otpButtonSnapshot = try XCTUnwrap(otpButtonObservation["snapshot_id"] as? String)
        let otpButtonElements = try XCTUnwrap(otpButtonObservation["interactive_elements"] as? [[String: Any]])
        let otpButtonRef = try XCTUnwrap(otpButtonElements.first { ($0["name"] as? String) == "Verify OTP" }?["ref"] as? String)
        let otpButtonInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "target": otpButtonRef,
            "snapshot_id": otpButtonSnapshot
        ])
        let otpButtonOutput = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: otpButtonInput,
            isUserInitiated: false,
            runId: "submit-run",
            conversationId: "submit-conversation"
        ))
        guard case .needsUserAction(let otpButtonReason) = otpButtonOutput else {
            return XCTFail("Expected Verify OTP to require human handoff")
        }
        XCTAssertTrue(otpButtonReason.hasPrefix("human_handoff:"))
        let statusBeforeOTP = try await webView.evaluateJavaScript(
            "document.getElementById('status').textContent"
        ) as? String
        XCTAssertNotEqual(statusBeforeOTP, "otp-submitted")
        XCTAssertTrue(executor.completeWebMountHumanHandoff(
            toolName: "wm_click",
            input: otpButtonInput,
            runId: "submit-run"
        ))

        let payObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        )
        let paySnapshot = try XCTUnwrap(payObservation["snapshot_id"] as? String)
        let payElements = try XCTUnwrap(payObservation["interactive_elements"] as? [[String: Any]])
        let payRef = try XCTUnwrap(payElements.first { ($0["name"] as? String) == "Pay now" }?["ref"] as? String)
        let payInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "target": payRef,
            "snapshot_id": paySnapshot
        ])
        let blockedPayOutput = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: payInput,
            isUserInitiated: false,
            runId: "submit-run",
            conversationId: "submit-conversation"
        ))
        guard case .needsUserAction(let payReason) = blockedPayOutput else {
            return XCTFail("Expected snapshot-bound high-consequence approval")
        }
        XCTAssertTrue(payReason.contains("remote state"))
        let statusBeforeApproval = try await webView.evaluateJavaScript("document.getElementById('status').textContent") as? String
        XCTAssertNotEqual(statusBeforeApproval, "paid")

        let approvedPayOutput = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: payInput,
            isUserInitiated: true,
            runId: "submit-run",
            conversationId: "submit-conversation"
        ))
        guard case .webMountResult(let approvedPayText) = approvedPayOutput else {
            return XCTFail("Expected approved WebMount result")
        }
        XCTAssertEqual(try jsonObject(approvedPayText)["ok"] as? Bool, true)
        let statusAfterApproval = try await webView.evaluateJavaScript("document.getElementById('status').textContent") as? String
        XCTAssertEqual(statusAfterApproval, "paid")

        let cardObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        )
        let cardSnapshot = try XCTUnwrap(cardObservation["snapshot_id"] as? String)
        let cardElements = try XCTUnwrap(cardObservation["interactive_elements"] as? [[String: Any]])
        let cardRef = try XCTUnwrap(cardElements.first {
            ($0["selector"] as? String)?.contains("#card-number") == true
        }?["ref"] as? String)
        let cardInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "target": cardRef,
            "snapshot_id": cardSnapshot,
            "text": "4111111111111111"
        ])
        let cardOutput = await executor.execute(executor.executionRequest(
            toolName: "wm_type",
            operation: cardInput,
            isUserInitiated: false,
            runId: "submit-run",
            conversationId: "submit-conversation"
        ))
        guard case .needsUserAction(let handoffReason) = cardOutput else {
            return XCTFail("Expected sensitive-field human handoff")
        }
        XCTAssertTrue(handoffReason.hasPrefix("human_handoff:"))
        XCTAssertTrue(executor.webMountHandoffIsPending(toolName: "wm_type", input: cardInput))
        XCTAssertTrue(
            executor.completeWebMountHumanHandoff(
                toolName: "wm_type",
                input: cardInput,
                runId: "submit-run"
            )
        )
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: runtime.snapshot.sessionId)?.controlOwner,
            .agent
        )
        let cardValue = try await webView.evaluateJavaScript("document.getElementById('card-number').value") as? String
        XCTAssertEqual(cardValue, "")
        XCTAssertFalse(handoffReason.contains("4111111111111111"))
    }

    func testWebMountStationsUsesRegistryAndRedactedCookieSummary() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let output = await controller.execute(toolName: "wm_stations", input: "{}", isUserInitiated: false)
        let object = try jsonObject(output)

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["count"] as? Int, 9)
        XCTAssertFalse(output.contains("cookie-value"))
        let stations = try XCTUnwrap(object["stations"] as? [[String: Any]])
        XCTAssertEqual(object["eval_supported"] as? Bool, false)
        XCTAssertNil(object["eval_enabled"])
        XCTAssertTrue(stations.contains { ($0["id"] as? String) == "github" })
        let feishu = try XCTUnwrap(stations.first { ($0["id"] as? String) == "feishu_docs" })
        XCTAssertEqual(feishu["login_status"] as? String, "unknown")
        XCTAssertEqual(feishu["oauth_token_present"] as? Bool, false)
    }

    func testWebMountOpenAndExtractUseMockRuntimeAndRedactURLs() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        controller.registry.setEnabled(id: "github", enabled: true)
        let open = await controller.execute(
            toolName: "wm_open",
            input: #"{"site_id":"github","url":"https://github.com/login?token=secret"}"#,
            isUserInitiated: false
        )
        let openObject = try jsonObject(open)
        XCTAssertEqual(openObject["ok"] as? Bool, true)
        XCTAssertFalse(open.contains("token=secret"))

        let extract = await controller.execute(toolName: "wm_extract", input: #"{"mode":"readable"}"#, isUserInitiated: false)
        XCTAssertTrue(extract.contains("Hello from mock"))
        XCTAssertFalse(extract.contains("secret"))

        let get = await controller.execute(
            toolName: "wm_get",
            input: #"{"selector":"h1","kind":"text"}"#,
            isUserInitiated: false
        )
        let getObject = try jsonObject(get)
        XCTAssertEqual(getObject["ok"] as? Bool, true)
        let result = try XCTUnwrap(getObject["result"] as? [String: Any])
        XCTAssertEqual(result["selector"] as? String, "h1")
        XCTAssertEqual(result["value"] as? String, "Hello from mock")
    }

    func testWebMountTabLifecycleAndClosedSessionFailure() async throws {
        let controller = makeWebMountController(globalEnabled: true)

        let firstList = try jsonObject(await controller.execute(toolName: "wm_tab_list", input: "{}", isUserInitiated: true))
        XCTAssertEqual(firstList["count"] as? Int, 1)

        _ = try jsonObject(await controller.execute(toolName: "wm_tab_new", input: "{}", isUserInitiated: true))
        _ = try jsonObject(await controller.execute(toolName: "wm_tab_new", input: "{}", isUserInitiated: true))
        _ = await controller.execute(toolName: "wm_tab_new", input: "{}", isUserInitiated: true)

        let list = try jsonObject(await controller.execute(toolName: "wm_tab_list", input: "{}", isUserInitiated: true))
        XCTAssertLessThanOrEqual(list["count"] as? Int ?? 0, 3)
        let listedSessions = try XCTUnwrap(list["sessions"] as? [[String: Any]])
        let listedCurrentId = try XCTUnwrap(list["current_session_id"] as? String)
        let closeTargetId = try XCTUnwrap(
            listedSessions.compactMap { $0["session_id"] as? String }.first { $0 != listedCurrentId }
        )

        let closed = try jsonObject(await controller.execute(
            toolName: "wm_tab_close",
            input: IOSWebMountController.json(["session_id": closeTargetId]),
            isUserInitiated: true
        ))
        XCTAssertEqual(closed["closed_session_id"] as? String, closeTargetId)
        let liveSessionId = try XCTUnwrap(closed["current_session_id"] as? String)

        let staleState = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": closeTargetId]),
            isUserInitiated: true
        ))
        XCTAssertEqual(staleState["ok"] as? Bool, false)
        XCTAssertTrue((staleState["error"] as? String)?.contains(closeTargetId) == true)

        let liveState = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": liveSessionId]),
            isUserInitiated: true
        ))
        XCTAssertEqual(liveState["ok"] as? Bool, true)
        XCTAssertEqual(liveState["session_id"] as? String, liveSessionId)
    }

    func testWebMountAgentSessionBindingDoesNotStealVisibleTabAndHonorsUserControl() async throws {
        let visibleRuntime = MockWebMountRuntime(sessionId: "visible-session")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: visibleRuntime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let runA = IOSWebMountExecutionContext(runId: "run-a", conversationId: "conversation-a")
        let runB = IOSWebMountExecutionContext(runId: "run-b", conversationId: "conversation-b")

        let missingBinding = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: "{}",
            isUserInitiated: false,
            context: runA
        ))
        XCTAssertEqual(missingBinding["error_code"] as? String, "session_binding_required")

        let created = try jsonObject(await controller.execute(
            toolName: "wm_tab_new",
            input: "{}",
            isUserInitiated: false,
            context: runA
        ))
        let agentSessionId = try XCTUnwrap(created["session_id"] as? String)
        XCTAssertEqual(controller.sessionStore.currentSessionId, "visible-session")

        let runAState = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: runA
        ))
        XCTAssertEqual(runAState["ok"] as? Bool, true)
        XCTAssertEqual(controller.sessionStore.currentSessionId, "visible-session")

        let missingSnapshot = try jsonObject(await controller.execute(
            toolName: "wm_scroll",
            input: IOSWebMountController.json(["session_id": agentSessionId, "by_y": 200]),
            isUserInitiated: false,
            context: runA
        ))
        XCTAssertEqual(missingSnapshot["error_code"] as? String, "snapshot_required")

        let wrongConversation = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: runB
        ))
        XCTAssertEqual(wrongConversation["error_code"] as? String, "session_binding_mismatch")

        let wrongRun = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: IOSWebMountExecutionContext(runId: "run-c", conversationId: "conversation-a")
        ))
        XCTAssertEqual(wrongRun["error_code"] as? String, "session_binding_mismatch")

        _ = try controller.sessionStore.acquireUserControl(sessionId: agentSessionId)
        let observedWhileUserControls = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: runA
        ))
        XCTAssertEqual(observedWhileUserControls["ok"] as? Bool, true)
        XCTAssertEqual(controller.sessionStore.record(sessionId: agentSessionId)?.controlOwner, .user)

        let blockedByUser = try jsonObject(await controller.execute(
            toolName: "wm_back",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: runA
        ))
        XCTAssertEqual(blockedByUser["error_code"] as? String, "user_control_active")

        _ = try controller.sessionStore.handBackToAgent(sessionId: agentSessionId)
        let resumed = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: runA
        ))
        XCTAssertEqual(resumed["ok"] as? Bool, true)

        controller.releaseAgentOwnership(runId: runA.runId)
        XCTAssertNil(controller.sessionStore.record(sessionId: agentSessionId)?.ownerRunId)
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: agentSessionId)?.controlOwner,
            IOSWebMountControlOwner.none
        )

        let nextRun = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: IOSWebMountExecutionContext(runId: "run-c", conversationId: "conversation-a")
        ))
        XCTAssertEqual(nextRun["ok"] as? Bool, true)

        let otherConversation = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: runB
        ))
        XCTAssertEqual(otherConversation["error_code"] as? String, "session_binding_mismatch")

        _ = try controller.sessionStore.acquireUserControl(sessionId: agentSessionId)
        controller.releaseAgentOwnership(runId: "run-c")
        let releasedWhileUserControlled = try XCTUnwrap(
            controller.sessionStore.record(sessionId: agentSessionId)
        )
        XCTAssertNil(releasedWhileUserControlled.ownerRunId)
        XCTAssertEqual(releasedWhileUserControlled.controlOwner, .user)

        _ = try controller.sessionStore.handBackToAgent(sessionId: agentSessionId)
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: agentSessionId)?.controlOwner,
            IOSWebMountControlOwner.none
        )

        let rebound = try jsonObject(await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": agentSessionId]),
            isUserInitiated: false,
            context: IOSWebMountExecutionContext(runId: "run-d", conversationId: "conversation-a")
        ))
        XCTAssertEqual(rebound["ok"] as? Bool, true)
    }

    func testWebMountAgentMutationBecomesUnknownWhenControlChangesInFlight() async throws {
        let runtime = MockWebMountRuntime(sessionId: "control-race")
        runtime.suspendsInteraction = true
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(runId: "run-race", conversationId: "conversation-race")

        let action = Task { @MainActor in
            await controller.execute(
                toolName: "wm_scroll",
                input: IOSWebMountController.json([
                    "session_id": "control-race",
                    "snapshot_id": "mock-document:0",
                    "by_y": 120
                ]),
                isUserInitiated: false,
                context: context
            )
        }
        while runtime.interactionContinuation == nil {
            await Task.yield()
        }
        _ = try controller.sessionStore.acquireUserControl(sessionId: "control-race")
        runtime.resumeInteraction()

        let result = try jsonObject(await action.value)
        XCTAssertEqual(result["status"] as? String, "unknown_after_action")
        XCTAssertEqual(result["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(result["may_have_applied"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertEqual(controller.sessionStore.record(sessionId: "control-race")?.controlOwner, .user)
    }

    func testWebMountAgentMutationRequiresSemanticTargetAndBoundsInput() async throws {
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: MockWebMountRuntime(sessionId: "visible-semantic-target"),
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(
            runId: "run-semantic-target",
            conversationId: "conversation-semantic-target"
        )
        let created = try jsonObject(await controller.execute(
            toolName: "wm_tab_new",
            input: "{}",
            isUserInitiated: false,
            context: context
        ))
        let sessionId = try XCTUnwrap(created["session_id"] as? String)
        let observed = try jsonObject(await controller.execute(
            toolName: "wm_observe",
            input: IOSWebMountController.json(["session_id": sessionId]),
            isUserInitiated: false,
            context: context
        ))
        let snapshotId = try XCTUnwrap(observed["snapshot_id"] as? String)
        let runtime = try XCTUnwrap(
            controller.sessionStore.runtimeIfPresent(sessionId: sessionId) as? MockWebMountRuntime
        )

        let selectorAction = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "session_id": sessionId,
                "snapshot_id": snapshotId,
                "selector": "#submit"
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(selectorAction["error_code"] as? String, "semantic_target_required")
        XCTAssertEqual(runtime.interactionCallCount, 0)

        let oversizedKeys = try jsonObject(await controller.execute(
            toolName: "wm_keys",
            input: IOSWebMountController.json([
                "session_id": sessionId,
                "snapshot_id": snapshotId,
                "text": String(repeating: "x", count: 65)
            ]),
            isUserInitiated: false,
            context: context
        ))
        XCTAssertEqual(oversizedKeys["error_code"] as? String, "input_too_large")
        XCTAssertEqual(runtime.interactionCallCount, 0)
    }

    func testWebMountAgentNavigationBecomesUnknownWhenControlChangesInFlight() async throws {
        let runtime = MockWebMountRuntime(sessionId: "navigation-control-race")
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(
            runId: "run-navigation-race",
            conversationId: "conversation-navigation-race"
        )
        _ = await controller.execute(
            toolName: "wm_state",
            input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
            isUserInitiated: false,
            context: context
        )
        runtime.suspendsBack = true

        let action = Task { @MainActor in
            await controller.execute(
                toolName: "wm_back",
                input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]),
                isUserInitiated: false,
                context: context
            )
        }
        while runtime.navigationContinuation == nil { await Task.yield() }
        _ = try controller.sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
        runtime.resumeNavigation()

        let result = try jsonObject(await action.value)
        XCTAssertEqual(result["status"] as? String, "unknown_after_action")
        XCTAssertEqual(result["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(result["may_have_applied"] as? Bool, true)
        XCTAssertEqual(controller.sessionStore.record(sessionId: runtime.snapshot.sessionId)?.controlOwner, .user)
        XCTAssertEqual(controller.sessionStore.record(sessionId: runtime.snapshot.sessionId)?.needsReopen, true)
    }

    func testWebMountPostconditionVerificationBecomesUnknownWhenControlChangesInFlight() async throws {
        let runtime = MockWebMountRuntime(sessionId: "postcondition-control-race")
        runtime.suspendsInteraction = true
        runtime.suspendedInteractionMethod = "wait"
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )
        let context = IOSWebMountExecutionContext(
            runId: "run-postcondition-race",
            conversationId: "conversation-postcondition-race"
        )

        let action = Task { @MainActor in
            await controller.execute(
                toolName: "wm_scroll",
                input: IOSWebMountController.json([
                    "session_id": "postcondition-control-race",
                    "snapshot_id": "mock-document:0",
                    "by_y": 120,
                    "postcondition": [
                        "condition": "dom_stable",
                        "timeout_ms": 1_000
                    ]
                ]),
                isUserInitiated: false,
                context: context
            )
        }
        while runtime.interactionContinuation == nil {
            await Task.yield()
        }
        _ = try controller.sessionStore.acquireUserControl(sessionId: "postcondition-control-race")
        runtime.resumeInteraction()

        let result = try jsonObject(await action.value)
        XCTAssertEqual(result["status"] as? String, "unknown_after_action")
        XCTAssertEqual(result["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(result["may_have_applied"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertNotNil(result["postcondition"] as? [String: Any])
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: "postcondition-control-race")?.controlOwner,
            .user
        )
    }

    func testWebMountSessionTTLAndPersistentMetadataRestoreFreshRuntimeOnly() throws {
        let defaults = isolatedDefaults()
        var now: Int64 = 10_000
        var removedSessionIDs: [String] = []
        let store = IOSWebMountSessionStore(
            initialRuntime: MockWebMountRuntime(sessionId: "initial"),
            runtimeFactory: { MockWebMountRuntime() },
            restoredRuntimeFactory: { MockWebMountRuntime(sessionId: $0) },
            userDefaults: defaults,
            nowMillis: { now },
            onSessionRemoved: { removedSessionIDs.append($0) }
        )
        let initialRecordsRevision = store.recordsRevision
        let ephemeral = try store.newSession(persistent: false, makeCurrent: false)
        let persistent = try store.newSession(persistent: true, makeCurrent: false)
        XCTAssertGreaterThan(store.recordsRevision, initialRecordsRevision)
        _ = try store.bindAgentSession(
            sessionId: "initial",
            runId: "lease-run",
            conversationId: "lease-conversation",
            requiresControl: true
        )
        now += IOSWebMountSessionStore.agentLeaseMillis + 1
        let expiredLease = try XCTUnwrap(store.record(sessionId: "initial"))
        XCTAssertEqual(expiredLease.ownerRunId, "lease-run")
        XCTAssertEqual(expiredLease.controlOwner, .none)
        _ = try store.bindAgentSession(
            sessionId: "initial",
            runId: "lease-run",
            conversationId: "lease-conversation",
            requiresControl: true
        )
        XCTAssertEqual(store.record(sessionId: "initial")?.controlOwner, .agent)
        XCTAssertGreaterThan(store.record(sessionId: "initial")?.leaseExpiresAtMillis ?? 0, now)
        store.releaseAgentOwnership(runId: "lease-run")
        let beforeUserControlRevision = store.recordsRevision
        _ = try store.acquireUserControl(sessionId: "initial")
        XCTAssertGreaterThan(store.recordsRevision, beforeUserControlRevision)

        now += IOSWebMountSessionStore.ephemeralTTLMillis + 1
        XCTAssertNil(store.record(sessionId: ephemeral.id))
        XCTAssertEqual(removedSessionIDs, [ephemeral.id])
        XCTAssertNotNil(store.record(sessionId: persistent.id))
        XCTAssertEqual(store.record(sessionId: "initial")?.controlOwner, .user)

        let restoredStore = IOSWebMountSessionStore(
            runtimeFactory: { MockWebMountRuntime() },
            restoredRuntimeFactory: { MockWebMountRuntime(sessionId: $0) },
            userDefaults: defaults,
            nowMillis: { now }
        )
        let restored = try XCTUnwrap(restoredStore.record(sessionId: persistent.id))
        XCTAssertTrue(restored.persistentOptIn)
        XCTAssertTrue(restored.needsReopen)
        XCTAssertEqual(restored.status, "needs_reopen")
        XCTAssertEqual(restored.controlOwner, .none)
        let restoredRuntime = try XCTUnwrap(
            try restoredStore.runtime(sessionId: persistent.id, makeCurrent: false) as? MockWebMountRuntime
        )
        XCTAssertTrue(restoredRuntime.openedURLs.isEmpty)
        XCTAssertNil(restoredRuntime.snapshot.currentURL)
    }

    func testWebMountWatchRouteRequiresExactLocalRegisteredSession() throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let site = try XCTUnwrap(registry.sites.first)
        let store = IOSWebMountSessionStore(
            initialRuntime: MockWebMountRuntime(sessionId: "local-watch"),
            runtimeFactory: { MockWebMountRuntime() },
            userDefaults: defaults
        )
        store.tag(sessionId: "local-watch", site: site)

        let localRecord = try XCTUnwrap(store.record(sessionId: "local-watch"))
        let route = try XCTUnwrap(WebMountSiteRoute(watching: localRecord, registry: registry))
        XCTAssertEqual(route.sessionId, "local-watch")
        XCTAssertEqual(route.siteId, site.id)
        XCTAssertEqual(route.mode, .watch)

        let untagged = try store.newSession(persistent: false, makeCurrent: false)
        XCTAssertNil(WebMountSiteRoute(watching: untagged, registry: registry))

        let remote = try store.newSession(
            site: site,
            persistent: false,
            makeCurrent: false,
            backend: .moli,
            runtime: MockWebMountRuntime(sessionId: "remote-watch")
        )
        XCTAssertNil(WebMountSiteRoute(watching: remote, registry: registry))
    }

    func testWebMountSessionStoreDecodesLegacyV1MetadataWithDefaults() throws {
        let defaults = isolatedDefaults()
        let now: Int64 = 20_000
        let legacyPayload: [String: Any] = [
            "id": "legacy-local",
            "metadata": [
                "siteId": "github",
                "siteName": "GitHub",
                "lastTitle": "GitHub",
                "redactedURL": "https://github.com",
                "lastActivityMillis": now
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: [legacyPayload]),
            forKey: "app.amber.ios.webmount.persistent-sessions.v1"
        )
        defaults.set("legacy-local", forKey: "app.amber.ios.webmount.persistent-current-session.v1")

        let store = IOSWebMountSessionStore(
            runtimeFactory: { MockWebMountRuntime() },
            restoredRuntimeFactory: { MockWebMountRuntime(sessionId: $0) },
            userDefaults: defaults,
            nowMillis: { now }
        )

        let restored = try XCTUnwrap(store.record(sessionId: "legacy-local"))
        XCTAssertEqual(restored.backend, .local)
        XCTAssertTrue(restored.persistentOptIn)
        XCTAssertTrue(restored.needsReopen)
        XCTAssertEqual(restored.controlOwner, .none)
        XCTAssertNil(restored.ownerRunId)
        XCTAssertEqual(store.currentSessionId, "legacy-local")
    }

    func testWebMountOpenTimeoutReportsOutcomeUnknown() async throws {
        let defaults = isolatedDefaults()
        let runtime = MockWebMountRuntime(sessionId: "timeout-session")
        runtime.openResultOverride = IOSWebMountRuntimeSnapshot(
            sessionId: "timeout-session",
            status: .failed,
            requestedURL: "https://github.com",
            currentURL: nil,
            title: nil,
            estimatedProgress: 0.4,
            canGoBack: false,
            canGoForward: false,
            error: "load timed out after 1000ms",
            updatedAtMillis: 123
        )
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        registry.setEnabled(id: "github", enabled: true)
        let settings = IOSWebMountSettings(userDefaults: defaults)
        settings.globalEnabled = true
        let controller = IOSWebMountController(
            registry: registry,
            settings: settings,
            runtime: runtime,
            runtimeFactory: { MockWebMountRuntime() }
        )

        let result = try jsonObject(await controller.execute(
            toolName: "wm_open",
            input: #"{"site_id":"github","timeout_ms":1000}"#,
            isUserInitiated: true
        ))

        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["status"] as? String, "unknown_after_action")
        XCTAssertEqual(result["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(result["may_have_applied"] as? Bool, true)
        XCTAssertEqual(controller.sessionStore.record(sessionId: "timeout-session")?.needsReopen, true)
    }

    func testWebMountObserveSnapshotAndScreenshotAreRedacted() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let runtime = try XCTUnwrap(controller.runtime as? MockWebMountRuntime)
        controller.registry.setEnabled(id: "github", enabled: true)
        _ = await controller.execute(
            toolName: "wm_open",
            input: #"{"site_id":"github","url":"https://github.com/login?token=secret"}"#,
            isUserInitiated: true
        )

        let observe = await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        XCTAssertTrue(observe.contains("Hello from mock"))
        XCTAssertFalse(observe.contains("token=secret"))
        XCTAssertEqual(runtime.observeCallCount, 1)
        let observation = try jsonObject(observe)
        XCTAssertEqual(observation["untrusted_page_content"] as? Bool, true)
        XCTAssertEqual(observation["observation_consistency"] as? String, "unknown")

        let visual = await controller.execute(toolName: "wm_visual_snapshot", input: "{}", isUserInitiated: true)
        XCTAssertTrue(visual.contains("visual_candidates"))
        XCTAssertFalse(visual.contains("token=secret"))

        let blockedScreenshot = try jsonObject(await controller.execute(toolName: "wm_screenshot", input: "{}", isUserInitiated: false))
        XCTAssertEqual(blockedScreenshot["needs_user_action"] as? Bool, true)

        let screenshot = try jsonObject(await controller.execute(toolName: "wm_screenshot", input: "{}", isUserInitiated: true))
        XCTAssertEqual(screenshot["ok"] as? Bool, true)
        let artifact = try XCTUnwrap(screenshot["artifact"] as? [String: Any])
        XCTAssertEqual(artifact["format"] as? String, "png")
        XCTAssertEqual(artifact["width"] as? Int, 390)
        XCTAssertEqual(artifact["height"] as? Int, 844)
        XCTAssertEqual(artifact["size_bytes"] as? Int, 4)
        XCTAssertFalse(IOSWebMountController.json(screenshot).contains("base64"))
    }

    func testWebMountSiteAddRemoveSyncsAllowlistAndDoesNotClearCookies() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let cookieStore = try XCTUnwrap(controller.cookieStore as? MockWebMountCookieStore)

        let blockedAdd = try jsonObject(await controller.execute(
            toolName: "wm_site_add",
            input: #"{"display_name":"Example","homepage_url":"https://docs.example.com/a?token=secret"}"#,
            isUserInitiated: false
        ))
        XCTAssertEqual(blockedAdd["needs_user_action"] as? Bool, true)

        let added = try jsonObject(await controller.execute(
            toolName: "wm_site_add",
            input: #"{"display_name":"Example","homepage_url":"https://docs.example.com/a?token=secret","login_cookie_name":"sid"}"#,
            isUserInitiated: true
        ))
        XCTAssertEqual(added["ok"] as? Bool, true)
        let siteId = try XCTUnwrap(added["site_id"] as? String)
        XCTAssertEqual(added["enabled"] as? Bool, true)
        XCTAssertTrue(controller.settings.allowedHosts.contains("docs.example.com"))
        XCTAssertFalse(IOSWebMountController.json(added).contains("token=secret"))

        let removed = try jsonObject(await controller.execute(
            toolName: "wm_site_remove",
            input: IOSWebMountController.json(["site_id": siteId]),
            isUserInitiated: true
        ))
        XCTAssertEqual(removed["removed"] as? Bool, true)
        XCTAssertEqual(removed["cookies_cleared"] as? Bool, false)
        XCTAssertFalse(controller.settings.allowedHosts.contains("docs.example.com"))
        XCTAssertTrue(cookieStore.clearedSiteIds.isEmpty)
    }

    func testWebMountExecutorRequiresApprovalAndClearRequiresUserAction() async throws {
        let controller = makeWebMountController(globalEnabled: false)
        let executor = makeExecutor(webMountController: controller)
        let noAutoApprove = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:],
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: false,
            webSearchEnabled: false
        )

        let stationsOutput = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_stations",
                operation: "{}",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: noAutoApprove
            )
        )
        guard case .needsUserAction(let stationsReason) = stationsOutput else {
            return XCTFail("Expected needsUserAction, got \(stationsOutput)")
        }
        XCTAssertTrue(stationsReason.contains("WebMount browser tools"))

        let clearOutput = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_clear_session",
                operation: #"{"site_id":"github"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: noAutoApprove
            )
        )
        guard case .needsUserAction(let clearReason) = clearOutput else {
            return XCTFail("Expected needsUserAction, got \(clearOutput)")
        }
        XCTAssertTrue(clearReason.contains("Clearing WebMount cookies"))

        let screenshotOutput = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_screenshot",
                operation: "{}",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: noAutoApprove
            )
        )
        guard case .needsUserAction(let screenshotReason) = screenshotOutput else {
            return XCTFail("Expected needsUserAction, got \(screenshotOutput)")
        }
        XCTAssertTrue(screenshotReason.contains("wm_screenshot"))

        let siteAddOutput = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_site_add",
                operation: #"{"display_name":"Example","homepage_url":"https://example.com"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: noAutoApprove
            )
        )
        guard case .needsUserAction(let siteAddReason) = siteAddOutput else {
            return XCTFail("Expected needsUserAction, got \(siteAddOutput)")
        }
        XCTAssertTrue(siteAddReason.contains("wm_site_add"))
    }

    func testWebMountExecutorAllowsToolsAfterForegroundApproval() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)

        let output = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_stations",
                operation: "{}",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: true
            )
        )

        guard case .webMountResult(let text) = output else {
            return XCTFail("Expected WebMount result, got \(output)")
        }
        let object = try jsonObject(text)
        XCTAssertEqual(object["ok"] as? Bool, true)
    }

    func testWebMountExecutorRespectsDisabledPermissionPolicy() async throws {
        let defaults = isolatedDefaults()
        let permissionStore = IOSPermissionStore(userDefaults: defaults)
        let capability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.webmount.browser" }
        )
        permissionStore.setPolicy(.disabled, for: capability)
        let executor = makeExecutor(
            permissionStore: permissionStore,
            webMountController: makeWebMountController(globalEnabled: true)
        )

        let output = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_stations",
                operation: "{}",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )

        guard case .denied(let reason) = output else {
            return XCTFail("Expected denied, got \(output)")
        }
        XCTAssertTrue(reason.contains("Disabled"))
    }

    func testWebMountOpenRequiresRegisteredEnabledStation() async throws {
        let controller = makeWebMountController(globalEnabled: true)

        let missing = await controller.execute(
            toolName: "wm_open",
            input: #"{"url":"https://removed.example.com/path?token=secret"}"#,
            isUserInitiated: true
        )
        let missingObject = try jsonObject(missing)
        XCTAssertEqual(missingObject["denied"] as? Bool, true)
        XCTAssertFalse(missing.contains("token=secret"))

        let disabled = await controller.execute(
            toolName: "wm_open",
            input: #"{"site_id":"github"}"#,
            isUserInitiated: true
        )
        let disabledObject = try jsonObject(disabled)
        XCTAssertEqual(disabledObject["denied"] as? Bool, true)
        XCTAssertEqual(disabledObject["site_id"] as? String, "github")
    }

    func testWebMountHighRiskAutoApproveOpensUnlistedHostAndOffRestoresAllowlist() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        let sessionId = try XCTUnwrap(controller.sessionStore.records.first?.id)
        let url = "https://unlisted.amber.invalid/path"

        let disabledOutput = await executor.execute(IOSLocalToolExecutionRequest(
            toolName: "wm_open",
            operation: IOSWebMountController.json([
                "session_id": sessionId,
                "url": "https://github.com/"
            ]),
            scopeDigest: "",
            payloadDigest: "",
            isUserInitiated: false,
            runId: "high-risk-run",
            conversationId: "high-risk-conversation",
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:],
                globalAutoApproveEnabled: false,
                highRiskAutoApproveEnabled: true,
                execJavaScriptEnabled: false,
                webSearchEnabled: false
            )
        ))
        guard case .webMountResult(let disabledText) = disabledOutput else {
            return XCTFail("Expected disabled-site WebMount result, got \(disabledOutput)")
        }
        XCTAssertEqual(try jsonObject(disabledText)["denied"] as? Bool, true)

        let output = await executor.execute(IOSLocalToolExecutionRequest(
            toolName: "wm_open",
            operation: IOSWebMountController.json(["session_id": sessionId, "url": url]),
            scopeDigest: "",
            payloadDigest: "",
            isUserInitiated: false,
            runId: "high-risk-run",
            conversationId: "high-risk-conversation",
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:],
                globalAutoApproveEnabled: false,
                highRiskAutoApproveEnabled: true,
                execJavaScriptEnabled: false,
                webSearchEnabled: false
            )
        ))

        guard case .webMountResult(let text) = output else {
            return XCTFail("Expected high-risk WebMount result, got \(output)")
        }
        XCTAssertEqual(try jsonObject(text)["ok"] as? Bool, true)
        let record = try XCTUnwrap(controller.sessionStore.record(sessionId: sessionId))
        XCTAssertNil(record.siteId)
        XCTAssertEqual(record.redactedURL, url)
        XCTAssertNotNil(WebMountSiteRoute(watching: record, registry: controller.registry))

        controller.releaseAgentOwnership(runId: "high-risk-run")
        let blockedOutput = await executor.execute(IOSLocalToolExecutionRequest(
            toolName: "wm_state",
            operation: IOSWebMountController.json(["session_id": sessionId]),
            scopeDigest: "",
            payloadDigest: "",
            isUserInitiated: false,
            runId: "off-run",
            conversationId: "high-risk-conversation",
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:],
                globalAutoApproveEnabled: true,
                highRiskAutoApproveEnabled: false,
                execJavaScriptEnabled: false,
                webSearchEnabled: false
            )
        ))
        guard case .webMountResult(let blockedText) = blockedOutput else {
            return XCTFail("Expected allowlist-restored WebMount result, got \(blockedOutput)")
        }
        let blocked = try jsonObject(blockedText)
        XCTAssertEqual(blocked["denied"] as? Bool, true)
        XCTAssertEqual(blocked["error_code"] as? String, "high_risk_auto_approve_required")
    }

    func testWebMountGetDeniesHtmlAndSensitiveValueSelectors() async throws {
        let controller = makeWebMountController(globalEnabled: true)

        let html = await controller.execute(
            toolName: "wm_get",
            input: #"{"selector":"body","kind":"html"}"#,
            isUserInitiated: true
        )
        let htmlObject = try jsonObject(html)
        XCTAssertEqual(htmlObject["denied"] as? Bool, true)

        let token = await controller.execute(
            toolName: "wm_get",
            input: #"{"selector":"input[name=csrf_token]","kind":"value"}"#,
            isUserInitiated: true
        )
        let tokenObject = try jsonObject(token)
        XCTAssertEqual(tokenObject["denied"] as? Bool, true)

        let valueAttribute = await controller.execute(
            toolName: "wm_get",
            input: #"{"selector":"input","kind":"attr","attr_name":"value"}"#,
            isUserInitiated: true
        )
        let valueAttributeObject = try jsonObject(valueAttribute)
        XCTAssertEqual(valueAttributeObject["denied"] as? Bool, true)
    }

    func testWebMountContentHandoffRedactsAndBuildsChatAndBoardPayloads() throws {
        let site = try XCTUnwrap(IOSWebMountSite.seeds(nowMillis: 1).first { $0.id == "github" })
        let snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: "handoff",
            status: .ready,
            requestedURL: "https://github.com/login",
            currentURL: "https://github.com/settings",
            title: "Settings",
            estimatedProgress: 1,
            canGoBack: true,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 2
        )

        let handoff = try XCTUnwrap(IOSWebMountContentHandoff.from(
            site: site,
            snapshot: snapshot,
            extraction: [
                "title": "Account",
                "url": "https://github.com/settings?token=secret",
                "text": "Profile link https://github.com/settings?token=secret Authorization: Bearer abcdef123456",
                "links": [
                    ["href": "https://github.com/settings?token=secret"]
                ]
            ]
        ))

        XCTAssertFalse(handoff.text.contains("token=secret"))
        XCTAssertFalse(handoff.chatPrompt.contains("abcdef123456"))
        XCTAssertEqual(handoff.boardSignal.sourceType, IOSBoardSignalSourceType.webmount)
        XCTAssertTrue(handoff.boardSignal.metadataJson.contains(#""redacted":true"#))
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

    private func makeExecutor(
        permissionStore: IOSPermissionStore? = nil,
        documentStore: DocumentAccessStore = DocumentAccessStore(),
        workspaceStore: IOSWorkspaceStore = IOSWorkspaceStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        webMountController: IOSWebMountController? = nil
    ) -> IOSLocalToolExecutor {
        IOSLocalToolExecutor(
            permissionStore: permissionStore ?? IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore,
            workspaceStore: workspaceStore,
            webMountController: webMountController
        )
    }

    private func makeWebMountController(globalEnabled: Bool) -> IOSWebMountController {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let settings = IOSWebMountSettings(userDefaults: defaults)
        settings.globalEnabled = globalEnabled
        return IOSWebMountController(
            registry: registry,
            settings: settings,
            cookieStore: MockWebMountCookieStore(),
            runtime: MockWebMountRuntime(),
            runtimeFactory: { MockWebMountRuntime() },
            resolveHost: { _ in ["93.184.216.34"] }
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeTempFile(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data(repeating: 65, count: size).write(to: url)
        return url
    }

    private func makeTempFile(text: String, extension fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeWorkspaceStore() -> IOSWorkspaceStore {
        IOSWorkspaceStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }

    private func utf8String(using scalar: String, bytes: Int) -> String {
        let scalarBytes = scalar.utf8.count
        let repetitions = bytes / scalarBytes
        let remainder = bytes % scalarBytes
        return String(repeating: scalar, count: repetitions)
            + String(repeating: "x", count: remainder)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "app.amber.ios.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private extension Result where Success == URL, Failure == IOSWebMountURLPolicyError {
    var failure: IOSWebMountURLPolicyError? {
        switch self {
        case .success:
            nil
        case .failure(let error):
            error
        }
    }
}

@MainActor
private final class MockWebMountCookieStore: IOSWebMountCookieStoreProtocol {
    var clearedSiteIds: [String] = []

    func summary(for site: IOSWebMountSite) async -> IOSWebMountCookieSummary {
        IOSWebMountCookieSummary(
            siteId: site.id,
            cookieCount: site.id == "github" ? 1 : 0,
            cookieNames: site.id == "github" ? ["user_session"] : [],
            domains: site.id == "github" ? ["github.com"] : [],
            hasLoginCookie: site.loginCookieName.map { $0 == "user_session" },
            redacted: true
        )
    }

    func clearSession(for site: IOSWebMountSite) async -> IOSWebMountCookieClearResult {
        clearedSiteIds.append(site.id)
        return IOSWebMountCookieClearResult(
            siteId: site.id,
            deletedCookieCount: 1,
            clearedWebsiteDataRecords: 1
        )
    }
}

@MainActor
private final class MockWebMountRuntime: IOSWebMountRuntimeServicing {
    private static var nextId = 0

    /// Reset the shared session-id counter so each test starts from a known
    /// base. Without this a stale counter shifts the mock ids across tests,
    /// which made `testWebMountTabLifecycleAndClosedSessionFailure` pass in
    /// isolation but fail in the full suite (order-dependent test pollution).
    static func resetSessionCounter() { nextId = 0 }

    var snapshot: IOSWebMountRuntimeSnapshot
    var webView: WKWebView? { nil }
    var openedURLs: [URL] = []
    var lastInteraction: (method: String, selector: String?, text: String?, options: [String: Any])?
    var pageRevision = 0
    var waitMatched = false
    private(set) var observeCallCount = 0
    private(set) var interactionCallCount = 0
    var openResultOverride: IOSWebMountRuntimeSnapshot?
    var suspendsInteraction = false
    var suspendedInteractionMethod: String?
    private(set) var interactionContinuation: CheckedContinuation<Void, Never>?
    var suspendsBack = false
    private(set) var navigationContinuation: CheckedContinuation<Void, Never>?

    init(sessionId: String? = nil) {
        if let sessionId {
            snapshot = IOSWebMountRuntimeSnapshot.idle(sessionId: sessionId)
        } else {
            Self.nextId += 1
            snapshot = IOSWebMountRuntimeSnapshot.idle(sessionId: "mock-\(Self.nextId)")
        }
    }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        openedURLs.append(url)
        if let openResultOverride {
            snapshot = openResultOverride
            return snapshot
        }
        snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: snapshot.sessionId,
            status: .ready,
            requestedURL: IOSWebMountRedactor.redactedURL(url.absoluteString),
            currentURL: IOSWebMountRedactor.redactedURL(url.absoluteString),
            title: "Mock Page",
            estimatedProgress: 1,
            canGoBack: openedURLs.count > 1,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 123
        )
        return snapshot
    }

    func state() async throws -> [String: Any] {
        [
            "url": "https://github.com/login?token=secret",
            "title": "Mock Page",
            "ready_state": "complete",
            "page_revision": pageRevision,
            "snapshot_id": "mock-document:\(pageRevision)"
        ]
    }

    func observe(maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        observeCallCount += 1
        return [
            "document_id": "mock-document",
            "page_revision": pageRevision,
            "snapshot_id": "mock-document:\(pageRevision)",
            "page": try await state(),
            "visible_text": "Hello from mock",
            "interactive_elements": [
                ["ref": "css:button", "tag": "button", "text": "Sign in"]
            ],
            "visual_candidates": [
                ["ref": "css:img", "tag": "img", "alt": "Logo", "rect": ["width": 120, "height": 40]]
            ],
            "links": [
                ["href": "https://github.com/settings?token=secret", "text": "settings"]
            ]
        ]
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        [
            "mode": mode,
            "text": "Hello from mock",
            "nodes": [
                ["ref": "css:button", "tag": "button", "text": "Sign in"]
            ],
            "visual_candidates": [
                ["ref": "css:img", "tag": "img", "alt": "Logo", "rect": ["width": 120, "height": 40]]
            ],
            "links": [
                ["href": "https://github.com/settings?token=secret", "text": "settings"]
            ]
        ]
    }

    func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) async throws -> [String: Any] {
        [
            "ok": true,
            "selector": selector ?? target ?? "body",
            "kind": kind,
            "value": "Hello from mock"
        ]
    }

    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any] {
        interactionCallCount += 1
        lastInteraction = (method, selector, text, options)
        if suspendsInteraction,
           (suspendedInteractionMethod == nil || suspendedInteractionMethod == method),
           options["_amber_postcondition_probe"] as? Bool != true {
            await withCheckedContinuation { continuation in
                interactionContinuation = continuation
            }
        }
        if method != "find" && method != "wait" {
            pageRevision += 1
        }
        var result: [String: Any] = [
            "ok": true,
            "method": method,
            "found": true,
            "snapshot_id": "mock-document:\(pageRevision)"
        ]
        if method == "wait" { result["matched"] = waitMatched }
        return result
    }

    func resumeInteraction() {
        interactionContinuation?.resume()
        interactionContinuation = nil
        suspendsInteraction = false
        suspendedInteractionMethod = nil
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        IOSWebMountScreenshotCapture(data: Data([0x89, 0x50, 0x4E, 0x47]), width: 390, height: 844, format: "png")
    }

    func back() async -> IOSWebMountRuntimeSnapshot {
        if suspendsBack {
            await withCheckedContinuation { continuation in
                navigationContinuation = continuation
            }
        }
        snapshot.status = .ready
        return snapshot
    }

    func resumeNavigation() {
        navigationContinuation?.resume()
        navigationContinuation = nil
        suspendsBack = false
    }

    func forward() async -> IOSWebMountRuntimeSnapshot {
        snapshot.status = .ready
        return snapshot
    }
}
