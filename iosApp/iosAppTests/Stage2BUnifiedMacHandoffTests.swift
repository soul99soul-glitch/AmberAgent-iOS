import Foundation
import Testing
@testable import iosApp

@Suite("Stage 2-B Unified Mac Handoff, Approvals & Share Sheet")
struct Stage2BUnifiedMacHandoffTests {
    private struct AlwaysPassBiometricAuth: MacGatewayBiometricAuthenticating {
        func verifyForegroundApproval(reason: String) async -> Bool { true }
    }

    private static func jsonResponse(url: URL, status: Int, json: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), response)
    }

    @MainActor
    private func makeTestStore(
        suiteSuffix: String,
        transport: @escaping MacGatewayClient.Transport
    ) throws -> (store: MacGatewayStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "Stage2BTests.\(suiteSuffix).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = MacGatewayStore(
            defaults: defaults,
            biometricAuthenticator: AlwaysPassBiometricAuth(),
            isApplicationForeground: { true }
        )
        let connection = MacGatewayConnection(
            gatewayId: "gw-stage2b",
            name: "Studio MacBook Pro",
            addrs: ["127.0.0.1"],
            port: 9443,
            fingerprint: "fp-stage2b",
            deviceId: "ios-stage2b"
        )
        let client = MacGatewayClient(
            addrs: connection.addrs,
            port: connection.port,
            fingerprint: connection.fingerprint,
            token: "tok-stage2b",
            transport: transport
        )
        store.configureForTesting(connection: connection, client: client)
        return (store, defaults, suiteName)
    }

    // MARK: - 1. Explicit Delegation Carries conversationId + Header & Never Silently Falls Back

    @Test @MainActor func explicitMacDelegationCarriesStableConversationIdAndNeverSilentlyFallsBackOnWeakNetwork() async throws {
        actor RequestRecorder {
            var failMainPost = true
            var receivedHeaders: [String: String] = [:]
            var receivedBodies: [String] = []
            func shouldFail() -> Bool { failMainPost }
            func setFail(_ fail: Bool) { failMainPost = fail }
            func record(headers: [String: String], body: String) {
                receivedHeaders = headers
                receivedBodies.append(body)
            }
            func snapshot() -> ([String: String], [String]) { (receivedHeaders, receivedBodies) }
        }
        let recorder = RequestRecorder()
        let convId = "conv-unified-2b-01"
        let reqWeak = "550e8400-e29b-41d4-a716-446655440001"
        let reqCancel = "550e8400-e29b-41d4-a716-446655440002"

        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "WeakNet") { request, _ in
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            let path = url.path
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let headers = request.allHTTPHeaderFields ?? [:]

            if method == "POST", path == "/v2/dialogue/messages" {
                await recorder.record(headers: headers, body: body)
                if await recorder.shouldFail() {
                    throw URLError(.timedOut)
                }
            }
            if method == "GET", path == "/v2/dialogue/receipts/\(reqWeak)" {
                return Self.jsonResponse(
                    url: url,
                    status: 200,
                    json: """
                    {
                      "eventId": "evt-weak-1",
                      "requestId": "\(reqWeak)",
                      "topicId": "topic-weak-1",
                      "workItemIds": ["work:mac-weak-1"],
                      "state": "received",
                      "replayed": true,
                      "conversationId": "\(convId)"
                    }
                    """
                )
            }
            if method == "GET", path == "/v2/dialogue/events" {
                return Self.jsonResponse(
                    url: url,
                    status: 200,
                    json: """
                    {
                      "items": [
                        {
                          "seq": 1,
                          "id": "evt-weak-progress",
                          "kind": "process_event",
                          "role": "system",
                          "text": "正在 Mac 端编译测试",
                          "topicId": "topic-weak-1",
                          "workItemId": "work:mac-weak-1",
                          "conversationId": "\(convId)"
                        }
                      ],
                      "nextCursor": 1,
                      "conversationId": "\(convId)"
                    }
                    """
                )
            }
            return Self.jsonResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
        }
        defer {
            store.stopCloudDialoguePolling()
            defaults.removePersistentDomain(forName: suiteName)
        }

        // First send hits weak network timeout -> must NOT silently fall back; stays as unconfirmed Mac run.
        let weakResult = await store.delegateToMacInUnifiedTimeline(
            text: "在 Mac 上跑完整构建",
            conversationId: convId,
            requestId: reqWeak
        )
        if case .success = weakResult {
            Issue.record("Expected timeout failure on weak network")
        }

        let (headers, bodies) = await recorder.snapshot()
        #expect(headers["X-Amber-Dialogue-Version"] == "1")
        let firstBody = try #require(bodies.first)
        let firstJSON = try #require(JSONSerialization.jsonObject(with: Data(firstBody.utf8)) as? [String: Any])
        #expect(firstJSON["conversationId"] as? String == convId)
        #expect(firstJSON["requestId"] as? String == reqWeak)

        let unconfirmedRuns = store.unifiedMacDelegatedRuns(for: convId)
        #expect(unconfirmedRuns.count == 1)
        let weakRun = try #require(unconfirmedRuns.first)
        #expect(weakRun.badge == .running)
        #expect(weakRun.isReceiptUnconfirmed == true)
        #expect(weakRun.conversationId == convId)

        // Explicit recovery action #1: Recheck status recovers receipt + progress on the same conversation.
        let recheckResult = await store.recheckPendingMacSubmission(requestId: reqWeak, workItemId: nil)
        store.stopCloudDialoguePolling()
        #expect((try? recheckResult.get()) != nil)
        let recoveredRuns = store.unifiedMacDelegatedRuns(for: convId)
        let recovered = try #require(recoveredRuns.first(where: { $0.workItemId == "work:mac-weak-1" }))
        #expect(recovered.badge == .running)
        #expect(recovered.isReceiptUnconfirmed == false)
        #expect(recovered.statusLine.contains("正在 Mac 端编译测试"))

        // Second weak-network send -> explicit cancel marks abandoned without local fallback.
        _ = await store.delegateToMacInUnifiedTimeline(
            text: "另一条弱网任务",
            conversationId: convId,
            requestId: reqCancel
        )
        let cancelled = await store.cancelPendingMacSubmission(requestId: reqCancel, workItemId: nil)
        #expect(cancelled == true)
        let cancelledRun = try #require(store.unifiedMacDelegatedRuns(for: convId).first(where: { $0.requestId == reqCancel }))
        #expect(cancelledRun.badge == .cancelled)
    }

    // MARK: - 2. Local B Unblocked While Mac A Runs + Source Annotations + Targeted Follow-Up

    @Test @MainActor func localChatRemainsUnblockedWhileMacRunsAndSourcesReturnToOriginalTimeline() async throws {
        actor FollowupCapture {
            var followupPath: String?
            var followupBody: String?
            var followupHeader: String?
            func record(path: String, body: String, header: String?) {
                followupPath = path
                followupBody = body
                followupHeader = header
            }
            func read() -> (String?, String?, String?) { (followupPath, followupBody, followupHeader) }
        }
        let capture = FollowupCapture()
        let convId = "conv-ab-parallel"
        let reqA = "550e8400-e29b-41d4-a716-446655440010"
        let reqFollow = "550e8400-e29b-41d4-a716-446655440011"

        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "ParallelAB") { request, _ in
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            let path = url.path
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            if method == "POST", path == "/v2/dialogue/messages" {
                return Self.jsonResponse(
                    url: url,
                    status: 202,
                    json: """
                    {
                      "eventId": "evt-mac-a-u",
                      "requestId": "\(reqA)",
                      "topicId": "topic-mac-a",
                      "workItemIds": ["work:mac-a"],
                      "state": "received",
                      "replayed": false,
                      "conversationId": "\(convId)"
                    }
                    """
                )
            }
            if method == "POST", path == "/v2/work-items/work:mac-a/inputs" {
                await capture.record(
                    path: path,
                    body: body,
                    header: request.value(forHTTPHeaderField: "X-Amber-Dialogue-Version")
                )
                return Self.jsonResponse(
                    url: url,
                    status: 202,
                    json: """
                    {
                      "eventId": "evt-mac-a-follow",
                      "requestId": "\(reqFollow)",
                      "topicId": "topic-mac-a",
                      "workItemIds": ["work:mac-a"],
                      "state": "received",
                      "replayed": false,
                      "conversationId": "\(convId)"
                    }
                    """
                )
            }
            if method == "GET", path == "/v2/dialogue/events" {
                return Self.jsonResponse(url: url, status: 200, json: #"{"items":[],"nextCursor":0}"#)
            }
            return Self.jsonResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
        }
        defer {
            store.stopCloudDialoguePolling()
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Arm "交给 Mac" in composer, submit Mac task A, then confirm composer resets to local default for B.
        var composerState = ChatComposerLocalState()
        composerState.isDelegateToMacArmed = true
        let receiptA = try await store.delegateToMacInUnifiedTimeline(
            text: "分析本地仓库日志",
            conversationId: convId,
            requestId: reqA
        ).get()
        store.stopCloudDialoguePolling()
        composerState.isDelegateToMacArmed = false

        #expect(receiptA.workItemIds == ["work:mac-a"])
        #expect(composerState.isDelegateToMacArmed == false, "After dispatching Mac A, local B must immediately default to local chat")
        #expect(store.isCloudMainDialogueSelected == false, "Unified timeline delegation must not force parallel cloud host mode")

        // Simulate Mac A running while user chats B locally on the same conversation.
        let runningJSON = """
        {
          "items": [
            {
              "seq": 1,
              "id": "evt-a-proc",
              "kind": "process_event",
              "role": "system",
              "text": "正在扫描工作区日志",
              "topicId": "topic-mac-a",
              "workItemId": "work:mac-a",
              "conversationId": "\(convId)"
            }
          ],
          "nextCursor": 1,
          "conversationId": "\(convId)"
        }
        """
        store.ingestCloudDialogueEventsPage(
            try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(runningJSON.utf8)),
            requestedAfter: 0
        )
        let runningRun = try #require(store.unifiedMacDelegatedRuns(for: convId).first(where: { $0.workItemId == "work:mac-a" }))
        #expect(runningRun.badge == .running)
        // Other conversations do not leak Mac A.
        #expect(store.unifiedMacDelegatedRuns(for: "conv-other-unrelated").isEmpty)

        // Mac A completes with sourceRefs + sourcePaths -> naturally returns to original conversation timeline.
        let doneJSON = """
        {
          "items": [
            {
              "seq": 2,
              "id": "evt-a-done",
              "kind": "task_result",
              "role": "assistant",
              "text": "日志分析完成：发现 2 处超时重试。",
              "topicId": "topic-mac-a",
              "workItemId": "work:mac-a",
              "outcome": "completed",
              "conversationId": "\(convId)",
              "sourceRefs": ["log://gateway#L42", "Sources/App.swift"],
              "sourcePaths": ["Sources/App.swift", "docs/report.md"]
            }
          ],
          "nextCursor": 2,
          "conversationId": "\(convId)"
        }
        """
        store.ingestCloudDialogueEventsPage(
            try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(doneJSON.utf8)),
            requestedAfter: 1
        )
        let completedRun = try #require(store.unifiedMacDelegatedRuns(for: convId).first(where: { $0.workItemId == "work:mac-a" }))
        #expect(completedRun.badge == .completed)
        #expect(completedRun.resultText == "日志分析完成：发现 2 处超时重试。")
        #expect(completedRun.sourceAnnotations == ["log://gateway#L42", "Sources/App.swift", "docs/report.md"])

        // Targeted modification follow-up goes to /v2/work-items/{id}/inputs with stable conversationId.
        _ = try await store.delegateToMacInUnifiedTimeline(
            text: "把超时堆栈一并摘出来",
            conversationId: convId,
            requestId: reqFollow,
            targetWorkItemId: "work:mac-a"
        ).get()
        store.stopCloudDialoguePolling()
        let (path, body, header) = await capture.read()
        #expect(path == "/v2/work-items/work:mac-a/inputs")
        #expect(header == "1")
        let followBody = try #require(body)
        let followJSON = try #require(JSONSerialization.jsonObject(with: Data(followBody.utf8)) as? [String: Any])
        #expect(followJSON["conversationId"] as? String == convId)
        #expect(followJSON["text"] as? String == "把超时堆栈一并摘出来")
    }

    // MARK: - 3. Lock Screen Redline + Mac Local Approval Redline (requiresLocalApproval & HTTP 403)

    @Test func lockScreenAndL3ApprovalsNeverExposeApproveButton() {
        let l3Approval = AgentActivityApproval(
            requestId: "req-l3",
            title: "git push --force",
            allowsInlineApprove: true,
            riskLevel: .l3
        )
        #expect(l3Approval.allowsInlineApprove == false, "L3 risk must force allowsInlineApprove to false")
        #expect(
            AgentActivityInlineControlPolicy.controls(
                presentation: .waitingForUser(approval: l3Approval),
                isStale: false,
                hasConversation: true,
                isLockScreen: false
            ) == [.deny]
        )
        #expect(
            AgentActivityInlineControlPolicy.controls(
                presentation: .waitingForUser(approval: l3Approval),
                isStale: false,
                hasConversation: true,
                isLockScreen: true
            ) == [.deny]
        )

        // Even an L2 approval with allowsInlineApprove=true must NEVER expose approve on the lock screen.
        let l2Approval = AgentActivityApproval(
            requestId: "req-l2",
            title: "write_file README.md",
            allowsInlineApprove: true,
            riskLevel: .l2
        )
        #expect(
            AgentActivityInlineControlPolicy.controls(
                presentation: .waitingForUser(approval: l2Approval),
                isStale: false,
                hasConversation: true,
                isLockScreen: true
            ) == [.deny]
        )
    }

    @Test @MainActor func requiresLocalApprovalAndHttp403BlockRemoteApproveWhileAllowingReject() async throws {
        actor DecisionSpy {
            var decideRequests: [(toolCallId: String, allow: Bool)] = []
            func record(toolCallId: String, allow: Bool) { decideRequests.append((toolCallId, allow)) }
            func all() -> [(toolCallId: String, allow: Bool)] { decideRequests }
        }
        let spy = DecisionSpy()

        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "LocalApprovalRedline") { request, _ in
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            let path = url.path

            if method == "GET", path == "/v1/status" {
                return Self.jsonResponse(
                    url: url,
                    status: 200,
                    json: """
                    {
                      "gateway": {"id": "gw-stage2b", "name": "Studio MacBook Pro"},
                      "device": {"id": "ios-stage2b", "name": "iPhone", "pushRegistered": true},
                      "serverTime": 1793500000,
                      "sessions": [
                        {
                          "key": "amber:run-local-only",
                          "agent": "amber",
                          "subject": "修改系统权限",
                          "origin": "amber",
                          "state": "waiting",
                          "abnormal": false,
                          "monitored": true,
                          "updatedAt": 1793500000,
                          "pendingApproval": {
                            "toolCallId": "call-local-only",
                            "tool": "shell_exec",
                            "detail": "sudo chmod 600 /etc/hosts",
                            "highRisk": true,
                            "requiresLocalApproval": true,
                            "summary": "修改系统 hosts 权限",
                            "diffPreview": "- rw-r--r-- /etc/hosts\\n+ rw------- /etc/hosts",
                            "riskLevel": "L3"
                          }
                        },
                        {
                          "key": "amber:run-403",
                          "agent": "amber",
                          "subject": "推送代码",
                          "origin": "amber",
                          "state": "waiting",
                          "abnormal": false,
                          "monitored": true,
                          "updatedAt": 1793500000,
                          "pendingApproval": {
                            "toolCallId": "call-403",
                            "tool": "git_push",
                            "detail": "git push origin main",
                            "highRisk": true,
                            "requiresLocalApproval": false,
                            "summary": "推送到受保护分支",
                            "diffPreview": "@@ -1,1 +1,2 @@\\n+release commit",
                            "riskLevel": "L3"
                          }
                        }
                      ]
                    }
                    """
                )
            }
            if method == "GET", path == "/v1/amber/board" {
                return Self.jsonResponse(url: url, status: 200, json: #"{"board":[]}"#)
            }
            if method == "GET", path == "/v1/amber/schedules" {
                return Self.jsonResponse(url: url, status: 200, json: #"{"schedules":[]}"#)
            }
            if method == "GET", path == "/v2/agents" {
                return Self.jsonResponse(url: url, status: 200, json: #"{"agents":[]}"#)
            }
            if method == "POST", path == "/v1/amber/decision" {
                let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let callId = body["toolCallId"] as? String ?? ""
                let allow = body["allow"] as? Bool ?? false
                await spy.record(toolCallId: callId, allow: allow)
                if callId == "call-403", allow == true {
                    return Self.jsonResponse(url: url, status: 403, json: #"{"error":"requires_local_approval"}"#)
                }
                return Self.jsonResponse(url: url, status: 200, json: #"{"ok":true}"#)
            }
            return Self.jsonResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await store.refresh()
        let cards = store.activeMacApprovalCardItems()
        let localOnlyCard = try #require(cards.first(where: { $0.toolCallId == "call-local-only" }))
        #expect(localOnlyCard.requiresLocalApproval == true)
        #expect(localOnlyCard.riskTier == .l3)
        #expect(localOnlyCard.effectivePreviewText?.contains("/etc/hosts") == true)

        // 1. requiresLocalApproval == true -> remote allow MUST fail closed locally without sending HTTP request.
        let allowedLocalOnly = await store.decide(
            sessionKey: "amber:run-local-only",
            toolCallId: "call-local-only",
            allow: true,
            source: .foregroundApp
        )
        #expect(allowedLocalOnly == false)
        #expect(store.notice?.text == "此高危操作请在 Mac 上批准")
        #expect(await spy.all().isEmpty, "Must not send remote approve when requiresLocalApproval == true")

        // Rejecting a local-only approval from iPhone is still permitted as safe stop-loss.
        let rejectedLocalOnly = await store.decide(
            sessionKey: "amber:run-local-only",
            toolCallId: "call-local-only",
            allow: false,
            source: .foregroundApp
        )
        #expect(rejectedLocalOnly == true)

        // 2. Server returns HTTP 403 -> iOS locks that callId to local-only and surfaces Mac approval warning.
        let allowed403 = await store.decide(
            sessionKey: "amber:run-403",
            toolCallId: "call-403",
            allow: true,
            source: .foregroundApp
        )
        #expect(allowed403 == false)
        #expect(store.notice?.text == "此高危操作请在 Mac 上批准")
        #expect(store.requiresLocalApprovalOnly(sessionKey: "amber:run-403", toolCallId: "call-403") == true)
        let upgradedCard = try #require(store.activeMacApprovalCardItems().first(where: { $0.toolCallId == "call-403" }))
        #expect(upgradedCard.requiresLocalApproval == true)

        // Subsequent approve attempt for call-403 is blocked locally without another network call.
        let countBeforeSecondAttempt = await spy.all().count
        let secondAttempt = await store.decide(
            sessionKey: "amber:run-403",
            toolCallId: "call-403",
            allow: true,
            source: .foregroundApp
        )
        #expect(secondAttempt == false)
        #expect(await spy.all().count == countBeforeSecondAttempt)
    }

    // MARK: - 4. outcomeUnknown Three Actions in Unified Timeline

    @Test @MainActor func outcomeUnknownSurfacesAndResolvesViaRecheckRetryAbandonInUnifiedTimeline() async throws {
        let convId = "conv-unknown-2b"
        let retryReqId = "550e8400-e29b-41d4-a716-446655440099"
        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "UnifiedUnknown") { request, _ in
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            let path = url.path

            if method == "GET", path == "/v2/dialogue/events" {
                return Self.jsonResponse(url: url, status: 200, json: #"{"items":[],"nextCursor":3}"#)
            }
            if method == "GET", path == "/v2/work-items/work:u-recheck" {
                return Self.jsonResponse(
                    url: url,
                    status: 200,
                    json: """
                    {
                      "workItem": {
                        "id": "work:u-recheck",
                        "agentId": "main",
                        "title": "核对任务",
                        "state": "COMPLETED",
                        "progress": "已确认执行完成",
                        "updatedAtMs": 1793500100000,
                        "conversationId": "\(convId)",
                        "outcomeUnknown": false
                      },
                      "brief": "核对构建",
                      "failure": null,
                      "sessionArchived": false,
                      "resultMarkdown": "核对后确认已完成",
                      "outcomeUnknown": false
                    }
                    """
                )
            }
            if method == "POST", path == "/v2/dialogue/messages" {
                return Self.jsonResponse(
                    url: url,
                    status: 202,
                    json: """
                    {
                      "eventId": "evt-u-retry",
                      "requestId": "\(retryReqId)",
                      "topicId": "topic-u-retry",
                      "workItemIds": ["work:u-retry-new"],
                      "state": "received",
                      "replayed": false,
                      "conversationId": "\(convId)"
                    }
                    """
                )
            }
            return Self.jsonResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
        }
        defer {
            store.stopCloudDialoguePolling()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let pageJSON = """
        {
          "items": [
            {"seq":1,"id":"evt-u-prompt","kind":"user_message","role":"user","text":"重试同步","topicId":"topic-u2","workItemId":"work:u-retry","conversationId":"\(convId)"},
            {"seq":2,"id":"evt-u1","kind":"task_result","role":"assistant","text":"状态未知 1","topicId":"topic-u1","workItemId":"work:u-recheck","conversationId":"\(convId)","outcomeUnknown":true},
            {"seq":3,"id":"evt-u2","kind":"task_result","role":"assistant","text":"状态未知 2","topicId":"topic-u2","workItemId":"work:u-retry","conversationId":"\(convId)","outcomeUnknown":true},
            {"seq":4,"id":"evt-u3","kind":"process_event","role":"system","text":"状态未知 3","topicId":"topic-u3","workItemId":"work:u-abandon","conversationId":"\(convId)","outcomeUnknown":true}
          ],
          "nextCursor": 4,
          "conversationId": "\(convId)"
        }
        """
        store.ingestCloudDialogueEventsPage(
            try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(pageJSON.utf8)),
            requestedAfter: 0
        )

        let initialRuns = store.unifiedMacDelegatedRuns(for: convId)
        #expect(initialRuns.filter(\.isOutcomeUnknown).count == 3)
        #expect(initialRuns.allSatisfy { $0.badge == .outcomeUnknown })

        // 1. Recheck
        _ = try await store.recheckOutcomeUnknownCloudWorkItem(workItemId: "work:u-recheck").get()
        let rechecked = try #require(store.unifiedMacDelegatedRuns(for: convId).first(where: { $0.workItemId == "work:u-recheck" }))
        #expect(rechecked.isOutcomeUnknown == false)
        #expect(rechecked.badge == .completed)

        // 2. Retry after confirming not executed
        _ = try await store.retryOutcomeUnknownCloudWorkItem(workItemId: "work:u-retry", requestId: retryReqId).get()
        store.stopCloudDialoguePolling()
        let retried = try #require(store.unifiedMacDelegatedRuns(for: convId).first(where: { $0.workItemId == "work:u-retry" }))
        #expect(retried.isOutcomeUnknown == false)

        // 3. Abandon
        #expect(store.abandonOutcomeUnknownCloudWorkItem(workItemId: "work:u-abandon") == true)
        let abandoned = try #require(store.unifiedMacDelegatedRuns(for: convId).first(where: { $0.workItemId == "work:u-abandon" }))
        #expect(abandoned.isOutcomeUnknown == false)
        #expect(abandoned.badge == .cancelled)
    }

    // MARK: - 5. Share Sheet Prefill Routing

    @Test func shareSheetDeepLinkAndAppGroupHandoffStoreRoundTrip() throws {
        let scheme = "amber-test"
        let handoffId = "share-item-42"
        let url = try #require(IOSAppDeepLink.url(for: .shareInbox(handoffID: handoffId), scheme: scheme))
        #expect(url.absoluteString == "amber-test://share/share-item-42")
        #expect(IOSAppDeepLink.parse(url, expectedScheme: scheme) == .shareInbox(handoffID: handoffId))

        // Reject unsafe identifiers and query injections.
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://share/a%2Fb")), expectedScheme: scheme) == nil)
        #expect(IOSAppDeepLink.parse(try #require(URL(string: "amber-test://share/ok?text=inject")), expectedScheme: scheme) == nil)

        // Payload formatting deduplicates URL already inside text and preserves existing draft.
        let payload = AmberSharePayload(
            id: handoffId,
            title: "架构评审纪要",
            text: "请帮我总结这篇文档：https://example.com/spec",
            urlString: "https://example.com/spec"
        )
        let prefill = try #require(payload.formattedPrefillText)
        #expect(prefill == "架构评审纪要\n请帮我总结这篇文档：https://example.com/spec")
        #expect(AmberSharePayload.mergeIntoDraft(existingDraft: "", incoming: prefill) == prefill)
        #expect(
            AmberSharePayload.mergeIntoDraft(existingDraft: "先看这段：", incoming: prefill)
                == "先看这段：\n\n\(prefill)"
        )

        // App Group store save + single-use consume + expiration.
        let suiteName = "Stage2BTests.ShareStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AmberShareHandoffStore(defaults: defaults)
        #expect(store.save(payload) == true)
        let consumed = try #require(store.consume(id: handoffId))
        #expect(consumed.id == handoffId)
        #expect(consumed.formattedPrefillText == prefill)
        // Single-use: second consume returns nil.
        #expect(store.consume(id: handoffId) == nil)

        // Fallback consumeLatestPending works when host openURL wasn't triggered.
        let fallbackPayload = AmberSharePayload(id: "share-fallback-1", urlString: "https://apple.com")
        #expect(store.save(fallbackPayload) == true)
        let latest = try #require(store.consumeLatestPending())
        #expect(latest.id == "share-fallback-1")
        #expect(latest.formattedPrefillText == "https://apple.com")
    }
}
