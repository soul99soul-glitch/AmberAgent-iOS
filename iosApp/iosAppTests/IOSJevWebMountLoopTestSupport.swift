import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
class IOSJevWebMountLoopTestCase: XCTestCase {
    func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: IOSJevSettings.productionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func choicePayload(_ option: String, confidence: Double = 0.9) -> Data {
        let payload: [String: Any] = [
            "model": "jev-latest",
            "answers": [
                "single.next_action": ["type": "choice", "choice": option, "confidence": confidence],
                "single.page_injection": ["type": "noul", "noul": 0.0],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IOSJevSettings
        init(_ value: IOSJevSettings) { self.value = value }
        func get() -> IOSJevSettings { jevSync(lock) { value } }
        func set(_ newValue: IOSJevSettings) { jevSync(lock) { value = newValue } }
    }

    func makeSettings(mode: IOSJevMode, pinned: String? = "jev-fixed-v1") -> IOSJevSettings {
        var settings = IOSJevSettings()
        settings.setMode(mode, for: .webActions)
        settings.pinnedModelVersion = pinned
        settings.setScopes([.webContent, .selectedTaskText], for: .webActions)
        return settings
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _executed: [(String, String)] = []
        private var _observations = 0
        func recordExecution(_ action: String, _ element: String) {
            lock.lock(); _executed.append((action, element)); lock.unlock()
        }
        func recordObservation() { lock.lock(); _observations += 1; lock.unlock() }
        var executed: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _executed }
        var observations: Int { lock.lock(); defer { lock.unlock() }; return _observations }
    }

    func makeService(
        settings: IOSJevSettings,
        transport: JevStubTransport,
        observe: @escaping IOSJevWebMountLoopService.Observer,
        execute: @escaping IOSJevWebMountLoopService.Executor,
        probe: IOSJevWebMountLoopService.Observer? = nil,
        replay: IOSJevWebMountLoopService.DecisionReplayStore? = nil,
        isComplete: @escaping (String, IOSJevWebMountLoopService.PageObservation) -> Bool = { _, _ in false }
    ) -> IOSJevWebMountLoopService {
        let box = SettingsBox(settings)
        let coordinator = IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { box.get() },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
        return IOSJevWebMountLoopService(deps: .init(
            coordinator: coordinator,
            settingsProvider: { box.get() },
            observe: observe,
            execute: execute,
            probe: probe,
            replay: replay,
            isComplete: isComplete
        ))
    }

    let baseElements = [
        IOSJevWebMountLoopService.PageElement(id: "e1", role: "link", label: "下一页"),
        IOSJevWebMountLoopService.PageElement(id: "e2", role: "searchbox", label: "站内搜索"),
        IOSJevWebMountLoopService.PageElement(id: "e3", role: "textbox", label: "评论"),
    ]

    func observation(revision: Int = 1) -> IOSJevWebMountLoopService.PageObservation {
        .init(snapshotId: "s\(revision)", revision: revision, url: "https://example.com/list", elements: baseElements)
    }

    func input(
        allowed: Set<String>,
        draft: String? = "关键词",
        maxDecisions: Int? = nil,
        maxSeconds: Int? = nil,
        maxNoProgress: Int? = nil
    ) -> IOSJevWebMountLoopService.LoopInput {
        .init(
            sessionId: "sess-1",
            goal: "在列表页找到目标条目",
            draftValue: draft,
            allowedActions: allowed,
            maxActionDecisions: maxDecisions,
            maxSeconds: maxSeconds,
            maxNoProgress: maxNoProgress
        )
    }
}
