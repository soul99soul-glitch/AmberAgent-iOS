import BackgroundTasks
import UIKit
import XCTest
@testable import iosApp

/// 机制层的红绿门禁。短窗与两条可选长腿都靠闭包注入替身验证，不需要真机——
/// 唯一测不到的是 `adopt`（`BGContinuedProcessingTask` 无法构造），
/// 那一段只能靠设备验证。音频腿在测试里用 spy，不真正开 AVAudioSession。
@MainActor
final class BackgroundGenerationKeepAliveTests: XCTestCase {
    /// 记录机制层对系统的每一次调用，并留出手动触发到期的入口。
    @MainActor
    private final class SystemSpy {
        var begunNames: [String] = []
        var endedTaskIds: [UIBackgroundTaskIdentifier] = []
        var submittedRequests: [BGContinuedProcessingTaskRequest] = []
        var cancelledIdentifiers: [String] = []
        var registeredIdentifiers: [String] = []
        var events: [String] = []
        /// 按 begin 顺序保存的到期回调，测试用它模拟 30 秒到点。
        var expirationHandlers: [() -> Void] = []

        var nextTaskId: Int = 1
        var registrationResult = true
        var submitError: Error?
        /// Fail the first N submit attempts, then succeed.
        var remainingSubmitFailures: Int = 0
        let audio = AudioSpy()

        func makeKeepAlive(
            systemSubmitRetryDelayNanoseconds: UInt64 = 1_500_000_000,
            isApplicationForeground: @escaping () -> Bool = { true },
            isAudioKeepAliveEnabled: @escaping () -> Bool = { false }
        ) -> BackgroundGenerationKeepAlive {
            BackgroundGenerationKeepAlive(
                beginBackgroundTask: { [self] name, expiration in
                    begunNames.append(name)
                    events.append("begin")
                    expirationHandlers.append(expiration)
                    let identifier = UIBackgroundTaskIdentifier(rawValue: nextTaskId)
                    nextTaskId += 1
                    return identifier
                },
                endBackgroundTask: { [self] identifier in
                    endedTaskIds.append(identifier)
                    events.append("end")
                },
                submitTaskRequest: { [self] request in
                    if remainingSubmitFailures > 0 {
                        remainingSubmitFailures -= 1
                        events.append("submit-fail")
                        throw SubmitFailure()
                    }
                    if let submitError {
                        events.append("submit-fail")
                        throw submitError
                    }
                    events.append("submit")
                    submittedRequests.append(request)
                },
                cancelTaskRequest: { [self] identifier in
                    cancelledIdentifiers.append(identifier)
                },
                registerLaunchHandler: { [self] identifier, _ in
                    registeredIdentifiers.append(identifier)
                    return registrationResult
                },
                systemSubmitRetryDelayNanoseconds: systemSubmitRetryDelayNanoseconds,
                isApplicationForeground: isApplicationForeground,
                audioKeepAlive: audio,
                isAudioKeepAliveEnabled: isAudioKeepAliveEnabled
            )
        }
    }

    @MainActor
    private final class AudioSpy: BackgroundAudioKeepAliveControlling {
        var isActive = false
        var startSucceeds = true
        var startCount = 0
        var stopCount = 0

        func start() {
            startCount += 1
            isActive = startSucceeds
        }

        func stop() {
            stopCount += 1
            isActive = false
        }
    }

    private struct SubmitFailure: Error {}

    // MARK: - begin

    func testBeginTakesUITaskAndSubmitsQueuedRequest() throws {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "Amber 正在生成", subtitle: "GPT")

        XCTAssertEqual(spy.begunNames, ["AmberGeneration-run-1"])
        let request = try XCTUnwrap(spy.submittedRequests.first)
        XCTAssertEqual(spy.submittedRequests.count, 1)
        XCTAssertEqual(request.identifier, keepAlive.identifier(for: "run-1"))
        XCTAssertEqual(spy.registeredIdentifiers, [request.identifier])
        XCTAssertEqual(request.title, "Amber 正在生成")
        XCTAssertEqual(request.subtitle, "GPT")
        // 系统暂时没有资源时要继续排队，不能把尚未接管当成业务失败。
        XCTAssertEqual(request.strategy, .queue)
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .submitted)
    }

    func testBeginWhileBackgroundedKeepsOnlyUIKitLease() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive(isApplicationForeground: { false })

        keepAlive.begin("run-1", title: "t", subtitle: "s")

        XCTAssertEqual(spy.begunNames, ["AmberGeneration-run-1"])
        XCTAssertTrue(spy.registeredIdentifiers.isEmpty)
        XCTAssertTrue(spy.submittedRequests.isEmpty)
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .uiOnly)
    }

    func testBeginCanSkipSystemTaskWhileKeepingUIKitLease() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin(
            "novel-run",
            title: "Amber 小说创作中",
            subtitle: "后台生成",
            submitSystemTask: false
        )

        XCTAssertEqual(spy.begunNames, ["AmberGeneration-novel-run"])
        XCTAssertTrue(spy.registeredIdentifiers.isEmpty)
        XCTAssertTrue(spy.submittedRequests.isEmpty)
        XCTAssertTrue(keepAlive.holdsLease("novel-run"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "novel-run"), .uiOnly)
    }

    func testInvalidUIKitTaskWithoutSystemSubmissionOwnsNoExecution() {
        let keepAlive = BackgroundGenerationKeepAlive(
            beginBackgroundTask: { _, _ in .invalid },
            endBackgroundTask: { _ in },
            submitTaskRequest: { _ in },
            cancelTaskRequest: { _ in },
            registerLaunchHandler: { _, _ in true },
            audioKeepAlive: NoOpBackgroundAudioKeepAlive(),
            isAudioKeepAliveEnabled: { false }
        )

        keepAlive.begin("run-invalid", title: "t", subtitle: "s", submitSystemTask: false)

        XCTAssertTrue(keepAlive.holdsLease("run-invalid"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-invalid"), .none)
    }

    func testPromoteSystemTaskSubmitsAfterDeferredBegin() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin(
            "novel-run",
            title: "Amber 小说创作中",
            subtitle: "准备生成",
            submitSystemTask: false
        )
        XCTAssertTrue(spy.submittedRequests.isEmpty)

        keepAlive.promoteSystemTaskIfNeeded("novel-run", subtitle: "正在生成正文")

        XCTAssertEqual(spy.submittedRequests.count, 1)
        XCTAssertEqual(spy.submittedRequests.first?.subtitle, "正在生成正文")
        XCTAssertTrue(keepAlive.holdsLease("novel-run"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "novel-run"), .submitted)

        // Idempotent: do not queue a second system request for the same lease.
        keepAlive.promoteSystemTaskIfNeeded("novel-run", subtitle: "再次 promote")
        XCTAssertEqual(spy.submittedRequests.count, 1)
    }

    func testIdentifierStaysInsidePermittedNamespace() {
        let keepAlive = SystemSpy().makeKeepAlive()

        // Info.plist 只放行 `<bundle>.keepalive.*`，越界会被 register 拒掉。
        let identifier = keepAlive.identifier(for: "run/1 :: 议会")

        // 硬编码期望值，不要拿实现里那套谓词再算一遍——那样断言恒真，
        // 测的是标准库不是这段代码。CJK 也必须被换掉：`isLetter` 对它是 true。
        XCTAssertEqual(
            identifier,
            "\(Bundle.main.bundleIdentifier ?? "app.amber.ios").keepalive.run-1------"
        )
    }

    func testBeginIsIdempotentForSameLease() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        keepAlive.begin("run-1", title: "t", subtitle: "s")

        XCTAssertEqual(spy.begunNames.count, 1)
        XCTAssertEqual(spy.submittedRequests.count, 1)
    }

    func testSubmitFailureSchedulesOneRetryThenSucceeds() async {
        let spy = SystemSpy()
        spy.remainingSubmitFailures = 1
        let keepAlive = spy.makeKeepAlive(systemSubmitRetryDelayNanoseconds: 20_000_000)

        keepAlive.begin("run-1", title: "Amber 正在生成", subtitle: "GPT")
        XCTAssertEqual(spy.events, ["begin", "submit-fail"])
        XCTAssertTrue(spy.submittedRequests.isEmpty)
        XCTAssertTrue(keepAlive.holdsLease("run-1"))

        // Allow the deferred resubmit to run.
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(spy.events, ["begin", "submit-fail", "submit"])
        XCTAssertEqual(spy.submittedRequests.count, 1)
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
    }

    func testSubmitFailureRetryDoesNotLoopForever() async {
        let spy = SystemSpy()
        // Always fail: first submit + exactly one scheduled retry.
        spy.submitError = SubmitFailure()
        let keepAlive = spy.makeKeepAlive(systemSubmitRetryDelayNanoseconds: 20_000_000)

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(keepAlive.holdsLease("run-1"))
        XCTAssertTrue(spy.submittedRequests.isEmpty)
        XCTAssertEqual(spy.begunNames.count, 1)
        XCTAssertEqual(spy.events.filter { $0 == "submit-fail" }.count, 2)
    }

    func testSubmitFailureDoesNotRetryAfterAppMovesToBackground() async {
        let spy = SystemSpy()
        spy.remainingSubmitFailures = 1
        var isForeground = true
        let keepAlive = spy.makeKeepAlive(
            systemSubmitRetryDelayNanoseconds: 20_000_000,
            isApplicationForeground: { isForeground }
        )

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        isForeground = false
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(spy.events, ["begin", "submit-fail"])
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .uiOnly)
    }

    func testAbandonSystemAssertionCancelsPendingRetryWithoutDroppingUIKitLease() async {
        let spy = SystemSpy()
        spy.remainingSubmitFailures = 1
        let keepAlive = spy.makeKeepAlive(systemSubmitRetryDelayNanoseconds: 50_000_000)

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        XCTAssertEqual(spy.events, ["begin", "submit-fail"])

        keepAlive.abandonSystemAssertion("run-1")
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .uiOnly)
        XCTAssertEqual(spy.cancelledIdentifiers, [keepAlive.identifier(for: "run-1")])

        try? await Task.sleep(nanoseconds: 120_000_000)
        // No second submit after abandon.
        XCTAssertEqual(spy.events.filter { $0 == "submit" }.count, 0)
        XCTAssertEqual(spy.events.filter { $0 == "submit-fail" }.count, 1)
    }

    func testTransferReleasesGenericLeaseBeforeStartingDedicatedRequest() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()
        keepAlive.begin("run-1", title: "t", subtitle: "s")

        let didStart = keepAlive.transfer("run-1") {
            spy.events.append("dedicated-submit")
            return true
        }

        XCTAssertTrue(didStart)
        XCTAssertFalse(keepAlive.holdsLease("run-1"))
        XCTAssertFalse(keepAlive.holdsLease(keepAlive.handoffBridgeLeaseId(for: "run-1")))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .none)
        XCTAssertEqual(
            spy.events,
            ["begin", "submit", "begin", "end", "dedicated-submit", "end"]
        )
    }

    func testTransferRestoresGenericLeaseWhenDedicatedRequestFails() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()
        keepAlive.begin("run-1", title: "t", subtitle: "s")

        let didStart = keepAlive.transfer("run-1") {
            spy.events.append("dedicated-submit")
            return false
        }

        XCTAssertFalse(didStart)
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
        XCTAssertFalse(keepAlive.holdsLease(keepAlive.handoffBridgeLeaseId(for: "run-1")))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .submitted)
        XCTAssertEqual(
            spy.events,
            ["begin", "submit", "begin", "end", "dedicated-submit", "begin", "submit", "end"]
        )
    }

    func testTransferKeepsAudioAliveUntilDedicatedLeaseBegins() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { true })
        keepAlive.begin("run-1", title: "t", subtitle: "s")
        XCTAssertTrue(spy.audio.isActive)

        var audioDuringStart = false
        let dedicatedId = "chat-bg-run-1"
        let didStart = keepAlive.transfer("run-1") {
            audioDuringStart = spy.audio.isActive
            keepAlive.begin(
                dedicatedId,
                title: "t",
                subtitle: "s",
                submitSystemTask: false
            )
            spy.events.append("dedicated-submit")
            return true
        }

        XCTAssertTrue(didStart)
        XCTAssertTrue(audioDuringStart)
        XCTAssertTrue(spy.audio.isActive)
        XCTAssertFalse(keepAlive.holdsLease("run-1"))
        XCTAssertFalse(keepAlive.holdsLease(keepAlive.handoffBridgeLeaseId(for: "run-1")))
        XCTAssertTrue(keepAlive.holdsLease(dedicatedId))
        XCTAssertEqual(keepAlive.executionAssertion(for: dedicatedId), .uiOnly)
    }

    func testConcurrentLeasesAreTrackedIndependently() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        keepAlive.begin("run-2", title: "t", subtitle: "s")
        XCTAssertEqual(keepAlive.activeLeaseIds, ["run-1", "run-2"])

        keepAlive.end("run-1")
        XCTAssertEqual(keepAlive.activeLeaseIds, ["run-2"])
        XCTAssertFalse(keepAlive.holdsLease("run-1"))
        XCTAssertTrue(keepAlive.holdsLease("run-2"))
    }

    // MARK: - end

    func testEndReleasesUITaskAndDropsLease() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        keepAlive.end("run-1")

        XCTAssertEqual(spy.endedTaskIds.count, 1)
        XCTAssertFalse(keepAlive.holdsLease("run-1"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .none)
    }

    func testEndCancelsTheSubmittedRequest() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        XCTAssertTrue(spy.cancelledIdentifiers.isEmpty)
        keepAlive.end("run-1")

        // 已提交但尚未接管的请求也要撤；否则系统可能在业务早已结束后才调度到。
        XCTAssertEqual(spy.cancelledIdentifiers, [keepAlive.identifier(for: "run-1")])
    }

    func testUITaskExpirationKeepsQueuedRequestForSystemAdoption() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()
        var expired = 0

        keepAlive.begin("run-1", title: "t", subtitle: "s") { expired += 1 }
        spy.expirationHandlers.first?()

        XCTAssertTrue(spy.cancelledIdentifiers.isEmpty)
        XCTAssertEqual(expired, 0)
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .submitted)
        XCTAssertEqual(spy.endedTaskIds.count, 1)
    }

    func testEndIsIdempotent() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        keepAlive.end("run-1")
        keepAlive.end("run-1")
        keepAlive.end("never-started")

        XCTAssertEqual(spy.endedTaskIds.count, 1)
    }

    func testEndDoesNotFireOnExpire() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()
        var expired = 0

        keepAlive.begin("run-1", title: "t", subtitle: "s") { expired += 1 }
        keepAlive.end("run-1")

        // 正常跑完不是失去执行权，触发交接就会白白重跑一遍。
        XCTAssertEqual(expired, 0)
    }

    // MARK: - 短腿到期

    func testUITaskExpirationBeforeAdoptionDropsLeaseAndNotifiesOwner() {
        let spy = SystemSpy()
        spy.submitError = SubmitFailure()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { false })
        var expired = 0
        var heldInsideCallback: Bool?

        keepAlive.begin("run-1", title: "t", subtitle: "s") {
            expired += 1
            heldInsideCallback = keepAlive.holdsLease("run-1")
        }
        spy.expirationHandlers.first?()

        XCTAssertEqual(expired, 1)
        XCTAssertFalse(keepAlive.holdsLease("run-1"))
        // 回调里必须已经读不到租约，否则上层的交接会被自己短路掉，两边都不干活。
        XCTAssertEqual(heldInsideCallback, false)
        XCTAssertEqual(spy.endedTaskIds.count, 1)
    }

    func testUITaskExpirationAfterEndIsInert() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()
        var expired = 0

        keepAlive.begin("run-1", title: "t", subtitle: "s") { expired += 1 }
        keepAlive.end("run-1")
        spy.expirationHandlers.first?()

        XCTAssertEqual(expired, 0)
        XCTAssertEqual(spy.endedTaskIds.count, 1)
    }

    // MARK: - 降级路径

    func testSubmitFailureKeepsLeaseSoUITaskStillCovers() {
        let spy = SystemSpy()
        spy.submitError = SubmitFailure()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")

        // BG 任务提交失败只是退化成 30 秒，不该连短腿一起丢掉。
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .uiOnly)
        XCTAssertEqual(spy.begunNames.count, 1)
        XCTAssertTrue(spy.endedTaskIds.isEmpty)
    }

    func testRegistrationRefusalStillKeepsLease() {
        let spy = SystemSpy()
        spy.registrationResult = false
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")

        // Continued Processing 的通配符只负责 Info.plist 放行；运行时注册必须
        // 使用本轮具体 identifier。注册失败后若仍 submit，真机会抛 Objective-C
        // exception，Swift do/catch 接不住并直接 SIGABRT。
        XCTAssertEqual(spy.registeredIdentifiers, [keepAlive.identifier(for: "run-1")])
        XCTAssertTrue(spy.submittedRequests.isEmpty)
        // 注册被拒只丢长窗口，短腿还在，不能连租约一起丢。
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .uiOnly)
        XCTAssertEqual(spy.begunNames.count, 1)
    }

    func testEachConcreteIdentifierRegistersBeforeSubmission() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        keepAlive.end("run-1")
        keepAlive.begin("run-2", title: "t", subtitle: "s")

        let expectedIdentifiers = [
            keepAlive.identifier(for: "run-1"),
            keepAlive.identifier(for: "run-2")
        ]
        XCTAssertEqual(spy.registeredIdentifiers, expectedIdentifiers)
        XCTAssertEqual(spy.submittedRequests.map { $0.identifier }, expectedIdentifiers)
    }

    func testReusingLeaseIdentifierDoesNotRegisterHandlerTwice() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive()

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        keepAlive.end("run-1")
        keepAlive.begin("run-1", title: "t", subtitle: "s")

        XCTAssertEqual(spy.registeredIdentifiers, [keepAlive.identifier(for: "run-1")])
        XCTAssertEqual(spy.submittedRequests.count, 2)
    }

    // MARK: - 诊断

    func testSnapshotDetailReportsLeaseCounts() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { true })

        XCTAssertEqual(keepAlive.snapshotDetail, "keepAlive=0 adopted=0 audio=0")
        keepAlive.begin("run-1", title: "t", subtitle: "s")
        XCTAssertEqual(keepAlive.snapshotDetail, "keepAlive=1 adopted=0 audio=1")
        keepAlive.end("run-1")
        XCTAssertEqual(keepAlive.snapshotDetail, "keepAlive=0 adopted=0 audio=0")
    }

    // MARK: - 音频腿

    func testBeginStartsAudioAndEndStopsIt() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { true })

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        XCTAssertTrue(spy.audio.isActive)
        XCTAssertEqual(spy.audio.startCount, 1)
        XCTAssertTrue(spy.submittedRequests.isEmpty)
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .uiOnly)

        keepAlive.promoteSystemTaskIfNeeded("run-1", subtitle: "有可见输出")
        XCTAssertTrue(spy.submittedRequests.isEmpty)

        keepAlive.end("run-1")
        XCTAssertFalse(spy.audio.isActive)
        XCTAssertEqual(spy.audio.stopCount, 1)
    }

    func testSecondLeaseKeepsAudioUntilLastEnd() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { true })

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        keepAlive.begin("run-2", title: "t", subtitle: "s")
        keepAlive.end("run-1")

        XCTAssertTrue(spy.audio.isActive)
        XCTAssertTrue(keepAlive.holdsLease("run-2"))

        keepAlive.end("run-2")
        XCTAssertFalse(spy.audio.isActive)
    }

    func testDisabledAudioDoesNotStart() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { false })

        keepAlive.begin("run-1", title: "t", subtitle: "s")

        XCTAssertFalse(spy.audio.isActive)
        XCTAssertEqual(spy.audio.startCount, 0)
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .submitted)
    }

    func testAudioStartFailureFallsBackToQueuedSystemTask() {
        let spy = SystemSpy()
        spy.audio.startSucceeds = false
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { true })

        keepAlive.begin("run-1", title: "t", subtitle: "s")

        XCTAssertEqual(spy.audio.startCount, 1)
        XCTAssertFalse(spy.audio.isActive)
        XCTAssertEqual(spy.submittedRequests.count, 1)
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .submitted)
    }

    func testUITaskExpirationRearmsStoppedAudioInsteadOfKillingRun() {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { true })
        var expired = 0

        keepAlive.begin("run-1", title: "t", subtitle: "s") { expired += 1 }
        spy.audio.isActive = false
        spy.expirationHandlers.first?()

        XCTAssertEqual(expired, 0)
        XCTAssertEqual(spy.audio.startCount, 2)
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .audio)
        XCTAssertTrue(spy.audio.isActive)
        XCTAssertEqual(spy.endedTaskIds.count, 1)
    }

    func testUITaskExpirationWithoutAudioStillNotifiesOwner() {
        let spy = SystemSpy()
        spy.submitError = SubmitFailure()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { false })
        var expired = 0
        var heldInsideCallback: Bool?

        keepAlive.begin("run-1", title: "t", subtitle: "s") {
            expired += 1
            heldInsideCallback = keepAlive.holdsLease("run-1")
        }
        spy.expirationHandlers.first?()

        XCTAssertEqual(expired, 1)
        XCTAssertFalse(keepAlive.holdsLease("run-1"))
        XCTAssertEqual(heldInsideCallback, false)
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .none)
    }

    func testDisablingAudioExpiresAudioOnlyLeases() {
        let spy = SystemSpy()
        spy.submitError = SubmitFailure()
        var audioEnabled = true
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { audioEnabled })
        var expired = 0

        keepAlive.begin("run-1", title: "t", subtitle: "s") { expired += 1 }
        spy.expirationHandlers.first?()
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .audio)

        audioEnabled = false
        keepAlive.refreshAudioKeepAlive()

        XCTAssertEqual(expired, 1)
        XCTAssertFalse(keepAlive.holdsLease("run-1"))
        XCTAssertFalse(spy.audio.isActive)
    }

    func testAudioOwnedLeaseDoesNotSubmitSystemTaskAfterForeground() async {
        let spy = SystemSpy()
        let keepAlive = spy.makeKeepAlive(isAudioKeepAliveEnabled: { true })

        keepAlive.begin("run-1", title: "t", subtitle: "s")
        spy.expirationHandlers.first?()
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .audio)
        XCTAssertTrue(spy.submittedRequests.isEmpty)

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(spy.submittedRequests.isEmpty)
        XCTAssertEqual(keepAlive.executionAssertion(for: "run-1"), .audio)
        XCTAssertTrue(keepAlive.holdsLease("run-1"))
    }

    func testNearSilentToneIsNotAllZeros() {
        let data = NearSilentKeepAliveTone.wavData()
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertTrue(NearSilentKeepAliveTone.containsAudibleEnergy(data))
    }

    func testAudioKeepAlivePreferenceDefaultsOn() {
        let defaults = UserDefaults(suiteName: "amber.audioKeepAlive.\(UUID().uuidString)")!
        XCTAssertTrue(BackgroundGenerationKeepAlive.isAudioKeepAlivePreferenceEnabled(defaults: defaults))
        defaults.set(false, forKey: IOSExecutionPreferenceKeys.audioKeepAlive)
        XCTAssertFalse(BackgroundGenerationKeepAlive.isAudioKeepAlivePreferenceEnabled(defaults: defaults))
        defaults.set(true, forKey: IOSExecutionPreferenceKeys.audioKeepAlive)
        XCTAssertTrue(BackgroundGenerationKeepAlive.isAudioKeepAlivePreferenceEnabled(defaults: defaults))
    }
}
