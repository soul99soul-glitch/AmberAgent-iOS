import CryptoKit
import Foundation

/// A client for one locally launched, authenticated runner session.
///
/// The app allowlist is a preflight guard, not an OS sandbox: XCTest can observe and control other
/// apps. The owner must keep the runner token private and terminate the launcher at run end.
public actor PhoneRunnerClient {
    private let http: RunnerHTTP
    private var allowedBundleIDs: Set<String>
    private let allowHome: Bool
    private var stopped = false
    private var outcomeUnknown = false
    private var operationInFlight = false
    private var measurement: OperationMeasurement?
    private var snapshot: Snapshot?

    /// The same observation whose references are currently valid. Reading it performs no I/O.
    public var latestObservation: PhoneObservation? { snapshot?.observation }
    public private(set) var latestOperationDiagnostics: PhoneOperationDiagnostics?

    public init(token: String, allowedBundleIDs: Set<String>, port: UInt16 = 8100,
                allowHome: Bool = false, sessionConfiguration: URLSessionConfiguration? = nil) throws {
        guard RunnerSigning.validToken(token), port > 0,
              !allowedBundleIDs.isEmpty, allowedBundleIDs.allSatisfy({ !$0.isEmpty }) else {
            throw PhoneControlProblem(.invalidConfiguration, "A valid launch token and nonempty app scope are required.")
        }
        self.allowedBundleIDs = allowedBundleIDs
        self.allowHome = allowHome
        http = RunnerHTTP(token: token, port: port, configuration: sessionConfiguration)
    }

    public nonisolated static func newSessionToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { RunnerSigning.hex($0) }
    }

    /// Stops accepting new work. It cannot retract a gesture already dispatched to XCTest.
    /// The run owner separately stops the on-device launcher to release its test session.
    public func stop() {
        stopped = true
        snapshot = nil
    }

    /// Revokes this client's work and asks its authenticated runner to end testServe.
    /// The owner still releases the native launcher, including when shutdown fails.
    public func shutdownRunner() async throws {
        stop()
        let response = try await http.request(method: "POST", path: "/shutdown", timeoutInterval: 2)
        guard response.value["shutdown"] == .bool(true) else {
            throw PhoneControlProblem(.malformedResponse, "Runner did not confirm shutdown.")
        }
    }

    /// Extends this live run after its owner verified an installed application's exact ID.
    public func allowApplication(_ bundleID: String) throws {
        try checkCanContinue()
        guard !outcomeUnknown else {
            throw PhoneControlProblem(.previousOutcomeUnknown, "A previous action has an unknown outcome. End this run before changing its scope.")
        }
        guard !operationInFlight else {
            throw PhoneControlProblem(.busy, "Another observation or action is still running.")
        }
        guard !bundleID.isEmpty else {
            throw PhoneControlProblem(.invalidConfiguration, "An application bundle ID is required.")
        }
        allowedBundleIDs.insert(bundleID)
    }

    public func status() async throws -> PhoneRunnerStatus {
        let response = try await http.request(path: "/status")
        let value = response.value
        guard let ready = value["ready"]?.bool,
              let sessionID = value["sessionId"]?.string,
              let required = value["auth"]?["required"]?.bool,
              let scheme = value["auth"]?["scheme"]?.string else {
            throw PhoneControlProblem(.malformedResponse, "Runner status lacks readiness, session, or authentication details.")
        }
        guard required, scheme == "IPU-HMAC-SHA256" else {
            throw PhoneControlProblem(.runner, "This runner does not declare the required request authentication.")
        }
        return PhoneRunnerStatus(ready: ready, busy: value["busy"]?.bool ?? false,
                                 sessionID: sessionID, message: value["message"]?.string ?? "",
                                 requiresAuthentication: required, authenticationScheme: scheme)
    }

    public func observe(maxNodes: Int = 500, includeScreenSize: Bool = false,
                        settleBudgetMs: Int? = nil) async throws -> PhoneObservation {
        try beginOperation(.observe)
        defer { finishOperation() }
        // A failed fresh observation must not leave old actionable references alive.
        snapshot = nil
        if let settleBudgetMs, !(50...15_000).contains(settleBudgetMs) {
            throw PhoneControlProblem(.invalidConfiguration, "Screen-stability budget must be between 50 and 15000 milliseconds.")
        }
        let before = try await activeApp()
        try checkScope(before)
        try checkCanContinue()
        let stability: PhoneScreenStability?
        if let settleBudgetMs {
            stability = try await settleScreen(budgetMs: settleBudgetMs)
            try checkCanContinue()
        } else {
            stability = nil
        }
        let response = try await request(stage: .source, path: "/source", query: [
            "format": "json", "max_nodes": String(min(2_000, max(1, maxNodes))),
        ])
        guard let sourcePID = response.header("X-IPU-Pid").flatMap(Int.init), sourcePID == before.pid else {
            throw PhoneControlProblem(.appChanged, "The source tree does not belong to the checked foreground process.")
        }
        try checkCanContinue()
        let bounds: PhoneElementRect?
        if includeScreenSize {
            let size = try await screenSize()
            bounds = PhoneElementRect(x: 0, y: 0, width: size.width, height: size.height)
        } else {
            bounds = nil
        }
        let after = try await activeApp()
        try checkSameApp(before, after)
        try checkCanContinue()
        let tree = try SourceNode(response.value)
        let id = UUID().uuidString.lowercased()
        var nodes: [PhoneObservationNode] = []
        var sourceNodes: [SourceNode] = []
        var references: [String: SourceNode] = [:]
        func flatten(_ node: SourceNode, depth: Int) {
            let ref = depth > 0 && node.rect.width > 0 && node.rect.height > 0
                ? "\(id):\(nodes.count)" : nil
            if let ref { references[ref] = node }
            sourceNodes.append(node)
            nodes.append(PhoneObservationNode(
                ref: ref, depth: depth, type: node.type, identifier: node.identifier,
                label: node.label, value: node.isSecure ? nil : node.value,
                rect: node.rect, enabled: node.enabled, focused: node.focused
            ))
            for child in node.children { flatten(child, depth: depth + 1) }
        }
        flatten(tree, depth: 0)
        let alerts = observedAlerts(in: nodes, sources: sourceNodes, app: before)
        let observation = PhoneObservation(observationID: id, bundleID: before.bundleID, processID: before.pid,
                                           backend: response.header("X-IPU-Backend") ?? "unknown",
                                           truncated: response.header("X-IPU-Truncated") == "1", nodes: nodes,
                                           screenBounds: bounds, screenStability: stability,
                                           diagnostics: currentDiagnostics(), alerts: alerts,
                                           alertActionsSupported: response.header("X-IPU-Alert-Guard") == "context-v1")
        snapshot = Snapshot(id: id, app: before, references: references, observation: observation)
        return observation
    }

    /// Standalone, read-only compatibility API. Use screenshotObservation() for visual actions.
    /// Screenshots are never requested by observe() or act().
    public func screenshot() async throws -> Data {
        try beginOperation(.screenshot)
        defer { finishOperation() }
        var observed = snapshot
        snapshot = nil
        let before = try await activeApp()
        try checkScope(before)
        let data = try await screenshotPNG()
        let after = try await activeApp()
        try checkSameApp(before, after)
        try checkCanContinue()
        if observed?.app == before {
            observed?.screenshotSize = nil
            snapshot = observed
        }
        return data
    }

    /// Attaches a screenshot and its full-screen geometry to the latest tree observation.
    /// Taking another screenshot invalidates the old evidence, including when capture fails.
    public func screenshotObservation() async throws -> PhoneScreenshot {
        try beginOperation(.screenshot)
        defer { finishOperation() }
        let observed = snapshot
        snapshot = nil
        guard var observed else {
            throw PhoneControlProblem(.staleObservation, "Observe the foreground application before taking an actionable screenshot.")
        }
        let before = try await activeApp()
        try checkSameApp(observed.app, before)
        let sizeBefore = try await screenSize()
        let bounds = PhoneElementRect(x: 0, y: 0, width: sizeBefore.width, height: sizeBefore.height)
        if let observedBounds = observed.observation.screenBounds, observedBounds != bounds {
            throw PhoneControlProblem(.staleObservation, "The screen dimensions changed after the tree observation. Observe again before capturing a screenshot.")
        }
        let data = try await screenshotPNG()
        let sizeAfter = try await screenSize()
        try checkSameApp(before, try await activeApp())
        try checkCanContinue()
        guard sizeBefore == sizeAfter else {
            throw PhoneControlProblem(.staleObservation, "The screen orientation or dimensions changed during capture. Observe again.")
        }
        try sizeBefore.checkPNGDimensions(data)
        observed.screenshotSize = sizeBefore
        let tree = observed.observation
        observed.observation = PhoneObservation(
            observationID: tree.observationID, bundleID: tree.bundleID, processID: tree.processID,
            backend: tree.backend, truncated: tree.truncated, nodes: tree.nodes,
            screenBounds: bounds, screenStability: tree.screenStability, diagnostics: tree.diagnostics,
            alerts: tree.alerts, alertActionsSupported: tree.alertActionsSupported
        )
        snapshot = observed
        return PhoneScreenshot(data: data, observationID: observed.id, width: sizeBefore.width, height: sizeBefore.height)
    }

    /// Sends at most one screen-changing request, after fresh lookup and scope checks.
    public func act(_ action: PhoneAction) async -> PhoneActionResult {
        do {
            try beginOperation(.action)
        } catch {
            return .unsent(Self.problem(error))
        }
        defer { finishOperation() }
        let observed = snapshot
        snapshot = nil
        var dispatched = false
        do {
            guard !outcomeUnknown else {
                throw PhoneControlProblem(.previousOutcomeUnknown, "A previous action has an unknown outcome. End this run and reconcile before starting another.")
            }
            let path: String
            var body: [String: JSONValue] = [:]
            var resolvedAction = action
            if case .tap(let ref) = action, observed?.isAlertButton(ref) == true {
                resolvedAction = .tapAlert(ref: ref)
            }
            switch resolvedAction {
            case .launch(let bundleID):
                guard allowedBundleIDs.contains(bundleID) else {
                    throw PhoneControlProblem(.appOutOfScope, "The requested application is outside this run's scope.")
                }
                path = "/wda/apps/activate"
                body["bundleId"] = .string(bundleID)
            case .home:
                guard allowHome else {
                    throw PhoneControlProblem(.appOutOfScope, "This run does not allow the Home action.")
                }
                try checkScope(try await activeApp())
                path = "/wda/homescreen"
            case .tapAlert(let ref):
                guard let observed, let node = observed.references[ref],
                      let alert = observed.observation.alerts.first(where: { $0.buttons.contains { $0.ref == ref } }),
                      let button = alert.buttons.first(where: { $0.ref == ref }) else {
                    throw PhoneControlProblem(.staleObservation, "Alert actions require a button reference inside the latest observed alert.")
                }
                guard observed.observation.alertActionsSupported else {
                    throw PhoneControlProblem(.unsupportedNode, "This runner does not support alert-context guards. Update the runner before using alert actions.")
                }
                guard node.enabled else {
                    throw PhoneControlProblem(.unsupportedNode, "The observed alert button is disabled.")
                }
                guard alert.buttons.filter({ $0.name == button.name }).count == 1 else {
                    throw PhoneControlProblem(.ambiguousElement, "The observed alert has multiple buttons with the same name. No action was sent.")
                }
                try checkSameApp(observed.app, try await activeApp())
                path = "/alert/accept"
                body = ["name": .string(button.name), "exact_name": .bool(true),
                        "expected_text": .string(alert.text), "expected_pid": .number(Double(alert.processID)),
                        "expected_buttons": .array(alert.buttons.map { .string($0.name) })]
            case .tapPoint(let observationID, let x, let y), .longPressPoint(let observationID, let x, let y, _):
                if case .longPressPoint(_, _, _, let durationMs) = resolvedAction { try checkLongPressDuration(durationMs) }
                guard x.isFinite, y.isFinite, (0..<1).contains(x), (0..<1).contains(y) else {
                    throw PhoneControlProblem(.invalidAction, "Visual tap coordinates must be finite and normalized to [0, 1).")
                }
                let size = try await verifiedScreenshotSize(observed: observed, observationID: observationID)
                if case .longPressPoint(_, _, _, let durationMs) = resolvedAction {
                    path = "/actions"
                    body = ["actions": .array([.object([
                        "type": .string("pointer"), "id": .string("amber-long-press"),
                        "parameters": .object(["pointerType": .string("touch")]),
                        "actions": .array([
                            .object(["type": .string("pointerMove"), "duration": .number(0),
                                     "x": .number(x * size.width), "y": .number(y * size.height)]),
                            .object(["type": .string("pointerDown"), "button": .number(0)]),
                            .object(["type": .string("pause"), "duration": .number(Double(durationMs))]),
                            .object(["type": .string("pointerUp"), "button": .number(0)]),
                        ]),
                    ])])]
                } else {
                    path = "/tap"
                    body = ["x": .number(x * size.width), "y": .number(y * size.height)]
                }
            case .swipePoint(let observationID, let startX, let startY, let endX, let endY):
                guard [startX, startY, endX, endY].allSatisfy({ $0.isFinite && (0..<1).contains($0) }),
                      startX != endX || startY != endY else {
                    throw PhoneControlProblem(.invalidAction, "Visual swipe endpoints must be distinct, finite and normalized to [0, 1).")
                }
                let size = try await verifiedScreenshotSize(observed: observed, observationID: observationID)
                path = "/swipe"
                body = ["x1": .number(startX * size.width), "y1": .number(startY * size.height),
                        "x2": .number(endX * size.width), "y2": .number(endY * size.height),
                        "duration_ms": .number(300)]
            case .tap(let ref), .longPress(let ref, _), .type(let ref, _), .clear(let ref), .swipe(let ref, _):
                if case .longPress(_, let durationMs) = resolvedAction { try checkLongPressDuration(durationMs) }
                guard let observed, let node = observed.references[ref] else {
                    throw PhoneControlProblem(.staleObservation, "This reference is not part of the latest observation. Observe again.")
                }
                guard node.enabled else {
                    throw PhoneControlProblem(.unsupportedNode, "The observed element is disabled.")
                }
                switch resolvedAction {
                case .longPress:
                    guard !observed.isAlertButton(ref) else {
                        throw PhoneControlProblem(.unsupportedNode, "Long press is not supported for alert buttons. Tap the observed alert button instead.")
                    }
                case .type:
                    let inputTypes: Set<String> = ["XCUIElementTypeTextField", "XCUIElementTypeSecureTextField",
                                                   "XCUIElementTypeTextView", "XCUIElementTypeSearchField"]
                    guard inputTypes.contains(node.type) else {
                        throw PhoneControlProblem(.unsupportedNode, "Typing requires an observed text input.")
                    }
                case .clear:
                    let inputTypes: Set<String> = ["XCUIElementTypeTextField", "XCUIElementTypeTextView",
                                                   "XCUIElementTypeSearchField"]
                    guard inputTypes.contains(node.type) else {
                        throw PhoneControlProblem(.unsupportedNode, "Clearing requires an observed nonsecure text input.")
                    }
                default: break
                }
                let current = try await activeApp()
                try checkSameApp(observed.app, current)
                try checkCanContinue()
                let found = try await request(stage: .elementLookup, method: "POST", path: "/elements", body: .object([
                    "using": .string("predicate string"), "value": .string(node.predicate),
                ]))
                try checkCanContinue()
                guard let matches = found.value.array else {
                    throw PhoneControlProblem(.malformedResponse, "Element lookup did not return an array.")
                }
                guard !matches.isEmpty else {
                    throw PhoneControlProblem(.elementNotFound, "The observed element changed or disappeared. Observe again.")
                }
                guard matches.count == 1 else {
                    throw PhoneControlProblem(.ambiguousElement, "Fresh lookup matched multiple elements. No action was sent.")
                }
                guard let elementID = matches[0]["element-6066-11e4-a52e-4f735466cecf"]?.string
                    ?? matches[0]["ELEMENT"]?.string,
                      !elementID.isEmpty,
                      elementID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                          || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                    throw PhoneControlProblem(.malformedResponse, "Element lookup returned an invalid reference.")
                }
                try checkSameApp(observed.app, try await activeApp())
                switch resolvedAction {
                case .tap: path = "/element/\(elementID)/click"
                case .longPress(_, let durationMs):
                    path = "/wda/element/\(elementID)/touchAndHold"
                    body["duration"] = .number(Double(durationMs) / 1_000)
                case .type(_, let text):
                    path = "/element/\(elementID)/value"
                    body["text"] = .string(text)
                case .clear: path = "/element/\(elementID)/clear"
                case .swipe(_, let direction):
                    path = "/wda/element/\(elementID)/swipe"
                    body["direction"] = .string(direction.rawValue)
                default: preconditionFailure("Only element actions enter element lookup")
                }
            }
            try checkCanContinue()
            dispatched = true
            let response = try await request(stage: .action, method: "POST", path: path, body: .object(body))
            if case .longPressPoint = resolvedAction, response.header("X-IPU-Gesture") == "xcui-coordinate" {
                // Older runners may downgrade a failed two-point hold path to a tap.
                throw PhoneControlProblem(.runner, "The runner fell back to a tap instead of a long press. Observe and reconcile before starting another run.")
            }
            return .completed
        } catch {
            let problem = Self.problem(error)
            // Error codes such as stale element or invalid argument can follow a scroll/focus side
            // effect inside the runner. Only explicit pre-dispatch refusals establish no execution.
            if !dispatched || problem.wasDroppedBeforeExecution || problem.statusCode == 401 {
                return .unsent(problem)
            }
            outcomeUnknown = true
            return .unknown(problem)
        }
    }

    /// Retain the runner's complete alert description for every observed button. Its execution
    /// guard then refuses a truncated, changed, or different currently presented alert.
    private func observedAlerts(in nodes: [PhoneObservationNode], sources: [SourceNode],
                                app: ActiveApp) -> [PhoneObservedAlert] {
        nodes.enumerated().compactMap { index, alertNode in
            guard alertNode.type == "XCUIElementTypeAlert" else { return nil }
            let source = sources[index]
            var buttons: [PhoneObservedAlertButton] = []
            var buttonDepth: Int?
            for (sourceIndex, node) in nodes.enumerated().dropFirst(index + 1) {
                if node.depth <= alertNode.depth { break }
                if let buttonDepth, node.depth > buttonDepth { continue }
                buttonDepth = nil
                if node.type == "XCUIElementTypeButton" {
                    buttonDepth = node.depth
                    if let name = sources[sourceIndex].alertLabel {
                        buttons.append(PhoneObservedAlertButton(ref: node.ref, name: name))
                    }
                }
            }
            return PhoneObservedAlert(ref: alertNode.ref, text: source.alertText,
                                      processID: app.pid, buttons: buttons)
        }
    }

    private func checkLongPressDuration(_ durationMs: Int) throws {
        guard (300...3_000).contains(durationMs) else {
            throw PhoneControlProblem(.invalidAction, "Long-press duration must be between 300 and 3000 milliseconds.")
        }
    }

    private func verifiedScreenshotSize(observed: Snapshot?, observationID: String) async throws -> ScreenSize {
        guard let observed, observed.id == observationID, let size = observed.screenshotSize else {
            throw PhoneControlProblem(.staleObservation, "Visual actions require the screenshot attached to the latest observation. Observe with a screenshot again.")
        }
        try checkSameApp(observed.app, try await activeApp())
        let currentSize = try await screenSize()
        try checkCanContinue()
        guard size == currentSize else {
            throw PhoneControlProblem(.staleObservation, "The screen orientation or dimensions changed after the screenshot. Observe again.")
        }
        try checkSameApp(observed.app, try await activeApp())
        return size
    }

    private func beginOperation(_ operation: PhoneOperationDiagnostics.Operation) throws {
        // A refused start must not expose the previous operation's timings as its own.
        if !operationInFlight { latestOperationDiagnostics = nil }
        try checkCanContinue()
        guard !operationInFlight else {
            throw PhoneControlProblem(.busy, "Another observation or action is still running.")
        }
        operationInFlight = true
        measurement = OperationMeasurement(operation: operation)
    }

    private func finishOperation() {
        latestOperationDiagnostics = currentDiagnostics()
        measurement = nil
        operationInFlight = false
    }

    private func currentDiagnostics() -> PhoneOperationDiagnostics? {
        guard let measurement else { return nil }
        return PhoneOperationDiagnostics(operation: measurement.operation,
                                         durationMs: Self.milliseconds(since: measurement.started),
                                         requests: measurement.requests)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    }

    private func request(stage: PhoneRunnerRequestTiming.Stage, method: String = "GET", path: String,
                         query: [String: String] = [:], body: JSONValue? = nil,
                         timeoutInterval: TimeInterval? = nil) async throws -> RunnerResponse {
        let started = ContinuousClock.now
        var response: RunnerResponse?
        defer {
            measurement?.requests.append(PhoneRunnerRequestTiming(
                stage: stage, durationMs: Self.milliseconds(since: started),
                runnerMs: response.flatMap(Self.runnerMilliseconds),
                queuedMs: response?.header("X-IPU-Queued-Ms").flatMap(Self.validMilliseconds)
            ))
        }
        let received = try await http.request(method: method, path: path, query: query, body: body,
                                             timeoutInterval: timeoutInterval)
        response = received
        return received
    }

    private static func validMilliseconds(_ string: String) -> Double? {
        guard let value = Double(string), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func runnerMilliseconds(_ response: RunnerResponse) -> Double? {
        if let value = response.header("X-IPU-Ms").flatMap(validMilliseconds) { return value }
        for metric in (response.header("Server-Timing") ?? "").split(separator: ",") {
            let parameters = metric.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parameters.first == "runner" else { continue }
            for parameter in parameters.dropFirst() where parameter.hasPrefix("dur=") {
                if let value = validMilliseconds(String(parameter.dropFirst(4))) { return value }
            }
        }
        return nil
    }

    private func settleScreen(budgetMs: Int) async throws -> PhoneScreenStability {
        let response = try await request(stage: .settle, path: "/wda/settle",
                                         query: ["budget_ms": String(budgetMs)],
                                         timeoutInterval: Double(budgetMs) / 1_000 + 2)
        let value = response.value
        guard let stable = value["stable"]?.bool,
              let waitedMs = value["waited_ms"]?.number, waitedMs.isFinite, waitedMs >= 0,
              let frames = value["frames"]?.number, frames.isFinite, frames >= 0, frames.rounded() == frames,
              let changed = value["changed_px"]?.number, changed.isFinite, changed >= -1, changed.rounded() == changed,
              let captureMs = value["capture_ms"]?.number, captureMs.isFinite, captureMs >= 0,
              let actualBudget = value["budget_ms"]?.number, actualBudget == Double(budgetMs),
              frames < Double(Int.max), changed < Double(Int.max),
              frames == 0 || value["blank"]?.bool != nil else {
            throw PhoneControlProblem(.malformedResponse, "Runner did not return valid screen-stability measurements.")
        }
        return PhoneScreenStability(stable: stable, blank: value["blank"]?.bool, waitedMs: waitedMs,
                                    frames: Int(frames), changedPixels: Int(changed), captureMs: captureMs,
                                    budgetMs: budgetMs)
    }

    private func checkCanContinue() throws {
        guard !stopped else { throw PhoneControlProblem(.stopped, "This phone-control session has stopped.") }
        try Task.checkCancellation()
    }

    private func activeApp() async throws -> ActiveApp {
        let response = try await request(stage: .activeApp, path: "/wda/activeAppInfo")
        guard let bundleID = response.value["bundleId"]?.string, !bundleID.isEmpty,
              let pid = response.value["pid"]?.number, pid > 0, pid <= Double(Int32.max) else {
            throw PhoneControlProblem(.malformedResponse, "Runner did not identify the foreground application.")
        }
        let app = ActiveApp(bundleID: bundleID, pid: Int(pid))
        if let snapshot, snapshot.app != app { self.snapshot = nil }
        return app
    }

    private func screenSize() async throws -> ScreenSize {
        let response = try await request(stage: .screenSize, path: "/window/size")
        guard let width = response.value["width"]?.number, width.isFinite, width > 0,
              let height = response.value["height"]?.number, height.isFinite, height > 0 else {
            throw PhoneControlProblem(.malformedResponse, "Runner did not return valid full-screen dimensions.")
        }
        return ScreenSize(width: width, height: height)
    }

    private func screenshotPNG() async throws -> Data {
        let response = try await request(stage: .screenshot, path: "/screenshot")
        guard let encoded = response.value.string, let data = Data(base64Encoded: encoded),
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw PhoneControlProblem(.malformedResponse, "Runner screenshot is not a base64 PNG.")
        }
        return data
    }

    private func checkScope(_ app: ActiveApp) throws {
        guard allowedBundleIDs.contains(app.bundleID) else {
            throw PhoneControlProblem(.appOutOfScope, "The foreground application is outside this run's scope.")
        }
    }

    private func checkSameApp(_ before: ActiveApp, _ after: ActiveApp) throws {
        guard before == after else {
            snapshot = nil
            throw PhoneControlProblem(.appChanged, "The foreground application or process changed. Observe again.")
        }
        try checkScope(after)
    }

    private static func problem(_ error: Error) -> PhoneControlProblem {
        if let error = error as? PhoneControlProblem { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return PhoneControlProblem(.cancelled, "The request was cancelled.")
        }
        return PhoneControlProblem(.transport, error.localizedDescription)
    }
}

private struct OperationMeasurement {
    let operation: PhoneOperationDiagnostics.Operation
    let started = ContinuousClock.now
    var requests: [PhoneRunnerRequestTiming] = []
}

private struct ActiveApp: Sendable, Equatable {
    let bundleID: String
    let pid: Int
}

private struct Snapshot: Sendable {
    let id: String
    let app: ActiveApp
    let references: [String: SourceNode]
    var observation: PhoneObservation
    var screenshotSize: ScreenSize?

    func isAlertButton(_ ref: String) -> Bool {
        var alertDepth: Int?
        for node in observation.nodes {
            if let depth = alertDepth, node.depth <= depth { alertDepth = nil }
            if node.type == "XCUIElementTypeAlert", alertDepth == nil { alertDepth = node.depth }
            if node.ref == ref { return node.type == "XCUIElementTypeButton" && alertDepth != nil }
        }
        return false
    }
}

private struct ScreenSize: Sendable, Equatable {
    let width: Double
    let height: Double

    func checkPNGDimensions(_ data: Data) throws {
        // IHDR stores pixel dimensions; the coordinate route expects oriented screen points.
        // Checking their aspect ratio prevents applying portrait evidence to landscape geometry.
        guard data.count >= 33, data[8..<16].elementsEqual([0, 0, 0, 13, 73, 72, 68, 82]) else {
            throw PhoneControlProblem(.malformedResponse, "Runner screenshot lacks its PNG image dimensions.")
        }
        let pixelWidth = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let pixelHeight = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard pixelWidth > 0, pixelHeight > 0,
              abs(Double(pixelWidth) - Double(pixelHeight) * width / height) <= 1 else {
            throw PhoneControlProblem(.malformedResponse, "Screenshot pixels do not match the full-screen orientation and aspect ratio.")
        }
    }
}

private struct SourceNode: Sendable {
    let type: String
    let identifier: String?
    let label: String?
    let name: String?
    let value: String?
    let rect: PhoneElementRect
    let enabled: Bool
    let focused: Bool
    let children: [SourceNode]
    var isSecure: Bool { type == "XCUIElementTypeSecureTextField" }

    init(_ json: JSONValue) throws {
        guard let type = json["type"]?.string,
              let x = json["rect"]?["x"]?.number, let y = json["rect"]?["y"]?.number,
              let width = json["rect"]?["width"]?.number, let height = json["rect"]?["height"]?.number,
              [x, y, width, height].allSatisfy(\.isFinite) else {
            throw PhoneControlProblem(.malformedResponse, "Source tree contains a node without its type or frame.")
        }
        self.type = type
        identifier = json["rawIdentifier"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        label = json["label"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        name = json["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        value = json["value"]?.string
        rect = PhoneElementRect(x: x, y: y, width: width, height: height)
        enabled = json["isEnabled"]?.bool ?? true
        focused = json["isFocused"]?.bool ?? false
        children = try (json["children"]?.array ?? []).map(SourceNode.init)
    }

    var alertLabel: String? { label ?? name ?? value.flatMap { $0.isEmpty ? nil : $0 } }

    var alertText: String {
        var text: [String] = []
        func walk(_ node: SourceNode) {
            if node.type == "XCUIElementTypeButton" { return }
            if node.type == "XCUIElementTypeStaticText" || node.type == "XCUIElementTypeTextView",
               let label = node.alertLabel, !text.contains(label) {
                text.append(label)
            }
            for child in node.children { walk(child) }
        }
        for child in children { walk(child) }
        return text.isEmpty ? alertLabel ?? "" : text.joined(separator: "\n")
    }

    var predicate: String {
        var terms = ["type == \(Self.literal(type))", "enabled == true"]
        if let identifier { terms.append("rawIdentifier == \(Self.literal(identifier))") }
        else if let label { terms.append("label == \(Self.literal(label))") }
        // A reference is to this observed appearance, not whichever row later reuses its label.
        if let label, identifier != nil { terms.append("label == \(Self.literal(label))") }
        if let value, !isSecure { terms.append("value == \(Self.literal(value))") }
        terms.append(contentsOf: ["rect.x == \(rect.x)", "rect.y == \(rect.y)",
                                  "rect.width == \(rect.width)", "rect.height == \(rect.height)"])
        return terms.joined(separator: " AND ")
    }

    private static func literal(_ value: String) -> String {
        // NSPredicate rejects a raw line feed inside a quoted string literal.
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n") + "'"
    }
}
