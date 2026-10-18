import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
final class IOSWebMountSessionToolTests: IOSWebMountToolTestCase {
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
        let anonymous = try XCTUnwrap(stations.first { $0["auth_kind"] as? String == "anonymous" })
        XCTAssertEqual(anonymous["login_status"] as? String, "not_required")
        XCTAssertEqual(anonymous["authentication_required"] as? Bool, false)
        XCTAssertTrue(stations.allSatisfy { $0["login_verified"] as? Bool == false })
        let github = try XCTUnwrap(stations.first { $0["id"] as? String == "github" })
        XCTAssertEqual(github["login_status"] as? String, "unknown")
        XCTAssertEqual(github["authentication_evidence"] as? String, "cookie_present_unverified")
    }

    func testWebMountSiteIDAndDirectURLUseSameRegisteredHostPolicy() async throws {
        let controller = makeWebMountController(globalEnabled: true, resolveHost: { host in
            host == "github.com" ? ["198.18.0.34"] : ["10.0.0.34"]
        })
        controller.registry.setEnabled(id: "github", enabled: true)
        let site = try XCTUnwrap(controller.registry.site(id: "github"))
        for args in [["site_id": site.id], ["url": site.homepageURL]] {
            let output = try jsonObject(await controller.execute(
                toolName: "wm_open", input: IOSWebMountController.json(args),
                isUserInitiated: false, allowUnlistedHosts: true
            ))
            XCTAssertEqual(output["ok"] as? Bool, true, IOSWebMountController.json(output))
        }
        let denied = try jsonObject(await controller.execute(
            toolName: "wm_open", input: #"{"url":"https://unlisted.amber.invalid/"}"#,
            isUserInitiated: false, allowUnlistedHosts: true
        ))
        XCTAssertEqual(denied["error_code"] as? String, "dns_non_public_address")
        let runtime = try XCTUnwrap(controller.runtime as? MockWebMountRuntime)
        XCTAssertEqual(runtime.openedURLs.map(\.absoluteString), [site.homepageURL, site.homepageURL])
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

    func testWebMountReclaimedAgentSessionKeepsReopenEntryAndCardState() throws {
        var now: Int64 = 30_000
        let store = IOSWebMountSessionStore(
            initialRuntime: MockWebMountRuntime(sessionId: "reopen-local"),
            runtimeFactory: { MockWebMountRuntime() },
            restoredRuntimeFactory: { MockWebMountRuntime(sessionId: $0) },
            nowMillis: { now }
        )
        let session = try store.newSession(persistent: false, makeCurrent: false)
        _ = try store.bindAgentSession(
            sessionId: session.id,
            runId: "reopen-run",
            conversationId: "reopen-conversation",
            requiresControl: true
        )
        store.hideCard(sessionId: session.id)
        store.releaseAgentOwnership(runId: "reopen-run")

        now += IOSWebMountSessionStore.ephemeralTTLMillis + 1
        let reclaimed = try XCTUnwrap(store.record(sessionId: session.id))
        XCTAssertTrue(reclaimed.needsReopen)
        XCTAssertTrue(reclaimed.cardHidden)
        XCTAssertNil(store.runtimeIfPresent(sessionId: session.id))
        XCTAssertFalse(store.activeRecords.contains { $0.id == session.id })
        store.showCard(sessionId: session.id)
        store.hideCard(sessionId: session.id)
        XCTAssertTrue(try XCTUnwrap(store.record(sessionId: session.id)).cardHidden)

        let reopened = try XCTUnwrap(store.reopen(sessionId: session.id))
        XCTAssertEqual(reopened.id, session.id)
        XCTAssertTrue(reopened.needsReopen)
        XCTAssertNotNil(store.runtimeIfPresent(sessionId: session.id))
        store.showCard(sessionId: session.id)
        XCTAssertFalse(try XCTUnwrap(store.record(sessionId: session.id)).cardHidden)
        now += IOSWebMountSessionStore.ephemeralTTLMillis + 1
        XCTAssertTrue(try XCTUnwrap(store.record(sessionId: session.id)).needsReopen)
        _ = try store.close(sessionId: session.id)
        XCTAssertNil(store.record(sessionId: session.id))
    }

    func testWebMountCardWindowKeepsFifthNextTurnAndExpiresOnSixthWhileTouchRefreshesActivity() throws {
        let dates = (0..<7).map { second in
            Kotlinx_datetimeLocalDateTime(
                year: 2026,
                month: 9,
                day: 8,
                hour: 0,
                minute: 0,
                second: Int32(second),
                nanosecond: 0
            )
        }
        let messages = dates.map { date in
            UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.user,
                parts: [UIMessagePart.Text(text: "turn", metadata: nil)],
                annotations: [],
                createdAt: date,
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }
        let afterFifthNextTurn = ChatView.webMountRecentUserTurnStartMillis(
            from: Array(messages.prefix(6))
        )
        let afterSixthNextTurn = ChatView.webMountRecentUserTurnStartMillis(from: messages)
        XCTAssertEqual(afterFifthNextTurn, ChatContextSnapshot.epochMillis(from: dates[0]))
        XCTAssertEqual(afterSixthNextTurn, ChatContextSnapshot.epochMillis(from: dates[1]))

        var now = try XCTUnwrap(afterFifthNextTurn) + 1
        let store = IOSWebMountSessionStore(
            initialRuntime: MockWebMountRuntime(sessionId: "touch-session"),
            nowMillis: { now }
        )
        _ = try store.bindAgentSession(sessionId: "touch-session", runId: "run", conversationId: "conversation", requiresControl: true)
        store.releaseAgentOwnership(runId: "run")
        let original = try XCTUnwrap(store.record(sessionId: "touch-session"))
        XCTAssertTrue(ChatView.webMountSessionIsRetained(original, conversationId: "conversation", recentUserTurnStartMillis: afterFifthNextTurn))
        XCTAssertFalse(ChatView.webMountSessionIsRetained(original, conversationId: "conversation", recentUserTurnStartMillis: afterSixthNextTurn))

        now = try XCTUnwrap(afterSixthNextTurn) + 1
        store.touch(sessionId: original.id, makeCurrent: false)
        let renewed = try XCTUnwrap(store.record(sessionId: original.id))
        XCTAssertTrue(ChatView.webMountSessionIsRetained(renewed, conversationId: "conversation", recentUserTurnStartMillis: afterSixthNextTurn))
        XCTAssertFalse(ChatView.webMountSessionIsRetained(renewed, conversationId: "another-conversation", recentUserTurnStartMillis: afterSixthNextTurn))
        store.hideCard(sessionId: original.id)
        store.touch(sessionId: original.id, makeCurrent: false)
        XCTAssertFalse(ChatView.webMountSessionIsRetained(try XCTUnwrap(store.record(sessionId: original.id)), conversationId: "conversation", recentUserTurnStartMillis: afterSixthNextTurn))

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

}
