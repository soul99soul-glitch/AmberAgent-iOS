import Foundation

public struct PhoneControlProblem: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Sendable {
        case invalidConfiguration, stopped, busy, staleObservation, appOutOfScope, appChanged
        case ambiguousElement, elementNotFound, unsupportedNode, runner, transport
        case malformedResponse, cancelled, previousOutcomeUnknown
    }

    public let kind: Kind
    public let message: String
    public let statusCode: Int?
    public let runnerCode: String?
    public let wasDroppedBeforeExecution: Bool
    public var errorDescription: String? { message }

    init(_ kind: Kind, _ message: String, statusCode: Int? = nil,
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
    /// Types into a newly resolved element. Does not clear or replace existing content.
    case type(ref: String, text: String)
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

public struct PhoneElementRect: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
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
}

public struct PhoneObservation: Sendable, Equatable {
    public let observationID: String
    public let bundleID: String
    public let processID: Int
    public let backend: String
    public let truncated: Bool
    public let nodes: [PhoneObservationNode]

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
