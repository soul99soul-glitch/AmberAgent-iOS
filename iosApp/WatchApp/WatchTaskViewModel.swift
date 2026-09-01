import Combine
import Foundation
import SwiftUI

@MainActor
final class WatchTaskViewModel: ObservableObject {
    @Published private(set) var snapshot: WatchTaskSnapshot = .idle
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSending = false
    @Published private(set) var isRefreshing = false
    @Published var draftAnswer: String = ""
    @Published var isDictating = false

    private let bridge: WatchConnectivityBridge
    private var lastRequestId: String?
    private var refreshTimeoutTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?

    var isBusy: Bool { isSending || isRefreshing }

    init(bridge: WatchConnectivityBridge = .shared) {
        self.bridge = bridge
    }

    func start() {
        bridge.configure()
        bridge.onSnapshotUpdated = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        bridge.onReachabilityChanged = { [weak self] _ in
            guard let self else { return }
            self.receive(self.bridge.latestSnapshot)
        }
        bridge.onActionResult = { [weak self] result in
            guard let self, result.requestId == self.lastRequestId else { return }
            self.lastRequestId = nil
            self.isSending = false
            self.receive(self.bridge.latestSnapshot)
            self.statusMessage = result.message.map {
                WatchTaskLocalization.string(
                    $0,
                    defaultValue: $0,
                    languageCode: self.snapshot.languageCode
                )
            }
            if result.accepted {
                self.draftAnswer = ""
                self.isDictating = false
            }
        }
        bridge.activateIfNeeded()
        _ = bridge.requestSnapshotFromPhone()
        receive(bridge.latestSnapshot)
    }

    func refresh() {
        guard !isBusy else { return }
        isRefreshing = true
        statusMessage = nil
        guard bridge.requestSnapshotFromPhone() else {
            isRefreshing = false
            statusMessage = localized("无法连接 iPhone，请稍后重试")
            receive(bridge.latestSnapshot)
            return
        }
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.isRefreshing else { return }
            self.isRefreshing = false
            self.statusMessage = self.localized("无法连接 iPhone，请稍后重试")
        }
    }

    func approve() {
        send(action: .approve, optionId: "approve")
    }

    func deny() {
        send(action: .deny, optionId: "deny")
    }

    func choose(optionId: String) {
        if optionId == "open-phone" {
            openOnPhone()
            return
        }
        if optionId == "dictate" {
            isDictating = true
            return
        }
        send(action: .choose, optionId: optionId)
    }

    func submitDraftAnswer() {
        let text = draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusMessage = localized("请先输入或语音识别内容")
            return
        }
        send(action: .answer, text: text)
    }

    func cancel() {
        send(action: .cancel)
    }

    func retry() {
        send(action: .retry)
    }

    func openOnPhone() {
        send(action: .openOnPhone)
    }

    private func send(
        action: WatchInboundAction,
        optionId: String? = nil,
        text: String? = nil
    ) {
        guard !isBusy else { return }
        guard snapshot.isActive || action == .refresh else {
            statusMessage = localized("当前没有任务")
            return
        }
        isSending = true
        statusMessage = nil
        let requestId = UUID().uuidString
        lastRequestId = requestId
        let request = WatchTaskActionRequest(
            requestId: requestId,
            runId: snapshot.runId,
            conversationId: snapshot.conversationId,
            decisionId: snapshot.decision?.id,
            action: action,
            optionId: optionId,
            text: text,
            createdAt: Date()
        )
        bridge.sendAction(request)
    }

    private func receive(_ authoritativeSnapshot: WatchTaskSnapshot) {
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        isRefreshing = false
        snapshot = WatchSnapshotFreshnessPolicy.presented(
            authoritativeSnapshot,
            isPhoneReachable: bridge.isCompanionReachable
        )
        freshnessTask?.cancel()
        guard authoritativeSnapshot.isActive,
              !bridge.isCompanionReachable else { return }
        let remaining = max(
            0,
            WatchSnapshotFreshnessPolicy.staleAfter
                - Date().timeIntervalSince(authoritativeSnapshot.updatedAt)
        )
        freshnessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.snapshot = WatchSnapshotFreshnessPolicy.presented(
                self.bridge.latestSnapshot,
                isPhoneReachable: self.bridge.isCompanionReachable
            )
        }
    }

    private func localized(_ key: String) -> String {
        WatchTaskLocalization.string(
            key,
            defaultValue: key,
            languageCode: snapshot.languageCode
        )
    }
}
