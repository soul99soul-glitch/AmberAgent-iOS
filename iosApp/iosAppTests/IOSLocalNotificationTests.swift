import Foundation
import Testing
import UserNotifications
@testable import iosApp

@MainActor
private final class FakeLocalNotificationCenter: IOSLocalNotificationCenter {
    var status: IOSLocalNotificationAuthorization
    var requestResult = true
    var requests: [IOSLocalNotificationRequest] = []
    var removed: [[String]] = []
    var pendingIdentifiers: [String] = []
    var deliveredIdentifiers: [String] = []
    var removedDelivered: [[String]] = []
    var blocksAdd = false
    var blocksSoundUpdate = false
    var completionSoundUpdates: [Bool] = []
    private(set) var addContinuation: CheckedContinuation<Void, Never>?
    private(set) var soundUpdateContinuation: CheckedContinuation<Void, Never>?

    init(status: IOSLocalNotificationAuthorization) { self.status = status }

    func authorization() async -> IOSLocalNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        if requestResult { status = .allowed }
        return requestResult
    }
    func add(_ request: IOSLocalNotificationRequest) async throws {
        requests.append(request)
        if !pendingIdentifiers.contains(request.identifier) { pendingIdentifiers.append(request.identifier) }
        if blocksAdd {
            await withCheckedContinuation { continuation in
                addContinuation = continuation
            }
        }
    }
    func pendingRequestIdentifiers() async -> [String] { pendingIdentifiers }
    func removePendingRequests(identifiers: [String]) {
        removed.append(identifiers)
        pendingIdentifiers.removeAll { identifiers.contains($0) }
    }
    func deliveredRequestIdentifiers() async -> [String] { deliveredIdentifiers }
    func removeDeliveredRequests(identifiers: [String]) { removedDelivered.append(identifiers) }
    func updateTaskCompletionSound(enabled: Bool) async throws {
        completionSoundUpdates.append(enabled)
        let targets = requests.indices.filter {
            requests[$0].identifier.hasPrefix("amber.task-complete.") &&
                pendingIdentifiers.contains(requests[$0].identifier) && requests[$0].playsSound != enabled
        }
        if blocksSoundUpdate {
            await withCheckedContinuation { soundUpdateContinuation = $0 }
        }
        for index in targets {
            requests[index].playsSound = enabled
            // UNUserNotificationCenter updates content by adding the request again.
            if !pendingIdentifiers.contains(requests[index].identifier) {
                pendingIdentifiers.append(requests[index].identifier)
            }
        }
    }

    func resumeSoundUpdate() {
        soundUpdateContinuation?.resume()
        soundUpdateContinuation = nil
    }

    func resumeAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
}

@Suite("Local notifications")
@MainActor
struct IOSLocalNotificationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func completionRequiresExistingAuthorization() async throws {
        let center = FakeLocalNotificationCenter(status: .denied)
        let service = IOSLocalNotificationService(
            center: center,
            now: { now },
            completionNotificationsEnabled: { true }
        )
        #expect(try await service.scheduleTaskCompletion(conversationID: "abc") == .notAuthorized)
        #expect(center.requests.isEmpty)
    }

    @Test func completionHasStableIdentifierAndConversationRoute() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        let service = IOSLocalNotificationService(
            center: center,
            now: { now },
            completionNotificationsEnabled: { true }
        )
        #expect(try await service.scheduleTaskCompletion(conversationID: "abc-123") == .scheduled(identifier: "amber.task-complete.abc-123"))
        let request = try #require(center.requests.first)
        #expect(IOSAppDeepLink.parse(request.deepLink) == .conversation(id: "abc-123"))
        #expect(request.fireDate == now.addingTimeInterval(1))
    }

    @Test func completionSoundFollowsPreferenceWithoutSilencingOtherNotifications() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        var hapticEnabled = false
        let service = IOSLocalNotificationService(
            center: center, now: { now }, completionNotificationsEnabled: { true },
            completionHapticEnabled: { hapticEnabled }
        )
        _ = try await service.scheduleTaskCompletion(conversationID: "reply")
        #expect(center.requests.first?.playsSound == false)
        _ = try await service.scheduleManualReminder(title: "提醒", fireDate: now.addingTimeInterval(600))
        hapticEnabled = true
        try await service.refreshTaskCompletionSound()
        #expect(center.requests.first?.playsSound == true)
        hapticEnabled = false
        try await service.refreshTaskCompletionSound()
        #expect(center.requests.first?.playsSound == false)
        #expect(center.requests.last?.playsSound == true)
        #expect(center.requests.first?.userInfo[IOSTaskCompletionNotificationFeedback.markerKey] == "true")
    }

    @Test func completionSettingChangeDuringAddIsReconciledAfterCommit() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        center.blocksAdd = true
        var hapticEnabled = true
        let service = IOSLocalNotificationService(
            center: center, now: { now }, completionNotificationsEnabled: { true },
            completionHapticEnabled: { hapticEnabled }
        )
        let task = Task { try await service.scheduleTaskCompletion(conversationID: "reply") }
        while center.addContinuation == nil { await Task.yield() }
        #expect(center.requests.first?.playsSound == true)
        hapticEnabled = false
        center.resumeAdd()
        _ = try await task.value
        #expect(center.requests.first?.playsSound == false)
        #expect(center.completionSoundUpdates == [false])
    }

    @Test func foregroundCompletionKeepsBannerAndLeavesRevealOwnerTheOnlyFeedbackSource() {
        #expect(IOSTaskCompletionNotificationFeedback.presentationOptions(
            identifier: "amber.task-complete.reply", userInfo: [:]
        ) == [.banner])
        #expect(IOSTaskCompletionNotificationFeedback.presentationOptions(
            identifier: IOSLocalNotificationService.manualReminderIdentifier, userInfo: [:]
        ) == [.banner, .sound])
        #expect(IOSTaskCompletionNotificationFeedback.presentationOptions(
            identifier: "amber.watch-attention.reply.decision", userInfo: [:]
        ) == [.banner, .sound])
    }

    @Test func cancellationWinsAgainstInFlightCompletionSoundUpdate() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        var hapticEnabled = true
        let service = IOSLocalNotificationService(
            center: center, now: { now }, completionNotificationsEnabled: { true },
            completionHapticEnabled: { hapticEnabled }
        )
        _ = try await service.scheduleTaskCompletion(conversationID: "reply")
        center.pendingIdentifiers.append(IOSLocalNotificationService.manualReminderIdentifier)
        hapticEnabled = false
        center.blocksSoundUpdate = true
        let update = Task { try await service.refreshTaskCompletionSound() }
        while center.soundUpdateContinuation == nil { await Task.yield() }
        await service.cancelTaskCompletionNotifications()
        center.resumeSoundUpdate()
        try await update.value
        #expect(center.pendingIdentifiers == [IOSLocalNotificationService.manualReminderIdentifier])
        #expect(center.removed.last == ["amber.task-complete.reply"])
    }

    @Test func reminderValidatesDateAndReplacesPreviousRequest() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        let service = IOSLocalNotificationService(center: center, now: { now })
        #expect(try await service.scheduleManualReminder(title: "Soon", fireDate: now.addingTimeInterval(4)) == .invalidDate)
        #expect(try await service.scheduleManualReminder(title: "继续写作", fireDate: now.addingTimeInterval(600)) == .scheduled(identifier: IOSLocalNotificationService.manualReminderIdentifier))
        #expect(center.removed.last == [IOSLocalNotificationService.manualReminderIdentifier])
        service.cancelManualReminder()
        #expect(center.removed.count == 2)
    }

    @Test func disablingCompletionNotificationsRemovesOnlyPendingCompletionRequests() async {
        let center = FakeLocalNotificationCenter(status: .allowed)
        center.pendingIdentifiers = [
            "amber.task-complete.first",
            IOSLocalNotificationService.manualReminderIdentifier,
            "amber.task-complete.second"
        ]
        center.deliveredIdentifiers = [
            "amber.task-complete.first",
            IOSLocalNotificationService.manualReminderIdentifier
        ]
        let service = IOSLocalNotificationService(center: center, now: { now })

        await service.cancelTaskCompletionNotifications()

        #expect(center.removed == [["amber.task-complete.first", "amber.task-complete.second"]])
        #expect(center.removedDelivered == [["amber.task-complete.first"]])
    }

    @Test func agentNotificationToolSchedulesAndCancelsItsOwnStableRequest() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        let service = IOSLocalNotificationService(center: center, now: { now })
        let fireAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(600))

        let scheduled = await IOSNotificationAgentToolExecutor.execute(
            toolName: IOSAppleAgentToolCatalog.notificationSchedule,
            input: #"{"title":"喝水","body":"休息一下","fire_at":"\#(fireAt)","display_title":"安排喝水提醒"}"#,
            service: service
        )
        #expect(scheduled.contains(#""ok":true"#))
        #expect(center.requests.last?.identifier == IOSLocalNotificationService.agentReminderIdentifier)

        let cancelled = await IOSNotificationAgentToolExecutor.execute(
            toolName: IOSAppleAgentToolCatalog.notificationCancel,
            input: #"{"display_title":"取消喝水提醒"}"#,
            service: service
        )
        #expect(cancelled.contains(#""cancelled":true"#))
        #expect(center.removed.last == [IOSLocalNotificationService.agentReminderIdentifier])
    }

    @Test func cancellingInFlightAgentNotificationRemovesCommittedRequest() async {
        let center = FakeLocalNotificationCenter(status: .allowed)
        center.blocksAdd = true
        let service = IOSLocalNotificationService(center: center, now: { now })

        let task = Task {
            try await service.scheduleAgentNotification(
                title: "喝水",
                body: "休息一下",
                fireDate: now.addingTimeInterval(600)
            )
        }
        while center.addContinuation == nil { await Task.yield() }
        task.cancel()
        center.resumeAdd()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(center.removed.last == [IOSLocalNotificationService.agentReminderIdentifier])
    }

    @Test func deepLinkInboxBuffersNotificationUntilShellInstallsHandler() throws {
        let inbox = IOSDeepLinkInbox()
        let url = try #require(IOSAppDeepLink.url(for: .latestConversation))
        var received: [URL] = []

        inbox.submit(url)
        #expect(received.isEmpty)
        inbox.installHandler { received.append($0) }

        #expect(received == [url])
    }

    @Test func watchHandoffSurvivesHandlerInstallationUntilDestinationAcknowledges() throws {
        let suite = "WatchHandoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try #require(IOSAppDeepLink.url(for: .conversation(id: "conversation-1")))
        let first = IOSDeepLinkInbox(defaults: defaults)
        var received: [URL] = []
        first.submit(url, persistUntilHandled: true)
        first.installHandler { received.append($0) }
        #expect(received == [url])

        // Installing a handler is not evidence that bootstrap/navigation finished.
        let restarted = IOSDeepLinkInbox(defaults: defaults)
        received = []
        restarted.installHandler { received.append($0) }
        #expect(received == [url])
        restarted.acknowledge(url)

        received = []
        IOSDeepLinkInbox(defaults: defaults).installHandler { received.append($0) }
        #expect(received.isEmpty)
    }

    @Test func watchHandoffWithLiveHandlerIsDurableAndDeliveredOnce() throws {
        let suite = "WatchHandoffLive.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try #require(IOSAppDeepLink.url(for: .conversation(id: "conversation-2")))
        let inbox = IOSDeepLinkInbox(defaults: defaults)
        var received: [URL] = []
        inbox.installHandler { received.append($0) }
        inbox.submit(url, persistUntilHandled: true)
        #expect(received == [url])
        received = []
        IOSDeepLinkInbox(defaults: defaults).installHandler { received.append($0) }
        #expect(received == [url])
    }

    @Test func notificationCategoriesPreserveExistingAndRegisterProactiveCardActions() throws {
        let all = AmberNotificationCategories.all
        let ids = Set(all.map(\.identifier))

        #expect(ids.contains(IOSWatchDecisionNotification.approvalCategory))
        #expect(ids.contains(IOSWatchDecisionNotification.denyOnlyCategory))
        #expect(ids.contains(MacGatewayApprovalNotification.category))
        #expect(ids.contains(CloudProactiveNotification.category))

        let cloudApproval = try #require(all.first { $0.identifier == MacGatewayApprovalNotification.cloudCategory })
        let review = try #require(cloudApproval.actions.first { $0.identifier == MacGatewayApprovalNotification.openCloudApprovalAction })
        #expect(review.options.contains(.foreground))
        let deny = try #require(cloudApproval.actions.first { $0.identifier == MacGatewayApprovalNotification.denyCloudAction })
        #expect(!deny.options.contains(.foreground))

        let proactive = try #require(all.first { $0.identifier == CloudProactiveNotification.category })
        #expect(proactive.actions.count == 3)

        let act = try #require(proactive.actions.first { $0.identifier == CloudProactiveNotification.actAction })
        #expect(act.options.contains(.foreground))
        #expect(!act.options.contains(.destructive))

        let snooze = try #require(proactive.actions.first { $0.identifier == CloudProactiveNotification.snoozeAction })
        #expect(!snooze.options.contains(.foreground))
        #expect(!snooze.options.contains(.destructive))

        let mute = try #require(proactive.actions.first { $0.identifier == CloudProactiveNotification.muteAction })
        #expect(!mute.options.contains(.foreground))
        #expect(mute.options.contains(.destructive))
    }

    @Test func proactiveWillPresentReturnsListOnlyAndTriggersCloudDialoguePoll() async {
        let delegate = AmberAppDelegate()
        var pollCount = 0

        let options = delegate.handleWillPresent(
            identifier: "proactive-1",
            categoryIdentifier: CloudProactiveNotification.category,
            userInfo: ["signalId": "wt_signal_1"],
            pollCloudDialogue: {
                pollCount += 1
            }
        )

        #expect(options == [.list])
        for _ in 0..<10 where pollCount == 0 {
            await Task.yield()
        }
        #expect(pollCount == 1)

        // Non-proactive categories retain existing foreground presentation behavior.
        let other = delegate.handleWillPresent(
            identifier: IOSLocalNotificationService.manualReminderIdentifier,
            categoryIdentifier: "",
            userInfo: [:],
            pollCloudDialogue: {
                pollCount += 1
            }
        )
        #expect(other == [.banner, .sound])
        #expect(pollCount == 1)
    }

    @Test func proactiveDidReceiveActAndDefaultTapSubmitValidatedDeepLinks() async throws {
        let delegate = AmberAppDelegate()
        let coldInbox = IOSDeepLinkInbox()
        var submitted: [URL] = []

        let handledAct = await delegate.handleCloudProactiveNotificationResponse(
            categoryIdentifier: CloudProactiveNotification.category,
            actionIdentifier: CloudProactiveNotification.actAction,
            userInfo: ["signalId": "wt_abc_1"],
            submitDeepLink: { coldInbox.submit($0) }
        )
        #expect(handledAct == true)
        coldInbox.installHandler { submitted.append($0) }
        #expect(submitted == [try #require(URL(string: "amber://proactive/wt_abc_1"))])

        // Default tap using deepLink fallback for a new signal submits the deep link.
        let handledDefault = await delegate.handleCloudProactiveNotificationResponse(
            categoryIdentifier: CloudProactiveNotification.category,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["deepLink": "amber://proactive/wk_sig-2"],
            submitDeepLink: { coldInbox.submit($0) }
        )
        #expect(handledDefault == true)
        #expect(submitted.last == URL(string: "amber://proactive/wk_sig-2"))

        // Invalid signalId is claimed without submitting any deep link.
        let handledInvalid = await delegate.handleCloudProactiveNotificationResponse(
            categoryIdentifier: CloudProactiveNotification.category,
            actionIdentifier: CloudProactiveNotification.actAction,
            userInfo: ["signalId": "../escape"],
            submitDeepLink: { submitted.append($0) }
        )
        #expect(handledInvalid == true)
        #expect(submitted.count == 2)
        #expect(CloudProactiveNotification.signalId(from: ["signalId": " wt_abc_1 "]) == nil)
        #expect(CloudProactiveNotification.signalId(from: ["signalId": "", "deepLink": "amber://proactive/valid"]) == nil)
    }

    @Test(arguments: [true, false])
    func backgroundFeedbackCancellationReportsFailureBeforeEndingLease(systemExpires: Bool) async {
        let delegate = AmberAppDelegate()
        var expire: (@MainActor () -> Void)?
        var events: [String] = []
        let handled = await delegate.handleCloudProactiveNotificationResponse(
            categoryIdentifier: CloudProactiveNotification.category,
            actionIdentifier: CloudProactiveNotification.snoozeAction,
            userInfo: ["signalId": "wt_deadline"],
            ensureCloudGatewayReady: {},
            sendProactiveFeedback: { _, _ in
                if systemExpires { expire?() }
                do {
                    try await Task.sleep(for: .seconds(2))
                    return true
                } catch {
                    events.append("cancelled")
                    return false
                }
            },
            deliverFallbackNotification: { _, _, _, info in
                #expect(info["deepLink"] as? String == "amber://proactive/wt_deadline")
                events.append("failure")
            },
            beginBackgroundTask: { handler in
                expire = handler
                return .init(rawValue: 73)
            },
            endBackgroundTask: { identifier in
                #expect(identifier.rawValue == 73)
                events.append("ended")
            },
            feedbackBudget: systemExpires ? .seconds(4) : .milliseconds(25)
        )
        #expect(handled)
        #expect(events == ["cancelled", "failure", "ended"])
    }

    @Test func proactiveDidReceiveSnoozeAndMuteWaitForRestoreAndNotifyOnFailure() async {
        let delegate = AmberAppDelegate()
        var callLog: [String] = []
        var feedbackCalls: [(String, CloudProactiveFeedbackAction)] = []
        var fallbackNotifications: [(id: String, title: String, body: String, userInfo: [AnyHashable: Any])] = []

        // 1) Snooze succeeds after waiting for store restore: no fallback notification.
        let snoozeOk = await delegate.handleCloudProactiveNotificationResponse(
            categoryIdentifier: CloudProactiveNotification.category,
            actionIdentifier: CloudProactiveNotification.snoozeAction,
            userInfo: ["signalId": "wt_snooze_ok"],
            ensureCloudGatewayReady: {
                callLog.append("restore")
            },
            sendProactiveFeedback: { signalId, action in
                callLog.append("feedback:\(action.rawValue)")
                feedbackCalls.append((signalId, action))
                return true
            },
            deliverFallbackNotification: { id, title, body, info in
                fallbackNotifications.append((id, title, body, info))
            },
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in }
        )
        #expect(snoozeOk == true)
        #expect(callLog == ["restore", "feedback:snooze"])
        #expect(feedbackCalls.last?.0 == "wt_snooze_ok")
        #expect(feedbackCalls.last?.1 == .snooze)
        #expect(fallbackNotifications.isEmpty)

        // 2) Snooze fails: emits local fallback notification with deepLink to retry.
        let snoozeFail = await delegate.handleCloudProactiveNotificationResponse(
            categoryIdentifier: CloudProactiveNotification.category,
            actionIdentifier: CloudProactiveNotification.snoozeAction,
            userInfo: ["signalId": "wt_snooze_fail"],
            ensureCloudGatewayReady: {},
            sendProactiveFeedback: { signalId, action in
                feedbackCalls.append((signalId, action))
                return false
            },
            deliverFallbackNotification: { id, title, body, info in
                fallbackNotifications.append((id, title, body, info))
            },
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in }
        )
        #expect(snoozeFail == true)
        #expect(fallbackNotifications.count == 1)
        #expect(fallbackNotifications.last?.id == CloudProactiveNotification.failureNotificationIdentifier(signalId: "wt_snooze_fail", action: .snooze))
        #expect(fallbackNotifications.last?.body.contains("稍后提醒") == true)
        #expect(fallbackNotifications.last?.userInfo["deepLink"] as? String == "amber://proactive/wt_snooze_fail")

        // 3) Mute fails: calls muteTopic feedback and emits fallback notification.
        let muteFail = await delegate.handleCloudProactiveNotificationResponse(
            categoryIdentifier: CloudProactiveNotification.category,
            actionIdentifier: CloudProactiveNotification.muteAction,
            userInfo: ["deepLink": "amber://proactive/wt_mute_fail"],
            ensureCloudGatewayReady: {},
            sendProactiveFeedback: { signalId, action in
                feedbackCalls.append((signalId, action))
                return false
            },
            deliverFallbackNotification: { id, title, body, info in
                fallbackNotifications.append((id, title, body, info))
            },
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in }
        )
        #expect(muteFail == true)
        #expect(feedbackCalls.last?.0 == "wt_mute_fail")
        #expect(feedbackCalls.last?.1 == .muteTopic)
        #expect(fallbackNotifications.count == 2)
        #expect(fallbackNotifications.last?.id == CloudProactiveNotification.failureNotificationIdentifier(signalId: "wt_mute_fail", action: .muteTopic))
        #expect(fallbackNotifications.last?.body.contains("减少此类") == true)
        #expect(fallbackNotifications.last?.userInfo["deepLink"] as? String == "amber://proactive/wt_mute_fail")
    }
}
