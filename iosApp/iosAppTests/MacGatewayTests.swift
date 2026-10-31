import Foundation
import Security
import Testing
import UserNotifications
@testable import iosApp

@Suite("Mac Gateway")
struct MacGatewayTests {
    private static let payloadJSON = #"{"v":1,"id":"gw-1","name":"Studio Mac","addrs":["studio.local","192.168.1.20"],"port":47821,"fp":"E1koSGeJkiwpjjeThRw6ApEq2SvdvsQLpfEav0yC6Iw=","s":"secret_-1"}"#

    private static var encodedPayload: String {
        Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func parsesPairingLinkAndBareValue() throws {
        let link = "  amber://gateway/pair?p=\(Self.encodedPayload)\n"
        let payload = try #require(MacGatewayPairingPayload.parse(link))
        #expect(payload.name == "Studio Mac")
        #expect(payload.addrs == ["studio.local", "192.168.1.20"])
        #expect(payload.port == 47821)
        #expect(payload.s == "secret_-1")
        #expect(MacGatewayPairingPayload.parse(Self.encodedPayload) == payload)
    }

    @Test func rejectsMalformedPayloads() {
        #expect(MacGatewayPairingPayload.parse("") == nil)
        #expect(MacGatewayPairingPayload.parse("amber://gateway/pair?p=not-json") == nil)
        let wrongVersion = Data(Self.payloadJSON.replacingOccurrences(of: #""v":1"#, with: #""v":2"#).utf8).base64EncodedString()
        #expect(MacGatewayPairingPayload.parse(wrongVersion) == nil)
        let noAddress = Data(Self.payloadJSON.replacingOccurrences(of: #"["studio.local","192.168.1.20"]"#, with: "[]").utf8).base64EncodedString()
        #expect(MacGatewayPairingPayload.parse(noAddress) == nil)
    }

    /// Expected value from `openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`,
    /// the same computation `amber-gateway` prints next to the QR code.
    @Test func spkiFingerprintMatchesOpenSSL() throws {
        let derBase64 = "MIIBDDCBtAIJAMN/Mwv8flerMAoGCCqGSM49BAMCMA8xDTALBgNVBAMMBHRlc3QwHhcNMjYwOTI3MDgxNTQyWhcNMzYwOTI0MDgxNTQyWjAPMQ0wCwYDVQQDDAR0ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEtTyzbJf2Lqbe6fzit0tZ0xqhGOURe8QYdiII4wJoCeGsc8IoQlZmHNwODZnE794HYpLN7JYkX3LI6cTzsqwewzAKBggqhkjOPQQDAgNHADBEAiA/beSwfzzuB7jNcmn8goG4gV0HW5GxSHluQ81VTdrRqgIgWx8s9aOv82hBH0+QqudgrUnE89gAGA/lm4bsOaFQ9EE="
        let der = try #require(Data(base64Encoded: derBase64))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(MacGatewayPinningDelegate.spkiFingerprint(of: certificate) == "E1koSGeJkiwpjjeThRw6ApEq2SvdvsQLpfEav0yC6Iw=")
    }

    @Test func statusDecodesAmberPendingApproval() throws {
        let json = #"""
        {"gateway":{"id":"g","name":"Mac"},"device":{"id":"d","name":"iPhone","pushRegistered":true},"serverTime":1800000000,
         "sessions":[
          {"key":"amber:r1","agent":"amber","subject":"每日汇总","origin":"headless","state":"waiting","waitReason":"permission","abnormal":false,"monitored":true,"updatedAt":1800000000,
           "pendingApproval":{"toolCallId":"c1","tool":"workspace_file_write","detail":"path a.txt","highRisk":false}},
          {"key":"claude:s","agent":"claude","subject":"p","origin":"interactive","state":"running","abnormal":false,"monitored":true,"updatedAt":1800000000}
         ]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let status = try decoder.decode(MacGatewayStatus.self, from: Data(json.utf8))
        #expect(status.sessions[0].pendingApproval?.toolCallId == "c1")
        #expect(status.sessions[0].pendingApproval?.highRisk == false)
        #expect(status.sessions[1].pendingApproval == nil, "older gateways and agent sessions omit the field")
        #expect(status.sessions[0].isOpen && status.sessions[1].isOpen)
        #expect(status.sessions[1].displayTitle == "p", "no summary falls back to the directory name")
        var named = status.sessions[1]
        named.summary = "在 amber-macos 实现定时任务"
        named.state = "stopped"
        #expect(named.displayTitle == "在 amber-macos 实现定时任务")
        #expect(!named.isOpen, "ended tasks get no push switch")
    }

    /// A phone updated before its Mac must keep the boundary: an unknown risk is not an ordinary call.
    @Test func missingHighRiskDecodesAsHighRiskInStatusAndBoard() throws {
        let statusJSON = #"""
        {"gateway":{"id":"g","name":"Mac"},"device":{"id":"d","name":"iPhone","pushRegistered":true},"serverTime":1800000000,
         "sessions":[{"key":"amber:r1","agent":"amber","subject":"每日汇总","origin":"headless","state":"waiting","waitReason":"permission","abnormal":false,"monitored":true,"updatedAt":1800000000,
                     "pendingApproval":{"toolCallId":"c1","tool":"workspace_file_write"}}]}
        """#
        let boardJSON = #"[{"id":"run:A","kind":"run","column":"needsYou","title":"每日汇总","detail":"等你确认","updatedAt":1800000000,"waitingForReply":false,"failed":false,"approval":{"sessionKey":"amber:r1","toolCallId":"c1","tool":"workspace_file_write"}}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let status = try decoder.decode(MacGatewayStatus.self, from: Data(statusJSON.utf8))
        #expect(status.sessions[0].pendingApproval?.highRisk == true,
                "a missing highRisk must not offer approve on the phone")

        let board = try decoder.decode([MacGatewayBoardItem].self, from: Data(boardJSON.utf8))
        #expect(board[0].approval?.highRisk == true)
    }

    @Test func approvalNotificationActionsMapToDecisions() {
        let info: [AnyHashable: Any] = ["sessionKey": "amber:run-1", "toolCallId": "c1", "deepLink": "amber://tasks"]
        #expect(MacGatewayApprovalNotification.decision(actionIdentifier: MacGatewayApprovalNotification.approveAction, userInfo: info)
                == .init(sessionKey: "amber:run-1", toolCallId: "c1", allow: true))
        #expect(MacGatewayApprovalNotification.decision(actionIdentifier: MacGatewayApprovalNotification.denyAction, userInfo: info)?.allow == false)
        #expect(MacGatewayApprovalNotification.decision(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info) == nil,
                "tapping the banner opens the app instead")
        #expect(MacGatewayApprovalNotification.decision(actionIdentifier: MacGatewayApprovalNotification.approveAction,
                                                        userInfo: ["sessionKey": "claude:s", "toolCallId": "c1"]) == nil)
        #expect(MacGatewayApprovalNotification.decision(actionIdentifier: MacGatewayApprovalNotification.approveAction,
                                                        userInfo: ["sessionKey": "amber:run-1"]) == nil, "high-risk pushes carry no call id")
        let category = MacGatewayApprovalNotification.categories.first
        #expect(category?.identifier == "amber.gateway.approval")
        #expect(category?.actions.first { $0.identifier == MacGatewayApprovalNotification.approveAction }?.options.contains(.authenticationRequired) == true)
    }

    @Test func scheduleDraftSendsOnlyNamePromptAndTime() throws {
        var draft = MacGatewayScheduleDraft()
        #expect(!draft.isComplete)
        draft.name = "周报"; draft.prompt = "写周报"
        draft.rule = .weekly; draft.weekdays = [6, 2]
        draft.time = try #require(Calendar.current.date(bySettingHour: 17, minute: 30, second: 0, of: Date()))
        #expect(draft.isComplete)
        let body = draft.body
        #expect(body["rule"] as? String == "weekly")
        #expect(body["hour"] as? Int == 17 && body["minute"] as? Int == 30)
        #expect(body["weekdays"] as? [Int] == [2, 6])
        #expect(Set(body.keys) == ["name", "prompt", "rule", "hour", "minute", "weekdays"], "no approval fields leave the phone")
        draft.weekdays = []
        #expect(!draft.isComplete)
        draft.rule = .interval
        #expect(draft.body["intervalMinutes"] as? Int == 60 && draft.body["hour"] == nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let list = try decoder.decode([MacGatewaySchedule].self, from: Data(#"[{"id":"s1","name":"清理","rule":"每天 03:00","enabled":true,"running":false,"autoApprovesHighRisk":true}]"#.utf8))
        #expect(list.first?.autoApprovesHighRisk == true && list.first?.nextRunAt == nil)
    }

    @Test func tasksDeepLinkRoundTripsAndLegacyPushLinkLandsOnBoard() throws {
        let url = try #require(URL(string: "amber://tasks"))
        #expect(IOSAppDeepLink.parse(url) == .macTasks)
        #expect(IOSAppDeepLink.url(for: .macTasks) == url)
        // Gateway pushes still carry the Settings link; it opens the board now.
        let legacy = try #require(URL(string: "amber://settings/mac-gateway"))
        #expect(IOSAppDeepLink.parse(legacy) == .macTasks)
        for text in ["amber://tasks/x", "amber://tasks?x=1"] {
            let other = try #require(URL(string: text))
            #expect(IOSAppDeepLink.parse(other) == nil, "\(text)")
        }
    }

    private static let boardJSON = #"""
    {"status":200,"board":[
     {"id":"run:A","kind":"run","column":"needsYou","title":"每日汇总","detail":"等你确认 · workspace_file_write","updatedAt":1800000000,"scheduleId":"A","conversationId":"C","waitingForReply":false,"failed":false,
      "approval":{"sessionKey":"amber:r1","toolCallId":"c1","tool":"workspace_file_write","detail":"path a.txt","highRisk":false}},
     {"id":"session:claude:s1","kind":"agentSession","column":"running","title":"重构看板","detail":"Claude Code · 运行中","updatedAt":1800000100,"waitingForReply":false,"failed":false},
     {"id":"schedule:B","kind":"schedule","column":"scheduled","title":"清理","detail":"每天 03:00","updatedAt":1800003600,"scheduleId":"B","nextRunAt":1800003600,"waitingForReply":false,"failed":false},
     {"id":"done:R","kind":"run","column":"done","title":"清理","detail":"删了 3 个文件","updatedAt":1799990000,"scheduleId":"B","waitingForReply":false,"failed":true}
    ]}
    """#

    private static func decodeBoard() throws -> [MacGatewayBoardItem] {
        struct Response: Decodable { var board: [MacGatewayBoardItem] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Response.self, from: Data(boardJSON.utf8)).board
    }

    @Test func boardDecodesGatewayItems() throws {
        let board = try Self.decodeBoard()
        #expect(board.map(\.column) == [.needsYou, .running, .scheduled, .done])
        #expect(board[0].approval?.sessionKey == "amber:r1" && board[0].approval?.highRisk == false)
        #expect(board[1].sessionKey == "claude:s1" && board[0].sessionKey == nil)
        #expect(board[2].nextRunAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(board[3].failed && board[3].approval == nil)
    }

    @Test func boardLayoutKeepsMacOrderSkipsEmptyGroupsAndAddsDisabledSchedules() throws {
        let board = try Self.decodeBoard()
        let schedule = MacGatewaySchedule(id: "B", name: "清理", rule: "每天 03:00", enabled: true, running: false,
                                          autoApprovesHighRisk: false)
        var off = schedule
        off.id = "D"; off.name = "周报"; off.enabled = false
        let groups = MacTasksBoardLayout.groups(items: board, schedules: [schedule, off])
        #expect(groups.map(\.column) == [.needsYou, .running, .scheduled, .done])
        #expect(groups[2].rows.map(\.id) == ["schedule:B", "schedule-off:D"])
        #expect(groups[2].rows.allSatisfy { $0.showsScheduleControls })
        #expect(!groups[0].rows[0].showsScheduleControls, "runs get no run-now/enable controls")
        #expect(groups[3].rows[0].icon == "exclamationmark.triangle")

        // Just switched on, before the board lists it: shown once, not dropped.
        var justOn = off
        justOn.enabled = true
        let pending = MacTasksBoardLayout.groups(items: board, schedules: [schedule, justOn])
        #expect(pending[2].rows.map(\.id) == ["schedule:B", "schedule-off:D"])
        // Just switched off while the board still lists it: not duplicated.
        var justOff = schedule
        justOff.enabled = false
        #expect(MacTasksBoardLayout.groups(items: board, schedules: [justOff])[2].rows.map(\.id) == ["schedule:B"])

        let onlyRunning = MacTasksBoardLayout.groups(items: board.filter { $0.column == .running }, schedules: nil)
        #expect(onlyRunning.map(\.column) == [.running], "empty groups are not shown")
    }

    @Test @MainActor func fallbackBoardGroupsGatewaySessionsWithoutAmber() throws {
        let json = #"""
        {"gateway":{"id":"g","name":"Mac"},"device":{"id":"d","name":"iPhone","pushRegistered":true},"serverTime":1800000000,
         "sessions":[
          {"key":"amber:r1","agent":"amber","subject":"每日汇总","origin":"headless","state":"waiting","abnormal":false,"monitored":true,"updatedAt":1800000000},
          {"key":"amber:r2","agent":"amber","subject":"清理","origin":"headless","state":"waiting","waitReason":"permission","abnormal":false,"monitored":true,"updatedAt":1799999000,
           "pendingApproval":{"toolCallId":"c9","tool":"shell_run","highRisk":true}},
          {"key":"codex:a","agent":"codex","subject":"p","summary":"修 bug","origin":"interactive","state":"stopped","abnormal":true,"monitored":true,"updatedAt":1800000000},
          {"key":"claude:b","agent":"claude","subject":"q","origin":"interactive","state":"waiting","waitReason":"input","abnormal":false,"monitored":true,"updatedAt":1800000050},
          {"key":"claude:c","agent":"claude","subject":"r","summary":"跑测试","origin":"interactive","state":"stalled","abnormal":false,"monitored":true,"updatedAt":1800000010},
          {"key":"claude:e","agent":"claude","subject":"arquiel","origin":"host","host":"Synara","state":"stopped","abnormal":false,"monitored":true,"updatedAt":1800000060}
         ]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let status = try decoder.decode(MacGatewayStatus.self, from: Data(json.utf8))
        let board = MacGatewayStore.fallbackBoard(sessions: status.sessions)
        #expect(board.map(\.id) == ["session:claude:b", "run:amber:r2", "session:claude:c", "session:codex:a"],
                "Amber runs appear only while a tool call waits on the phone")
        #expect(board.map(\.column) == [.needsYou, .needsYou, .running, .done])
        #expect(board[0].waitingForReply && board[0].detail.hasPrefix("Claude Code"))
        #expect(board[1].approval == .init(sessionKey: "amber:r2", toolCallId: "c9", tool: "shell_run", detail: nil, highRisk: true))
        #expect(board[3].title == "修 bug" && board[3].failed)
        #expect(!board.contains { $0.id == "session:claude:e" }, "a session with no prompt is dropped unless it waits on you")
        #expect(board.filter { $0.kind == .agentSession }.map(MacTasksBoardLayout.icon) == ["text.bubble", "terminal", "terminal"],
                "same session icons as the Mac's board")
    }

    @Test func gatewayPairDeepLinkRoundTrips() throws {
        let url = try #require(URL(string: "amber-test://gateway/pair?p=\(Self.encodedPayload)"))
        let destination = try #require(IOSAppDeepLink.parse(url, expectedScheme: "amber-test"))
        #expect(destination == .gatewayPair(payload: Self.encodedPayload))
        let rebuilt = try #require(IOSAppDeepLink.url(for: destination, scheme: "amber-test"))
        #expect(IOSAppDeepLink.parse(rebuilt, expectedScheme: "amber-test") == destination)
    }

    @Test func gatewayPairDeepLinkRejectsExtraOrUnsafeQuery() throws {
        for text in [
            "amber-test://gateway/pair",
            "amber-test://gateway/pair?p=abc&x=1",
            "amber-test://gateway/pair?q=abc",
            "amber-test://gateway/pair?p=a%2Fb",
            "amber-test://gateway/other?p=abc",
        ] {
            #expect(IOSAppDeepLink.parse(try #require(URL(string: text)), expectedScheme: "amber-test") == nil, "\(text)")
        }
    }

    @Test @MainActor func c3AndC5ApprovalContractBlocksHighRiskApproveAndDefaultsMissingHighRiskToTrue() async throws {
        // C5: missing `highRisk` field in JSON defaults to `true` (fail-closed)
        let missingHighRiskJSON = #"{"sessionKey":"amber:r1","toolCallId":"c1","tool":"shell_run"}"#
        let decoded = try JSONDecoder().decode(MacGatewayBoardItem.Approval.self, from: Data(missingHighRiskJSON.utf8))
        #expect(decoded.highRisk == true)

        // C5: push notification decision blocks `approveAction` if `highRisk == true` in userInfo, while still allowing `denyAction`
        let riskyPushInfo: [AnyHashable: Any] = [
            "sessionKey": "amber:r1",
            "toolCallId": "c1",
            "highRisk": true
        ]
        #expect(MacGatewayApprovalNotification.decision(
            actionIdentifier: MacGatewayApprovalNotification.approveAction,
            userInfo: riskyPushInfo
        ) == nil)
        #expect(MacGatewayApprovalNotification.decision(
            actionIdentifier: MacGatewayApprovalNotification.denyAction,
            userInfo: riskyPushInfo
        )?.allow == false)
    }

    @Test @MainActor func staleApprovalClaimNeverAffectsNewRunOrMismatchedRequestId() async {
        let session = ChatRunApprovalSession()
        let prompt = ChatToolApprovalPrompt.ish(
            IshHandoffToolApprovalRequest(
                id: "req-run-1",
                mode: .embeddedExecute,
                commandPreview: "ls -la",
                filename: "cmd.sh",
                reason: "终端命令需要确认",
                runId: "run-1"
            )
        )
        let waitTask = Task { @MainActor in
            await session.wait(for: prompt)
        }
        await Task.yield()
        #expect(session.hasPendingApproval)

        // Stale requestId or mismatched runId must not claim the active waiter
        #expect(session.claim(category: .ish, requestId: "req-stale", runId: "run-1") == nil)
        #expect(session.claim(category: .ish, requestId: "req-run-1", runId: "run-2") == nil)
        #expect(session.hasPendingApproval)

        // Matching runId and requestId claims and resolves cleanly
        let claimed = session.claim(category: .ish, requestId: "req-run-1", runId: "run-1")
        #expect(claimed != nil)
        claimed?.waiter.resume(returning: .deny)
        let decision = await waitTask.value
        if case .deny = decision {
            // expected
        } else {
            Issue.record("Expected .deny, got \(String(describing: decision))")
        }
        #expect(!session.hasPendingApproval)
    }
}
