import Foundation

struct IOSPhoneGoalTarget: Codable, Equatable, Sendable {
    let label: String?
    let identifier: String?
    let type: String?

    init(label: String? = nil, identifier: String? = nil, type: String? = nil) {
        self.label = label
        self.identifier = identifier
        self.type = type
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

struct IOSPhoneGoalRequest: Codable, Equatable, Sendable {
    let goal: String
    let bundleID: String
    let actions: [IOSPhoneGoalActionSpec]
    let completion: IOSPhoneGoalExpectation
    let maxSteps: Int

    enum CodingKeys: String, CodingKey {
        case goal, actions, completion
        case bundleID = "bundle_id"
        case maxSteps = "max_steps"
    }

    init(goal: String, bundleID: String, actions: [IOSPhoneGoalActionSpec],
         completion: IOSPhoneGoalExpectation, maxSteps: Int = 6) {
        self.goal = goal
        self.bundleID = bundleID
        self.actions = actions
        self.completion = completion
        self.maxSteps = maxSteps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = try container.decode(String.self, forKey: .goal)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        actions = try container.decode([IOSPhoneGoalActionSpec].self, forKey: .actions)
        completion = try container.decode(IOSPhoneGoalExpectation.self, forKey: .completion)
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 6
    }

    func validate() throws {
        try IOSPhoneGoalValidationError.requireText(goal, maximum: 1_000, field: "goal")
        try IOSPhoneGoalValidationError.requireText(bundleID, maximum: 255, field: "bundle_id")
        guard bundleID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw IOSPhoneGoalValidationError.invalid("bundle_id cannot contain whitespace.")
        }
        guard (1...12).contains(actions.count), (1...12).contains(maxSteps) else {
            throw IOSPhoneGoalValidationError.invalid("A goal needs 1–12 candidate actions and max_steps must be 1–12.")
        }
        for (index, action) in actions.enumerated() {
            try action.validate()
            guard !actions[..<index].contains(action) else {
                throw IOSPhoneGoalValidationError.invalid("Candidate actions cannot contain identical duplicates.")
            }
        }
        try completion.validate()
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
