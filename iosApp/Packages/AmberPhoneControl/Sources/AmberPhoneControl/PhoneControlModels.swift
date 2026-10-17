import Foundation

public struct PhoneControlProblem: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Sendable {
        case invalidConfiguration, invalidAction, stopped, busy, staleObservation, appOutOfScope, appChanged
        case ambiguousElement, elementNotFound, unsupportedNode, runner, transport
        case malformedResponse, cancelled, previousOutcomeUnknown
    }

    public let kind: Kind
    public let message: String
    public let statusCode: Int?
    public let runnerCode: String?
    public let wasDroppedBeforeExecution: Bool
    public var errorDescription: String? { message }

    public init(_ kind: Kind, _ message: String, statusCode: Int? = nil,
         runnerCode: String? = nil, wasDroppedBeforeExecution: Bool = false) {
        self.kind = kind
        self.message = message
        self.statusCode = statusCode
        self.runnerCode = runnerCode
        self.wasDroppedBeforeExecution = wasDroppedBeforeExecution
    }
}

public enum PhoneActionResult: Sendable, Equatable {
    /// No screen-changing request was dispatched, or the runner explicitly refused it before execution.
    case unsent(PhoneControlProblem)
    /// The runner acknowledged execution. Observe again to verify the intended application effect.
    case completed
    /// A screen-changing request may have executed. This client blocks further actions.
    case unknown(PhoneControlProblem)
}

public enum PhoneSwipeDirection: String, Sendable, CaseIterable {
    case up, down, left, right
}

/// Visual quiet is an observation aid, not evidence that an action achieved its goal.
public struct PhoneScreenStability: Sendable, Encodable, Equatable {
    public let stable: Bool
    public let blank: Bool?
    public let waitedMs: Double
    public let frames: Int
    public let changedPixels: Int
    public let captureMs: Double
    public let budgetMs: Int

    public init(stable: Bool, blank: Bool?, waitedMs: Double, frames: Int,
                changedPixels: Int, captureMs: Double, budgetMs: Int) {
        self.stable = stable
        self.blank = blank
        self.waitedMs = waitedMs
        self.frames = frames
        self.changedPixels = changedPixels
        self.captureMs = captureMs
        self.budgetMs = budgetMs
    }
}

/// Numeric, operation-local diagnostics. It deliberately excludes request bodies and UI content.
public struct PhoneOperationDiagnostics: Sendable, Encodable, Equatable {
    public enum Operation: String, Sendable, Encodable {
        case observe, action, screenshot
    }

    public let operation: Operation
    public let durationMs: Double
    public let requests: [PhoneRunnerRequestTiming]
    public var httpRequestCount: Int { requests.count }

    public init(operation: Operation, durationMs: Double, requests: [PhoneRunnerRequestTiming]) {
        self.operation = operation
        self.durationMs = durationMs
        self.requests = requests
    }

    private enum CodingKeys: CodingKey { case operation, durationMs, httpRequestCount, requests }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(operation, forKey: .operation)
        try value.encode(durationMs, forKey: .durationMs)
        try value.encode(httpRequestCount, forKey: .httpRequestCount)
        try value.encode(requests, forKey: .requests)
    }
}

public struct PhoneRunnerRequestTiming: Sendable, Encodable, Equatable {
    public enum Stage: String, Sendable, Encodable {
        case activeApp, settle, source, screenSize, screenshot, elementLookup, action
    }

    public let stage: Stage
    /// Client-side duration, including transport and response decoding.
    public let durationMs: Double
    /// Runner headers, when supplied. Server-Timing includes the runner's queue wait.
    public let runnerMs: Double?
    public let queuedMs: Double?
    /// The runner's own phases of at least 20 ms (`X-IPU-<phase>-Ms`, e.g. Island, Covered,
    /// HitTest), so a slow observation shows where its time went.
    public let runnerPhasesMs: [String: Double]?

    public init(stage: Stage, durationMs: Double, runnerMs: Double?, queuedMs: Double?,
                runnerPhasesMs: [String: Double]? = nil) {
        self.stage = stage
        self.durationMs = durationMs
        self.runnerMs = runnerMs
        self.queuedMs = queuedMs
        self.runnerPhasesMs = runnerPhasesMs
    }
}

public enum PhoneAction: Sendable, Equatable {
    case launch(bundleID: String)
    case tap(ref: String)
    case longPress(ref: String, durationMs: Int)
    /// An exact button reference inside the latest observed alert, guarded by its full context.
    case tapAlert(ref: String)
    /// A point in the full screenshot, normalized to [0, 1) on both axes.
    /// Requires screenshot evidence attached to this latest observation.
    case tapPoint(observationID: String, x: Double, y: Double)
    case longPressPoint(observationID: String, x: Double, y: Double, durationMs: Int)
    /// Finger movement between distinct full-screenshot points, normalized to [0, 1).
    /// Requires screenshot evidence attached to this latest observation.
    case swipePoint(observationID: String, startX: Double, startY: Double, endX: Double, endY: Double)
    /// Types into a newly resolved element. Does not clear or replace existing content.
    case type(ref: String, text: String)
    /// Clears a newly resolved nonsecure text input. Observe again before typing replacement text.
    case clear(ref: String)
    /// Direction describes the finger movement, not the content movement.
    case swipe(ref: String, direction: PhoneSwipeDirection)
    case home
    /// 收起屏幕键盘：输入完成后键盘与候选栏会遮住底部控件，且遮挡后坐标失效。
    case dismissKeyboard
}

public struct PhoneRunnerStatus: Sendable, Equatable {
    public let ready: Bool
    public let busy: Bool
    public let sessionID: String
    public let message: String
    public let requiresAuthentication: Bool
    public let authenticationScheme: String
}

public struct PhoneScreenshot: Sendable, Equatable {
    public let data: Data
    public let observationID: String
    /// Full screen dimensions in points, not screenshot pixels or an accessibility node's frame.
    public let width: Double
    public let height: Double

    public init(data: Data, observationID: String, width: Double, height: Double) {
        self.data = data
        self.observationID = observationID
        self.width = width
        self.height = height
    }
}

public struct PhoneElementRect: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PhoneObservationNode: Sendable, Equatable {
    /// Local to one observation, not a WebDriver element ID.
    public let ref: String?
    public let depth: Int
    public let type: String
    public let identifier: String?
    public let label: String?
    public let value: String?
    public let rect: PhoneElementRect
    public let enabled: Bool
    public let focused: Bool
    /// On a page hidden under a pushed page: still in the accessibility tree, not on screen.
    /// Covered nodes carry no ref, so no action can target them.
    public let covered: Bool

    public init(ref: String?, depth: Int, type: String, identifier: String?, label: String?,
                value: String?, rect: PhoneElementRect, enabled: Bool, focused: Bool, covered: Bool = false) {
        self.ref = ref
        self.depth = depth
        self.type = type
        self.identifier = identifier
        self.label = label
        self.value = value
        self.rect = rect
        self.enabled = enabled
        self.focused = focused
        self.covered = covered
    }
}

public struct PhoneObservedAlertButton: Sendable, Encodable, Equatable {
    public let ref: String?
    public let name: String

    public init(ref: String?, name: String) {
        self.ref = ref
        self.name = name
    }
}

public struct PhoneObservedAlert: Sendable, Encodable, Equatable {
    public let ref: String?
    public let text: String
    public let processID: Int
    public let buttons: [PhoneObservedAlertButton]

    public init(ref: String?, text: String, processID: Int, buttons: [PhoneObservedAlertButton]) {
        self.ref = ref
        self.text = text
        self.processID = processID
        self.buttons = buttons
    }
}

public struct PhoneObservation: Sendable, Equatable {
    public let observationID: String
    public let bundleID: String
    public let processID: Int
    public let backend: String
    public let truncated: Bool
    public let nodes: [PhoneObservationNode]
    /// Real screen geometry from /window/size, independent of the accessibility root frame.
    public let screenBounds: PhoneElementRect?
    public let screenStability: PhoneScreenStability?
    public let diagnostics: PhoneOperationDiagnostics?
    public let alerts: [PhoneObservedAlert]
    public let alertActionsSupported: Bool

    public init(observationID: String, bundleID: String, processID: Int, backend: String,
                truncated: Bool, nodes: [PhoneObservationNode], screenBounds: PhoneElementRect? = nil,
                screenStability: PhoneScreenStability? = nil, diagnostics: PhoneOperationDiagnostics? = nil,
                alerts: [PhoneObservedAlert] = [], alertActionsSupported: Bool = false) {
        self.observationID = observationID
        self.bundleID = bundleID
        self.processID = processID
        self.backend = backend
        self.truncated = truncated
        self.nodes = nodes
        self.screenBounds = screenBounds
        self.screenStability = screenStability
        self.diagnostics = diagnostics
        self.alerts = alerts
        self.alertActionsSupported = alertActionsSupported
    }

    /// A text UI tree for the model; screens with little useful text may need a separate screenshot.
    public var compactText: String {
        let containers: Set<String> = ["XCUIElementTypeApplication", "XCUIElementTypeWindow",
                                       "XCUIElementTypeOther", "XCUIElementTypeGroup"]
        let visibleNodes = nodes.filter { node in
            guard !node.covered else { return false }
            let hasText = [node.identifier, node.label, node.value].contains { !($0 ?? "").isEmpty }
            return hasText || !containers.contains(node.type) || !node.enabled || node.focused
        }
        let covered = nodes.filter(\.covered).count
        var lines = ["app=\(bundleID) pid=\(processID) observation=\(observationID) backend=\(backend) truncated=\(truncated) nodes=\(nodes.count) displayed=\(visibleNodes.count) omitted=\(nodes.count - visibleNodes.count)"
            + (covered > 0 ? " covered=\(covered) (a page hidden under the visible one; its elements are not on screen)" : "")]
        for node in visibleNodes {
            let identity = node.identifier.map { " id=\(Self.quoted($0))" } ?? ""
            let label = node.label.map { " label=\(Self.quoted($0))" } ?? ""
            let value = node.value.map { " value=\(Self.quoted($0))" } ?? ""
            let role = node.type.replacingOccurrences(of: "XCUIElementType", with: "")
            let frame = "[\(node.rect.x),\(node.rect.y),\(node.rect.width),\(node.rect.height)]"
            let flags = (node.enabled ? "" : " enabled=false") + (node.focused ? " focused=true" : "")
            lines.append("\(String(repeating: "  ", count: min(node.depth, 20)))\(node.ref ?? "-") \(role)\(identity)\(label)\(value)\(flags) rect=\(frame)")
        }
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        // JSON quoting prevents UI text from introducing extra tree rows.
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
