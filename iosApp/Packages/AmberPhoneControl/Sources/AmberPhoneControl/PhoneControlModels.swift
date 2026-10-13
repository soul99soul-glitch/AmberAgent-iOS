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

public enum PhoneAction: Sendable, Equatable {
    case launch(bundleID: String)
    case tap(ref: String)
    /// A point in the full screenshot, normalized to [0, 1) on both axes.
    /// Requires screenshot evidence attached to this latest observation.
    case tapPoint(observationID: String, x: Double, y: Double)
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
}

public struct PhoneRunnerStatus: Sendable, Equatable {
    public let ready: Bool
    public let busy: Bool
    public let sessionID: String
    public let message: String
    public let requiresAuthentication: Bool
    public let authenticationScheme: String
}

/// The result of waiting for the runner to observe a settled screen.
public struct PhoneScreenStability: Sendable, Equatable {
    public let stable: Bool
    public let waitedMs: Int
    public let frames: Int
    public let blank: Bool

    public init(stable: Bool, waitedMs: Int, frames: Int, blank: Bool) {
        self.stable = stable
        self.waitedMs = waitedMs
        self.frames = frames
        self.blank = blank
    }
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

    public init(ref: String?, depth: Int, type: String, identifier: String?, label: String?,
                value: String?, rect: PhoneElementRect, enabled: Bool, focused: Bool) {
        self.ref = ref
        self.depth = depth
        self.type = type
        self.identifier = identifier
        self.label = label
        self.value = value
        self.rect = rect
        self.enabled = enabled
        self.focused = focused
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

    public init(observationID: String, bundleID: String, processID: Int, backend: String,
                truncated: Bool, nodes: [PhoneObservationNode], screenBounds: PhoneElementRect? = nil) {
        self.observationID = observationID
        self.bundleID = bundleID
        self.processID = processID
        self.backend = backend
        self.truncated = truncated
        self.nodes = nodes
        self.screenBounds = screenBounds
    }

    /// A text UI tree for the model; screens with little useful text may need a separate screenshot.
    public var compactText: String {
        var lines = ["app=\(bundleID) pid=\(processID) observation=\(observationID) backend=\(backend) truncated=\(truncated)"]
        for node in nodes {
            let identity = node.identifier.map { " id=\(Self.quoted($0))" } ?? ""
            let label = node.label.map { " label=\(Self.quoted($0))" } ?? ""
            let value = node.value.map { " value=\(Self.quoted($0))" } ?? ""
            let role = node.type.replacingOccurrences(of: "XCUIElementType", with: "")
            let frame = "[\(node.rect.x),\(node.rect.y),\(node.rect.width),\(node.rect.height)]"
            lines.append("\(String(repeating: "  ", count: min(node.depth, 20)))\(node.ref ?? "-") \(role)\(identity)\(label)\(value) enabled=\(node.enabled) focused=\(node.focused) rect=\(frame)")
        }
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        // JSON quoting prevents UI text from introducing extra tree rows.
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
