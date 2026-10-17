import Foundation

struct IOSPhoneGoalRegion: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func validate() throws {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite),
              (0..<1).contains(x), (0..<1).contains(y),
              width > 0, width <= 1, height > 0, height <= 1,
              x + width <= 1, y + height <= 1 else {
            throw IOSPhoneGoalValidationError.invalid(
                "target region must be a finite rectangle inside normalized screen bounds."
            )
        }
    }
}

struct IOSPhoneGoalTarget: Codable, Equatable, Sendable {
    let label: String?
    let identifier: String?
    let type: String?
    let region: IOSPhoneGoalRegion?

    init(label: String? = nil, identifier: String? = nil, type: String? = nil,
         region: IOSPhoneGoalRegion? = nil) {
        self.label = label
        self.identifier = identifier
        self.type = type
        self.region = region
    }

    func validate() throws {
        guard label != nil || identifier != nil else {
            throw IOSPhoneGoalValidationError.invalid("A target needs an exact label or identifier.")
        }
        for value in [label, identifier].compactMap({ $0 }) {
            try IOSPhoneGoalValidationError.requireText(value, maximum: 512, field: "target label/identifier")
        }
        if let type {
            try IOSPhoneGoalValidationError.requireText(type, maximum: 128, field: "target type")
        }
        try region?.validate()
    }
}

struct IOSPhoneGoalExpectation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case visible, enabled, absent
        case valueEquals = "value_equals"
    }

    let kind: Kind
    let target: IOSPhoneGoalTarget
    let value: String?
    let anchor: IOSPhoneGoalTarget?

    init(kind: Kind, target: IOSPhoneGoalTarget, value: String? = nil, anchor: IOSPhoneGoalTarget? = nil) {
        self.kind = kind
        self.target = target
        self.value = value
        self.anchor = anchor
    }

    func validate() throws {
        try target.validate()
        switch kind {
        case .visible, .enabled:
            guard value == nil, anchor == nil else {
                throw IOSPhoneGoalValidationError.invalid("\(kind.rawValue) accepts only a target.")
            }
        case .absent:
            guard value == nil, let anchor, anchor != target else {
                throw IOSPhoneGoalValidationError.invalid("absent needs a distinct visible anchor and no value.")
            }
            try anchor.validate()
        case .valueEquals:
            guard let value, value.count <= 4_000, anchor == nil else {
                throw IOSPhoneGoalValidationError.invalid("value_equals needs a value of at most 4000 characters and no anchor.")
            }
        }
    }
}

struct IOSPhoneGoalActionSpec: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case tap, type, swipe }
    enum Direction: String, Codable, Sendable { case up, down, left, right }

    let action: Action
    let target: IOSPhoneGoalTarget
    let text: String?
    let direction: Direction?

    init(action: Action, target: IOSPhoneGoalTarget, text: String? = nil, direction: Direction? = nil) {
        self.action = action
        self.target = target
        self.text = text
        self.direction = direction
    }

    func validate() throws {
        try target.validate()
        switch action {
        case .tap:
            guard text == nil, direction == nil else {
                throw IOSPhoneGoalValidationError.invalid("tap accepts only a target.")
            }
        case .type:
            guard let text, direction == nil else {
                throw IOSPhoneGoalValidationError.invalid("type needs text and does not accept a direction.")
            }
            try IOSPhoneGoalValidationError.requireText(text, maximum: 4_000, field: "text")
        case .swipe:
            guard direction != nil, text == nil else {
                throw IOSPhoneGoalValidationError.invalid("swipe needs a direction and does not accept text.")
            }
        }
    }
}

struct IOSPhoneSequenceStep: Codable, Equatable, Sendable {
    let pageAnchor: IOSPhoneGoalTarget
    let actions: [IOSPhoneGoalActionSpec]
    let expectation: IOSPhoneGoalExpectation
    let waitForStability: Bool

    enum CodingKeys: String, CodingKey {
        case actions, expectation
        case pageAnchor = "page_anchor"
        case waitForStability = "wait_for_stability"
    }

    init(pageAnchor: IOSPhoneGoalTarget, actions: [IOSPhoneGoalActionSpec],
         expectation: IOSPhoneGoalExpectation, waitForStability: Bool = false) {
        self.pageAnchor = pageAnchor
        self.actions = actions
        self.expectation = expectation
        self.waitForStability = waitForStability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageAnchor = try container.decode(IOSPhoneGoalTarget.self, forKey: .pageAnchor)
        actions = try container.decode([IOSPhoneGoalActionSpec].self, forKey: .actions)
        expectation = try container.decode(IOSPhoneGoalExpectation.self, forKey: .expectation)
        waitForStability = try container.decodeIfPresent(Bool.self, forKey: .waitForStability) ?? false
    }

    func validate() throws {
        try pageAnchor.validate()
        try IOSPhoneGoalRequest.validateActions(actions)
        try expectation.validate()
    }
}

struct IOSPhoneGoalRequest: Codable, Equatable, Sendable {
    /// Action budget per invocation. A liveness heartbeat keeps long goal runs alive,
    /// so the loop's own 180-second budget is the effective bound.
    static let defaultMaxSteps = 15
    static let maximumSteps = 30

    let goal: String
    let bundleID: String
    let actions: [IOSPhoneGoalActionSpec]
    let steps: [IOSPhoneSequenceStep]?
    let completion: IOSPhoneGoalExpectation
    let maxSteps: Int
    let usesLiveCandidates: Bool

    enum CodingKeys: String, CodingKey {
        case goal, actions, steps, completion
        case bundleID = "bundle_id"
        case maxSteps = "max_steps"
    }

    init(goal: String, bundleID: String, actions: [IOSPhoneGoalActionSpec],
         completion: IOSPhoneGoalExpectation, maxSteps: Int = IOSPhoneGoalRequest.defaultMaxSteps) {
        self.goal = goal
        self.bundleID = bundleID
        self.actions = actions
        self.steps = nil
        self.completion = completion
        self.maxSteps = maxSteps
        self.usesLiveCandidates = false
    }

    init(goal: String, bundleID: String, steps: [IOSPhoneSequenceStep],
         completion: IOSPhoneGoalExpectation, maxSteps: Int? = nil) {
        self.goal = goal
        self.bundleID = bundleID
        self.actions = []
        self.steps = steps
        self.completion = completion
        self.maxSteps = maxSteps ?? Self.defaultMaxSteps(for: steps)
        self.usesLiveCandidates = false
    }

    init(goal: String, bundleID: String, completion: IOSPhoneGoalExpectation,
         maxSteps: Int = IOSPhoneGoalRequest.defaultMaxSteps) {
        self.goal = goal
        self.bundleID = bundleID
        self.actions = []
        self.steps = nil
        self.completion = completion
        self.maxSteps = maxSteps
        self.usesLiveCandidates = true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = try container.decode(String.self, forKey: .goal)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        steps = try container.decodeIfPresent([IOSPhoneSequenceStep].self, forKey: .steps)
        actions = try container.decodeIfPresent([IOSPhoneGoalActionSpec].self, forKey: .actions) ?? []
        completion = try container.decode(IOSPhoneGoalExpectation.self, forKey: .completion)
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps)
            ?? steps.map(Self.defaultMaxSteps(for:)) ?? Self.defaultMaxSteps
        usesLiveCandidates = !container.contains(.actions) && !container.contains(.steps)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(goal, forKey: .goal)
        try container.encode(bundleID, forKey: .bundleID)
        if let steps { try container.encode(steps, forKey: .steps) }
        else if !usesLiveCandidates { try container.encode(actions, forKey: .actions) }
        try container.encode(completion, forKey: .completion)
        try container.encode(maxSteps, forKey: .maxSteps)
    }

    func validate() throws {
        try IOSPhoneGoalValidationError.requireText(goal, maximum: 1_000, field: "goal")
        try IOSPhoneGoalValidationError.requireText(bundleID, maximum: 255, field: "bundle_id")
        guard bundleID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw IOSPhoneGoalValidationError.invalid("bundle_id cannot contain whitespace.")
        }
        guard (1...Self.maximumSteps).contains(maxSteps) else {
            throw IOSPhoneGoalValidationError.invalid("max_steps must be 1–\(Self.maximumSteps).")
        }
        if let steps {
            guard actions.isEmpty, (1...12).contains(steps.count) else {
                throw IOSPhoneGoalValidationError.invalid("Provide either actions or 1–12 ordered steps.")
            }
            for step in steps { try step.validate() }
        } else if !usesLiveCandidates {
            try Self.validateActions(actions)
        }
        try completion.validate()
    }

    /// Ordered steps keep room for in-call recovery when the screen deviates from the plan.
    static func defaultMaxSteps(for steps: [IOSPhoneSequenceStep]) -> Int {
        min(maximumSteps, max(steps.count, defaultMaxSteps))
    }

    static func validateActions(_ actions: [IOSPhoneGoalActionSpec]) throws {
        guard (1...12).contains(actions.count) else {
            throw IOSPhoneGoalValidationError.invalid("Provide 1–12 candidate actions.")
        }
        for (index, action) in actions.enumerated() {
            try action.validate()
            guard !actions[..<index].contains(action) else {
                throw IOSPhoneGoalValidationError.invalid("Candidate actions cannot contain identical duplicates.")
            }
        }
    }
}

enum IOSPhoneGoalValidationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }

    static func requireText(_ value: String, maximum: Int, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= maximum else {
            throw Self.invalid("\(field) must contain 1–\(maximum) characters.")
        }
    }
}
