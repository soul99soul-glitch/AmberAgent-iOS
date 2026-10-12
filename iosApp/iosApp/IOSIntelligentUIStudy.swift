import Foundation

struct IOSIntelligentUIStudyDefinition: Codable, Equatable, Sendable {
    struct Choice: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let label: String
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let prompt: String
        let answer: String
        let detail: String?
        let options: [Choice]?
        let correctOptionID: String?

        enum CodingKeys: String, CodingKey {
            case id, prompt, answer, detail, options
            case correctOptionID = "correct_option_id"
        }
    }

    let items: [Item]
    var quizItems: [Item] { items.filter { !($0.options ?? []).isEmpty } }

    func validate() throws {
        guard (2...40).contains(items.count) else { throw studyIssue("学习项目必须为 2 至 40 项。") }
        guard Set(items.map(\.id)).count == items.count else { throw studyIssue("学习项目 id 重复。") }
        for item in items { try Self.validate(item) }
    }

    static func validate(_ item: Item) throws {
        try validateID(item.id)
        try validateText(item.prompt, maximum: 1_000)
        try validateText(item.answer, maximum: 2_000)
        if let detail = item.detail { try validateText(detail, maximum: 4_000) }
        if let choices = item.options {
            guard (2...8).contains(choices.count), Set(choices.map(\.id)).count == choices.count else {
                throw studyIssue("学习题目选项必须为 2 至 8 个，且 id 不重复。")
            }
            guard let correct = item.correctOptionID, choices.contains(where: { $0.id == correct }) else {
                throw studyIssue("学习题目的正确选项必须引用现有选项 id。")
            }
            for choice in choices {
                try validateID(choice.id)
                try validateText(choice.label, maximum: 300)
            }
        } else if item.correctOptionID != nil {
            throw studyIssue("没有选择题选项时不能声明正确选项。")
        }
    }

    private static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 80,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw studyIssue("学习项目和选项 id 必须为稳定 ASCII 标识。")
        }
    }

    private static func validateText(_ value: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= maximum else {
            throw studyIssue("学习文本不能为空，且不得超过 \(maximum) 个字符。")
        }
    }
}

/// Local study interactions do not call the model. The draft owns this session;
/// explicit task submission sends its summary, never the private storage field.
struct IOSIntelligentUIStudySession: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case review, quiz }
    struct Feedback: Equatable, Sendable {
        let selectedOptionID: String
        let correctOptionID: String
        let isCorrect: Bool
    }
    struct Summary: Codable, Equatable, Sendable {
        let answeredCount: Int
        let correctCount: Int
        let totalQuizCount: Int
        let incorrectItemIDs: [String]
        let mode: Mode
        let currentItemID: String
        let answerRevealed: Bool

        var promptSummary: String {
            var text = "\(mode == .review ? "翻卡复习" : "选择题练习")，当前项目 \(currentItemID)，\(answerRevealed ? "已查看答案" : "尚未查看答案")。已答 \(answeredCount)/\(totalQuizCount) 题，答对 \(correctCount) 题。"
            if !incorrectItemIDs.isEmpty {
                text += "错题项目：\(incorrectItemIDs.prefix(12).joined(separator: "、"))。"
                if incorrectItemIDs.count > 12 { text += "另有 \(incorrectItemIDs.count - 12) 项错题。" }
            }
            return text
        }
    }

    static let storageKey = "__study_session"
    private(set) var mode: Mode = .review
    private(set) var index = 0
    private(set) var revealed = false
    private(set) var answers: [String: String] = [:]

    init() {}

    static func restore(_ raw: String?, definition: IOSIntelligentUIStudyDefinition) throws -> Self {
        try definition.validate()
        guard let raw else { return Self() }
        guard raw.utf8.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              Set(object.keys) == Set(["mode", "index", "revealed", "answers"]) else {
            throw studyIssue("学习进度格式无效，请重新开始本轮练习。")
        }
        let session: Self
        do { session = try JSONDecoder().decode(Self.self, from: Data(raw.utf8)) }
        catch { throw studyIssue("学习进度格式无效，请重新开始本轮练习。") }
        try session.validate(definition: definition)
        return session
    }

    func encodedValue() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func currentItem(definition: IOSIntelligentUIStudyDefinition) -> IOSIntelligentUIStudyDefinition.Item {
        items(definition: definition)[index]
    }

    func canGoNext(definition: IOSIntelligentUIStudyDefinition) -> Bool {
        index + 1 < items(definition: definition).count
    }

    func feedback(definition: IOSIntelligentUIStudyDefinition) -> Feedback? {
        guard mode == .quiz else { return nil }
        let item = currentItem(definition: definition)
        guard let selected = answers[item.id], let correct = item.correctOptionID else { return nil }
        return Feedback(selectedOptionID: selected, correctOptionID: correct, isCorrect: selected == correct)
    }

    mutating func setMode(_ nextMode: Mode, definition: IOSIntelligentUIStudyDefinition) throws {
        try validate(definition: definition)
        guard nextMode != .quiz || !definition.quizItems.isEmpty else { throw studyIssue("本组卡片没有选择题，请使用翻卡复习。") }
        guard mode != nextMode else { return }
        mode = nextMode
        index = 0
        revealed = mode == .quiz && answers[currentItem(definition: definition).id] != nil
    }

    mutating func reveal(definition: IOSIntelligentUIStudyDefinition) throws {
        try validate(definition: definition)
        guard mode == .review else { throw studyIssue("请先作答，再查看答案。") }
        revealed = true
    }

    mutating func answer(optionID: String, definition: IOSIntelligentUIStudyDefinition) throws {
        try validate(definition: definition)
        guard mode == .quiz else { throw studyIssue("请先切换到选择题练习。") }
        let item = currentItem(definition: definition)
        guard item.options?.contains(where: { $0.id == optionID }) == true else { throw studyIssue("所选答案不在当前题目中。") }
        guard answers[item.id] == nil else { throw studyIssue("本题已作答；重新练习后可以再次作答。") }
        answers[item.id] = optionID
        revealed = true
    }

    mutating func next(definition: IOSIntelligentUIStudyDefinition) throws {
        try validate(definition: definition)
        guard canGoNext(definition: definition) else { throw studyIssue("已到本轮最后一项。") }
        index += 1
        revealed = mode == .quiz && answers[currentItem(definition: definition).id] != nil
    }

    mutating func reset(definition: IOSIntelligentUIStudyDefinition) throws {
        try definition.validate()
        if mode == .quiz && definition.quizItems.isEmpty { mode = .review }
        index = 0
        revealed = false
        answers = [:]
    }

    func summary(definition: IOSIntelligentUIStudyDefinition) -> Summary {
        let incorrect = definition.quizItems.filter { item in
            guard let answer = answers[item.id] else { return false }
            return answer != item.correctOptionID
        }.map(\.id)
        return Summary(answeredCount: answers.count, correctCount: answers.count - incorrect.count,
                       totalQuizCount: definition.quizItems.count, incorrectItemIDs: incorrect,
                       mode: mode, currentItemID: currentItem(definition: definition).id, answerRevealed: revealed)
    }

    private func items(definition: IOSIntelligentUIStudyDefinition) -> [IOSIntelligentUIStudyDefinition.Item] {
        mode == .review ? definition.items : definition.quizItems
    }

    private func validate(definition: IOSIntelligentUIStudyDefinition) throws {
        try definition.validate()
        let currentItems = items(definition: definition)
        guard currentItems.indices.contains(index) else { throw studyIssue("学习进度超出当前卡片范围。") }
        for (itemID, answerID) in answers {
            guard let item = definition.quizItems.first(where: { $0.id == itemID }),
                  item.options?.contains(where: { $0.id == answerID }) == true else {
                throw studyIssue("学习进度包含不属于当前题目的答案。")
            }
        }
        if mode == .quiz, revealed != (answers[currentItems[index].id] != nil) {
            throw studyIssue("未作答的题目不能提前展示答案。")
        }
    }
}

private func studyIssue(_ reason: String) -> IOSIntelligentUIProtocolError {
    IOSIntelligentUIProtocolError(reason: reason)
}
