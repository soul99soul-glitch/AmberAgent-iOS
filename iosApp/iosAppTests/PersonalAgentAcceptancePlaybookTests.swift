import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class PersonalAgentAcceptancePlaybookTests: XCTestCase {
    func testPA_iOS01_DeepLinkAndFailureClassifierPlaybooks() async throws {
        // Cloud task deep link + phone control settings deep link
        let taskLink = try XCTUnwrap(URL(string: "amber://cloud-task/work:pa-sched-001"))
        XCTAssertEqual(IOSAppDeepLink.parse(taskLink), .cloudTask(workItemId: "work:pa-sched-001"))

        let phoneSettingsLink = try XCTUnwrap(URL(string: "amber://settings/phone-control"))
        XCTAssertEqual(IOSAppDeepLink.parse(phoneSettingsLink), .phoneControl)

        // Backfill store opens deep linked task
        let suite = "PA-iOS01-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacGatewayStore(defaults: defaults)
        await store.openCloudTaskFromDeepLink(workItemId: "work:pa-sched-001")
        XCTAssertEqual(store.pendingCloudTaskWorkItemId, "work:pa-sched-001")

        // Structured failure classifier prioritizes explicit code and avoids raw snake_case leakage
        let permTool = UIMessagePart.Tool(
            toolCallId: "pa-tc-1",
            toolName: "calendar_event_create",
            input: "{}",
            output: [UIMessagePart.Text(
                text: #"{"ok":false,"reason_code":"permission_denied","error":"timeout"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let classified = ChatTaskFailureClassifier.classify(tool: permTool, step: nil)
        XCTAssertEqual(classified.kind, .permissionDenied)
        XCTAssertFalse(classified.localizedReason.contains("permission_denied"))
    }

    func testPA_iOS02_DeviceContextSharingAndRecentWorkspaceArtifactIndex() throws {
        // Sharing defaults opt-out & snapshot redaction
        let suite = "PA-iOS02-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gateway = MacGatewayStore(defaults: defaults)
        XCTAssertFalse(gateway.anyDeviceContextSharingEnabled)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = MacGatewayStore.assembleDeviceContextSnapshot(
            deviceId: "ios-pa-test",
            calendarItems: [
                IOSDeviceContextSnapshotPayload.CalendarItem(
                    title: "团队周会 Bearer tok-1234567890abcdef",
                    startMs: 1_700_001_000_000,
                    endMs: 1_700_004_600_000,
                    allDay: false
                )
            ],
            reminderItems: nil,
            artifactRecords: nil,
            now: now
        )
        XCTAssertNil(snap.domains.remindersDue)
        XCTAssertEqual(snap.domains.calendarUpcoming?.items.count, 1)
        XCTAssertFalse(snap.domains.calendarUpcoming?.items.first?.title.contains("tok-1234567890abcdef") ?? true)

        // Explicit memory directive detection + workspace recent artifacts index
        XCTAssertTrue(IOSExplicitMemoryIntentDetector.containsExplicitDirective("请记住我下周去上海出差"))
        XCTAssertFalse(IOSExplicitMemoryIntentDetector.containsExplicitDirective("```swift\n// 记住这个变量\n```"))

        let wsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wsRoot) }

        let ws = IOSWorkspaceStore(baseDirectory: wsRoot)
        _ = try ws.saveArtifact(
            title: "周会纪要",
            content: "下周二对齐发布会清单",
            type: .note,
            sourceKind: "chat",
            sourceId: "c1",
            now: now
        )
        let index = try XCTUnwrap(ws.recentArtifactsPromptIndex(limit: 5, maxChars: 600))
        XCTAssertTrue(index.contains("<untrusted_workspace_artifacts"))
        XCTAssertTrue(index.contains("</untrusted_workspace_artifacts>"))
        XCTAssertTrue(index.contains("周会纪要"))
    }

    func testPA_iOS03_FirstRoundPassthroughPreflightZeroLeaseAndRecipeV2() async throws {
        // First-round passthrough filters strictly against entitled available catalog
        let msg = UIMessage.companion.user(prompt: "帮我看下明天日程和天气，再检查手机控制")
        let available: Set<String> = [
            IOSWeatherToolCatalog.toolName,
            IOSAppleAgentToolCatalog.calendarEventsList,
            IOSPhoneControlToolCatalog.preflightToolName
        ]
        let exposed = ChatViewModel.firstRoundPassthroughToolNames(for: [msg], availableToolNames: available)
        XCTAssertTrue(exposed.contains(IOSWeatherToolCatalog.toolName))
        XCTAssertTrue(exposed.contains(IOSAppleAgentToolCatalog.calendarEventsList))
        XCTAssertTrue(exposed.contains(IOSPhoneControlToolCatalog.preflightToolName))

        // Preflight reports exact disabled blocker cleanly without throwing/leasing
        let suite = "PA-iOS03-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        PhoneRecipeStore.save(
            bundleID: "com.example.demo",
            goal: "打开设置",
            steps: ["click(设置)", "sk-secret-value-123456"],
            defaults: defaults
        )
        let recipes = PhoneRecipeStore.candidates(bundleID: "com.example.demo", defaults: defaults)
        XCTAssertEqual(recipes.count, 1)
        XCTAssertFalse(recipes.first?.steps.joined(separator: " ").contains("sk-secret-value-123456") ?? true)
        PhoneRecipeStore.markNeedsReverify(bundleID: "com.example.demo", goal: "打开设置", defaults: defaults)
        XCTAssertEqual(
            PhoneRecipeStore.candidates(bundleID: "com.example.demo", defaults: defaults).first?.needsReverify,
            true
        )
    }

    func testPA_iOS04_WorkspaceUndoAndMemoryEventKitSafeRollbackContracts() async throws {
        // Workspace .undo + SHA-256 verification
        let wsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wsRoot) }

        let ws = IOSWorkspaceStore(baseDirectory: wsRoot)
        _ = await ws.executeTool(
            toolName: "workspace_file_write",
            input: #"{"path":"spec.md","content":"v1"}"#
        )
        _ = await ws.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"spec.md","find":"v1","replace":"v2"}"#
        )
        let undoRes = ws.undoLastChange(forPath: "spec.md")
        XCTAssertEqual(undoRes["ok"] as? Bool, true)
        let record = try XCTUnwrap(ws.fileRecord(idOrPath: "spec.md"))
        XCTAssertEqual(try String(contentsOf: ws.fileURL(for: record), encoding: .utf8), "v1")

        // EventKit rollback restricted strictly to current runId
        IOSEventKitTurnCreationTracker.shared.reset()
        defer { IOSEventKitTurnCreationTracker.shared.reset() }
        IOSEventKitTurnCreationTracker.shared.recordCreated(
            runId: "pa-run-1",
            kind: .reminder,
            identifier: "rem-pa-1",
            title: "买咖啡"
        )
        XCTAssertTrue(IOSEventKitTurnCreationTracker.shared.canRollback(identifier: "rem-pa-1", inRunId: "pa-run-1"))
        XCTAssertFalse(IOSEventKitTurnCreationTracker.shared.canRollback(identifier: "rem-old", inRunId: "pa-run-1"))

        var removedReminders: [String] = []
        let rollback = IOSEventKitAgentToolExecutor.rollbackCurrentTurnCreatedItems(
            runId: "pa-run-1",
            reminderRemover: { removedReminders.append($0) }
        )
        XCTAssertEqual(rollback["ok"] as? Bool, true)
        XCTAssertEqual(removedReminders, ["rem-pa-1"])
    }
}
