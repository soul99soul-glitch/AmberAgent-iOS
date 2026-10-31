import Foundation
import Testing
@testable import GatewayCore
@testable import GatewayPush

/// Scheduled runs reported by the Amber Mac app (`AgentKind.amber`).
@Suite("Amber scheduled runs")
struct AmberSessionTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let config = GatewayConfig()
    let away = { Presence(screenLocked: true, idleSeconds: 999) }
    let here = { Presence(screenLocked: false, idleSeconds: 0) }

    func event(_ kind: EventKind, _ at: Double, call: String? = nil, tool: String? = nil, highRisk: Bool? = nil, exit: Int32? = nil) -> GatewayEvent {
        var e = GatewayEvent(agent: .amber, kind: kind, sessionId: "run-1", timestamp: t0.addingTimeInterval(at),
                             process: ProcessIdentity(pid: 4242, startSec: 1, startUsec: 0), origin: .headless,
                             title: "每日汇总", exitCode: exit, tool: tool)
        e.toolCallId = call
        e.detail = call.map { "参数 \($0)" }
        e.highRisk = highRisk
        return e
    }

    func pushes(_ effects: [RegistryEffect]) -> [PushIntent] {
        effects.compactMap { if case .push(let p) = $0 { p } else { nil } }
    }

    @Test func approvalWaitPushesWhenAwayDespiteHeadlessOriginAndCarriesTheCall() {
        var r = Registry()
        #expect(pushes(r.ingest(event(.runStart, 0), config: config, now: t0, presence: away)).isEmpty)
        let p = pushes(r.ingest(event(.permissionRequest, 1, call: "c1", tool: "workspace_file_write", highRisk: false),
                                config: config, now: t0, presence: away))
        #expect(p.count == 1)
        #expect(p.first?.state == .waiting && p.first?.waitReason == .permission)
        #expect(p.first?.toolCallId == "c1" && p.first?.highRisk == false)
        let rec = r.sessions["amber:run-1"]!
        #expect(rec.waitingToolCallId == "c1" && rec.waitingDetail == "参数 c1")
    }

    @Test func approvalWhileAtTheMacIsHeldBackAndSentOnLeaving() {
        var r = Registry()
        _ = r.ingest(event(.runStart, 0), config: config, now: t0, presence: here)
        #expect(pushes(r.ingest(event(.permissionRequest, 1, call: "c1", tool: "t", highRisk: false), config: config, now: t0, presence: here)).isEmpty)
        #expect(r.hasPendingPushes)
        let later = pushes(r.tick(config: config, now: t0.addingTimeInterval(60), presence: away()))
        #expect(later.count == 1 && later.first?.toolCallId == "c1")
    }

    @Test func onlyTheAnsweredCallResumesAndASecondCallPushesAgain() {
        var r = Registry()
        _ = r.ingest(event(.runStart, 0), config: config, now: t0, presence: away)
        _ = r.ingest(event(.permissionRequest, 1, call: "c1", tool: "t", highRisk: false), config: config, now: t0, presence: away)
        _ = r.ingest(event(.toolDone, 2, call: "other", tool: "t"), config: config, now: t0, presence: away)
        #expect(r.sessions["amber:run-1"]?.state == .waiting, "same tool name, different call")
        _ = r.ingest(event(.toolDone, 3, call: "c1", tool: "t"), config: config, now: t0, presence: away)
        #expect(r.sessions["amber:run-1"]?.state == .running)
        #expect(r.sessions["amber:run-1"]?.waitingToolCallId == nil)
        let second = pushes(r.ingest(event(.permissionRequest, 4, call: "c2", tool: "t", highRisk: true), config: config, now: t0, presence: away))
        #expect(second.first?.toolCallId == "c2")
    }

    @Test func outcomesAndNoStallDetection() {
        var r = Registry()
        _ = r.ingest(event(.runStart, 0), config: config, now: t0, presence: away)
        let stall = r.heartbeat(HealthSnapshot(sampledAt: t0, diskFreeBytes: nil, batteryPercent: nil, onBattery: nil, memoryPressure: .normal, thermal: .nominal),
                                config: config, now: t0.addingTimeInterval(3 * 3600))
        #expect(pushes(stall).isEmpty, "an Amber run's end is always reported, so silence is not a stall")
        let done = pushes(r.ingest(event(.runExit, 10, exit: 0), config: config, now: t0, presence: away))
        #expect(done.first?.state == .completed)
        var failed = Registry()
        _ = failed.ingest(event(.runStart, 0), config: config, now: t0, presence: away)
        let p = pushes(failed.ingest(event(.runExit, 5, exit: 1), config: config, now: t0, presence: away))
        #expect(p.first?.state == .stopped && p.first?.abnormal == true)
        #expect(PushContent.render(p.first!, gatewayName: "Mac").body == "未完成")
        #expect(PushContent.render(p.first!, gatewayName: "Mac").title == "Amber 定时任务 · 每日汇总")
    }

    @Test func quietCompletionIsRecordedWithoutPushButFailuresStillPush() {
        func finish(exit: Int32, quiet: Bool?) -> (Registry, [PushIntent]) {
            var r = Registry()
            _ = r.ingest(event(.runStart, 0), config: config, now: t0, presence: away)
            var e = event(.runExit, 10, exit: exit)
            e.quiet = quiet
            let p = pushes(r.ingest(e, config: config, now: t0, presence: away))
            return (r, p)
        }
        let (quiet, quietPushes) = finish(exit: 0, quiet: true)
        #expect(quiet.sessions["amber:run-1"]?.state == .completed)
        #expect(quietPushes.isEmpty, "nothing new: the board shows it, the phone isn't buzzed")
        #expect(finish(exit: 0, quiet: false).1.first?.state == .completed)
        #expect(finish(exit: 0, quiet: nil).1.first?.state == .completed, "not judged: push as before")
        let failed = finish(exit: 1, quiet: true).1
        #expect(failed.first?.state == .stopped && failed.first?.abnormal == true, "failures always push")
    }

    @Test func apnsPayloadOffersActionsOnlyForOrdinaryApprovals() {
        let ordinary = PushIntent(kind: .task, sessionKey: "amber:run-1", agent: .amber, subject: "每日汇总", state: .waiting,
                                  waitReason: .permission, toolCallId: "c1", highRisk: false, level: .timeSensitive, createdAt: t0)
        let payload = APNsSender.payload(PushMessage(ordinary, gatewayName: "Mac"))
        #expect((payload["aps"] as? [String: Any])?["category"] as? String == PushMessage.amberApprovalCategory)
        #expect(payload["toolCallId"] as? String == "c1")
        #expect(payload["sessionKey"] as? String == "amber:run-1")
        #expect(payload["deepLink"] as? String == PushMessage.amberDeepLink)

        var risky = ordinary
        risky.highRisk = true
        let riskyPayload = APNsSender.payload(PushMessage(risky, gatewayName: "Mac"))
        #expect((riskyPayload["aps"] as? [String: Any])?["category"] == nil)
        #expect(riskyPayload["toolCallId"] == nil)
        #expect(PushContent.render(risky, gatewayName: "Mac").body.contains("高风险"))

        var unknown = ordinary
        unknown.highRisk = nil
        let unknownPayload = APNsSender.payload(PushMessage(unknown, gatewayName: "Mac"))
        #expect((unknownPayload["aps"] as? [String: Any])?["category"] == nil, "unknown risk is not ordinary")
        #expect(unknownPayload["toolCallId"] == nil)
        #expect(PushContent.render(unknown, gatewayName: "Mac").body.contains("高风险"),
                "an unactionable banner must not read like an ordinary approval")
        #expect(!PushContent.render(ordinary, gatewayName: "Mac").body.contains("高风险"),
                "ordinary approvals stay ordinary")
        var noCall = ordinary
        noCall.toolCallId = nil
        #expect(!PushContent.render(noCall, gatewayName: "Mac").body.contains("高风险"),
                "a turn-end wait has no tool call to approve")

        let claude = PushIntent(kind: .task, sessionKey: "claude:s", agent: .claude, subject: "p", state: .waiting, createdAt: t0)
        let plain = APNsSender.payload(PushMessage(claude, gatewayName: "Mac"))
        #expect(plain.keys.sorted() == ["aps"], "agent pushes are unchanged")
    }
}
