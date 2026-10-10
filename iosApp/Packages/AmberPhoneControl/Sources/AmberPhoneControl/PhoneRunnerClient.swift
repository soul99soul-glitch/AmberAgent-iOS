import CryptoKit
import Foundation

/// A client for one locally launched, authenticated runner session.
///
/// The app allowlist is a preflight guard, not an OS sandbox: XCTest can observe and control other
/// apps. The owner must keep the runner token private and terminate the launcher at run end.
public actor PhoneRunnerClient {
    private let http: RunnerHTTP
    private let allowedBundleIDs: Set<String>
    private let allowHome: Bool
    private var stopped = false
    private var outcomeUnknown = false
    private var operationInFlight = false
    private var snapshot: Snapshot?

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

    public func observe(maxNodes: Int = 500) async throws -> PhoneObservation {
        try beginOperation()
        defer { operationInFlight = false }
        // A failed fresh observation must not leave old actionable references alive.
        snapshot = nil
        let before = try await activeApp()
        try checkScope(before)
        let response = try await http.request(path: "/source", query: [
            "format": "json", "max_nodes": String(min(2_000, max(1, maxNodes))),
        ])
        guard let sourcePID = response.header("X-IPU-Pid").flatMap(Int.init), sourcePID == before.pid else {
            throw PhoneControlProblem(.appChanged, "The source tree does not belong to the checked foreground process.")
        }
        let after = try await activeApp()
        try checkSameApp(before, after)
        try checkCanContinue()
        let tree = try SourceNode(response.value)
        let id = UUID().uuidString.lowercased()
        var nodes: [PhoneObservationNode] = []
        var references: [String: SourceNode] = [:]
        func flatten(_ node: SourceNode, depth: Int) {
            let ref = depth > 0 && node.rect.width > 0 && node.rect.height > 0
                ? "\(id):\(nodes.count)" : nil
            if let ref { references[ref] = node }
            nodes.append(PhoneObservationNode(
                ref: ref, depth: depth, type: node.type, identifier: node.identifier,
                label: node.label, value: node.isSecure ? nil : node.value,
                rect: node.rect, enabled: node.enabled, focused: node.focused
            ))
            for child in node.children { flatten(child, depth: depth + 1) }
        }
        flatten(tree, depth: 0)
        snapshot = Snapshot(app: before, references: references)
        return PhoneObservation(observationID: id, bundleID: before.bundleID, processID: before.pid,
                                backend: response.header("X-IPU-Backend") ?? "unknown",
                                truncated: response.header("X-IPU-Truncated") == "1", nodes: nodes)
    }

    /// Screenshots are opt-in. They are never requested by observe() or act().
    public func screenshot() async throws -> Data {
        try beginOperation()
        defer { operationInFlight = false }
        let before = try await activeApp()
        try checkScope(before)
        let response = try await http.request(path: "/screenshot")
        let after = try await activeApp()
        try checkSameApp(before, after)
        try checkCanContinue()
        guard let encoded = response.value.string, let data = Data(base64Encoded: encoded),
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw PhoneControlProblem(.malformedResponse, "Runner screenshot is not a base64 PNG.")
        }
        return data
    }

    /// Sends at most one screen-changing request, after fresh lookup and scope checks.
    public func act(_ action: PhoneAction) async -> PhoneActionResult {
        do {
            try beginOperation()
        } catch {
            return .unsent(Self.problem(error))
        }
        defer { operationInFlight = false }
        let observed = snapshot
        snapshot = nil
        var dispatched = false
        do {
            guard !outcomeUnknown else {
                throw PhoneControlProblem(.previousOutcomeUnknown, "A previous action has an unknown outcome. End this run and reconcile before starting another.")
            }
            let path: String
            var body: [String: JSONValue] = [:]
            switch action {
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
            case .tap(let ref), .type(let ref, _), .swipe(let ref, _):
                guard let observed, let node = observed.references[ref] else {
                    throw PhoneControlProblem(.staleObservation, "This reference is not part of the latest observation. Observe again.")
                }
                guard node.enabled else {
                    throw PhoneControlProblem(.unsupportedNode, "The observed element is disabled.")
                }
                if case .type = action {
                    let inputTypes: Set<String> = ["XCUIElementTypeTextField", "XCUIElementTypeSecureTextField",
                                                   "XCUIElementTypeTextView", "XCUIElementTypeSearchField"]
                    guard inputTypes.contains(node.type) else {
                        throw PhoneControlProblem(.unsupportedNode, "Typing requires an observed text input.")
                    }
                }
                let current = try await activeApp()
                try checkSameApp(observed.app, current)
                try checkCanContinue()
                let found = try await http.request(method: "POST", path: "/elements", body: .object([
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
                switch action {
                case .tap: path = "/element/\(elementID)/click"
                case .type(_, let text):
                    path = "/element/\(elementID)/value"
                    body["text"] = .string(text)
                case .swipe(_, let direction):
                    path = "/wda/element/\(elementID)/swipe"
                    body["direction"] = .string(direction.rawValue)
                default: preconditionFailure("Only element actions enter element lookup")
                }
            }
            try checkCanContinue()
            dispatched = true
            _ = try await http.request(method: "POST", path: path, body: .object(body))
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

    private func beginOperation() throws {
        try checkCanContinue()
        guard !operationInFlight else {
            throw PhoneControlProblem(.busy, "Another observation or action is still running.")
        }
        operationInFlight = true
    }

    private func checkCanContinue() throws {
        guard !stopped else { throw PhoneControlProblem(.stopped, "This phone-control session has stopped.") }
        try Task.checkCancellation()
    }

    private func activeApp() async throws -> ActiveApp {
        let response = try await http.request(path: "/wda/activeAppInfo")
        guard let bundleID = response.value["bundleId"]?.string, !bundleID.isEmpty,
              let pid = response.value["pid"]?.number, pid > 0, pid <= Double(Int32.max) else {
            throw PhoneControlProblem(.malformedResponse, "Runner did not identify the foreground application.")
        }
        let app = ActiveApp(bundleID: bundleID, pid: Int(pid))
        if let snapshot, snapshot.app != app { self.snapshot = nil }
        return app
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

private struct ActiveApp: Sendable, Equatable {
    let bundleID: String
    let pid: Int
}

private struct Snapshot: Sendable {
    let app: ActiveApp
    let references: [String: SourceNode]
}

private struct SourceNode: Sendable {
    let type: String
    let identifier: String?
    let label: String?
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
        value = json["value"]?.string
        rect = PhoneElementRect(x: x, y: y, width: width, height: height)
        enabled = json["isEnabled"]?.bool ?? true
        focused = json["isFocused"]?.bool ?? false
        children = try (json["children"]?.array ?? []).map(SourceNode.init)
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
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
