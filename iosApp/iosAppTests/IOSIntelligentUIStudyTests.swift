import XCTest
@testable import iosApp

@MainActor
final class IOSIntelligentUIStudyTests: XCTestCase {
    func testStudyWithoutDecisionQuestionOrOptionsDecodesAndRoundTrips() throws {
        let card = try studyCard()
        XCTAssertEqual(card.kind, "study")
        XCTAssertEqual(card.question, "")
        XCTAssertEqual(card.options, [])
        XCTAssertEqual(card.study?.items.count, 2)
        XCTAssertEqual(card.study?.items.first?.correctOptionID, "yuanzhang")
        let encoded = try JSONEncoder().encode(card)
        XCTAssertEqual(try IOSIntelligentUIProtocol.decode(String(decoding: encoded, as: UTF8.self)), card)
    }

    func testStudyRejectsUnknownNestedFieldsAndInvalidCorrectAnswerReferences() throws {
        for scope in ["root", "item", "choice"] {
            var object = try studyObject()
            var study = try XCTUnwrap(object["study"] as? [String: Any])
            var items = try XCTUnwrap(study["items"] as? [[String: Any]])
            if scope == "root" { study["execute"] = "javascript" }
            if scope == "item" { items[0]["callback"] = "javascript" }
            if scope == "choice" {
                var choices = try XCTUnwrap(items[0]["options"] as? [[String: Any]])
                choices[0]["action"] = "run"
                items[0]["options"] = choices
            }
            study["items"] = items
            object["study"] = study
            XCTAssertThrowsError(try decode(object), scope)
        }
        var object = try studyObject()
        var study = try XCTUnwrap(object["study"] as? [String: Any])
        var items = try XCTUnwrap(study["items"] as? [[String: Any]])
        items[0]["correct_option_id"] = "not-an-option"
        study["items"] = items
        object["study"] = study
        XCTAssertThrowsError(try decode(object))
    }

    func testStudyRequiresFiniteUniqueItemsAndChoices() throws {
        let original = try studyObject()
        for mutation in ["too-few", "too-many", "duplicate-item", "duplicate-choice", "missing-correct"] {
            var object = original
            var study = try XCTUnwrap(object["study"] as? [String: Any])
            var items = try XCTUnwrap(study["items"] as? [[String: Any]])
            switch mutation {
            case "too-few": items = [items[0]]
            case "too-many": items = Array(repeating: items[0], count: 41)
            case "duplicate-item": items[1]["id"] = items[0]["id"]
            case "duplicate-choice":
                var choices = try XCTUnwrap(items[0]["options"] as? [[String: Any]])
                choices[1]["id"] = choices[0]["id"]
                items[0]["options"] = choices
            default: items[0].removeValue(forKey: "correct_option_id")
            }
            study["items"] = items
            object["study"] = study
            XCTAssertThrowsError(try decode(object), mutation)
        }
    }

    func testReviewOnlyItemsNeverOfferAutomaticTextScoring() throws {
        var object = try studyObject()
        var study = try XCTUnwrap(object["study"] as? [String: Any])
        var items = try XCTUnwrap(study["items"] as? [[String: Any]])
        for index in items.indices {
            items[index].removeValue(forKey: "options")
            items[index].removeValue(forKey: "correct_option_id")
        }
        study["items"] = items
        object["study"] = study
        let definition = try XCTUnwrap(decode(object).study)
        var session = IOSIntelligentUIStudySession()
        XCTAssertNil(session.feedback(definition: definition))
        XCTAssertThrowsError(try session.setMode(.quiz, definition: definition))
        XCTAssertThrowsError(try session.answer(optionID: "free-text", definition: definition))
        XCTAssertEqual(session.summary(definition: definition).answeredCount, 0)
        try session.reveal(definition: definition)
        XCTAssertTrue(session.revealed)
    }

    func testNonDecisionSubmissionsDoNotInventASelectedOption() throws {
        for kind in ["form", "explore", "study"] {
            let card: IOSIntelligentUICardDefinition
            if kind == "study" { card = try studyCard() }
            else {
                card = .init(cardID: "input", kind: kind, goal: "补充行程信息",
                             fields: [.init(id: "destination", label: "目的地", required: true, placeholder: nil, type: nil)],
                             submit: .init(label: "继续", intent: "continue"))
            }
            try IOSIntelligentUIProtocol.validate(card)
            let store = IOSIntelligentUIStateStore()
            let source = source(cardID: card.cardID)
            try store.update(source: source, definition: card, selectedOptionID: nil, values: ["destination": "杭州"])
            let submission = try IOSIntelligentUISubmission(source: source, definition: card, draft: store.draft(for: source, definition: card))
            XCTAssertNil(submission.option)
            XCTAssertEqual(submission.taskKind, kind)
            XCTAssertFalse(submission.prompt().contains("所选方案"))
            XCTAssertTrue(submission.prompt().contains("任务："))
            if kind != "study" { XCTAssertEqual(submission.inputs.first?.value, "杭州") }
        }
    }

    func testDecisionStillRequiresSelectionAndKeepsOldReceiptAndPrompt() throws {
        let card = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.exampleJSON)
        let store = IOSIntelligentUIStateStore()
        let source = source(cardID: card.cardID)
        store.register(source: source, definition: card)
        XCTAssertThrowsError(try IOSIntelligentUISubmission(source: source, definition: card, draft: store.draft(for: source, definition: card)))
        try store.update(source: source, definition: card, selectedOptionID: "native", values: [:])
        let receipt = try IOSIntelligentUISubmission(source: source, definition: card, draft: store.draft(for: source, definition: card))
        XCTAssertNil(receipt.taskKind)
        XCTAssertNil(receipt.studySummary)
        XCTAssertTrue(receipt.prompt().hasPrefix("【任务卡选择】\n任务："))
        XCTAssertTrue(receipt.prompt().contains("所选方案：原生任务卡"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        object.removeValue(forKey: "taskKind")
        object.removeValue(forKey: "studySummary")
        XCTAssertEqual(try JSONDecoder().decode(IOSIntelligentUISubmission.self, from: JSONSerialization.data(withJSONObject: object)), receipt)
        let encodedDefinition = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        XCTAssertNil(encodedDefinition["study"], "Old definition fingerprints must not gain a null study field")
    }

    func testQuizHidesFeedbackUntilAnswerAndPreservesFirstAnswer() throws {
        let definition = try XCTUnwrap(studyCard().study)
        var session = IOSIntelligentUIStudySession()
        try session.setMode(.quiz, definition: definition)
        XCTAssertFalse(session.revealed)
        XCTAssertNil(session.feedback(definition: definition))
        XCTAssertThrowsError(try session.reveal(definition: definition))
        XCTAssertThrowsError(try session.answer(optionID: "invalid", definition: definition))
        try session.answer(optionID: "di", definition: definition)
        XCTAssertEqual(session.feedback(definition: definition)?.isCorrect, false)
        XCTAssertTrue(session.revealed)
        XCTAssertThrowsError(try session.answer(optionID: "yuanzhang", definition: definition))
        XCTAssertEqual(session.answers["hongwu"], "di")
        try session.next(definition: definition)
        XCTAssertFalse(session.revealed)
        try session.answer(optionID: "di", definition: definition)
        XCTAssertEqual(session.feedback(definition: definition)?.isCorrect, true)
        XCTAssertEqual(session.summary(definition: definition).correctCount, 1)
        XCTAssertEqual(session.summary(definition: definition).incorrectItemIDs, ["hongwu"])
        XCTAssertFalse(session.canGoNext(definition: definition))
        XCTAssertThrowsError(try session.next(definition: definition))
    }

    func testModeSwitchPreservesAnswersButResetStartsANewRound() throws {
        let definition = try XCTUnwrap(studyCard().study)
        var session = IOSIntelligentUIStudySession()
        try session.reveal(definition: definition)
        try session.next(definition: definition)
        XCTAssertFalse(session.revealed)
        try session.setMode(.quiz, definition: definition)
        try session.answer(optionID: "yuanzhang", definition: definition)
        try session.setMode(.review, definition: definition)
        XCTAssertFalse(session.revealed)
        XCTAssertNil(session.feedback(definition: definition))
        try session.setMode(.quiz, definition: definition)
        XCTAssertTrue(session.revealed)
        XCTAssertEqual(session.answers.count, 1)
        try session.reset(definition: definition)
        XCTAssertEqual(session.mode, .quiz)
        XCTAssertEqual(session.index, 0)
        XCTAssertFalse(session.revealed)
        XCTAssertEqual(session.answers, [:])
    }

    func testCorruptSessionCannotRevealUnansweredQuizOrDamageDraft() throws {
        let card = try studyCard()
        let definition = try XCTUnwrap(card.study)
        let badValues = [
            #"{"mode":"quiz","index":0,"revealed":true,"answers":{}}"#,
            #"{"mode":"review","index":-1,"revealed":false,"answers":{}}"#,
            #"{"mode":"review","index":5,"revealed":false,"answers":{}}"#,
            #"{"mode":"quiz","index":0,"revealed":false,"answers":{"missing":"di"}}"#,
            #"{"mode":"quiz","index":0,"revealed":true,"answers":{"hongwu":"invalid"}}"#,
            #"{"mode":"review","index":0,"revealed":false,"answers":{},"tool":"run"}"#,
            "not-json"
        ]
        let store = IOSIntelligentUIStateStore()
        let source = source(cardID: card.cardID)
        var session = IOSIntelligentUIStudySession()
        try session.reveal(definition: definition)
        try store.update(source: source, definition: card, selectedOptionID: nil,
                         values: [IOSIntelligentUIStudySession.storageKey: session.encodedValue()])
        let before = store.draft(for: source, definition: card)
        let revision = store.revision
        for raw in badValues {
            XCTAssertThrowsError(try IOSIntelligentUIStudySession.restore(raw, definition: definition))
            XCTAssertThrowsError(try store.update(source: source, definition: card, selectedOptionID: nil,
                                                  values: [IOSIntelligentUIStudySession.storageKey: raw]))
            XCTAssertEqual(store.revision, revision)
            XCTAssertEqual(store.draft(for: source, definition: card), before)
        }
    }

    func testStudyProgressFlushReloadAndSourceIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.json")
        let card = try studyCard()
        let definition = try XCTUnwrap(card.study)
        let origin = source(cardID: card.cardID)
        let other = source(cardID: card.cardID, messageID: "other")
        let store = IOSIntelligentUIStateStore(fileURL: url)
        var session = IOSIntelligentUIStudySession()
        try session.setMode(.quiz, definition: definition)
        try session.answer(optionID: "yuanzhang", definition: definition)
        try session.next(definition: definition)
        try store.update(source: origin, definition: card, selectedOptionID: nil,
                         values: [IOSIntelligentUIStudySession.storageKey: session.encodedValue(), "unknown": "discard"])
        try await store.flush()
        let restored = IOSIntelligentUIStateStore(fileURL: url)
        restored.register(source: origin, definition: card)
        restored.register(source: other, definition: card)
        let draft = restored.draft(for: origin, definition: card)
        XCTAssertEqual(try IOSIntelligentUIStudySession.restore(draft.values[IOSIntelligentUIStudySession.storageKey], definition: definition), session)
        XCTAssertNil(draft.values["unknown"])
        XCTAssertTrue(restored.draft(for: other, definition: card).values.isEmpty)
        XCTAssertEqual(restored.activeSource(for: origin.conversationID), origin)
    }

    func testStudySubmissionHasBoundedSummaryAndDoesNotSendRawSession() throws {
        let card = try studyCard()
        let definition = try XCTUnwrap(card.study)
        let origin = source(cardID: card.cardID)
        let store = IOSIntelligentUIStateStore()
        var session = IOSIntelligentUIStudySession()
        try session.setMode(.quiz, definition: definition)
        try session.answer(optionID: "di", definition: definition)
        try store.update(source: origin, definition: card, selectedOptionID: nil,
                         values: [IOSIntelligentUIStudySession.storageKey: session.encodedValue()])
        let submission = try IOSIntelligentUISubmission(source: origin, definition: card, draft: store.draft(for: origin, definition: card))
        XCTAssertTrue(submission.inputs.isEmpty)
        XCTAssertEqual(submission.studySummary?.answeredCount, 1)
        XCTAssertEqual(submission.studySummary?.correctCount, 0)
        XCTAssertTrue(submission.prompt().contains("错题项目：hongwu"))
        XCTAssertFalse(submission.prompt().contains(IOSIntelligentUIStudySession.storageKey))
        XCTAssertFalse(submission.prompt().contains("\"answers\""))
        XCTAssertLessThan(try XCTUnwrap(submission.studySummary).promptSummary.count, 2_000)
        let decoded = try JSONDecoder().decode(IOSIntelligentUISubmission.self, from: JSONEncoder().encode(submission))
        XCTAssertEqual(decoded, submission)
    }

    func testStudyStorageKeyIsPrivateAndOnlyStudyDraftsRetainIt() throws {
        let card = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.exampleJSON)
        let store = IOSIntelligentUIStateStore()
        let origin = source(cardID: card.cardID)
        try store.update(source: origin, definition: card, selectedOptionID: "native", values: [IOSIntelligentUIStudySession.storageKey: "not-json"])
        XCTAssertNil(store.draft(for: origin, definition: card).values[IOSIntelligentUIStudySession.storageKey])
        var object = try studyObject()
        object["fields"] = [["id": IOSIntelligentUIStudySession.storageKey, "label": "bad", "required": false]]
        XCTAssertThrowsError(try decode(object))
        object["kind"] = "form"
        XCTAssertThrowsError(try decode(object), "Study definitions cannot be smuggled into another task kind")
    }

    private func studyCard() throws -> IOSIntelligentUICardDefinition {
        try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.studyExampleJSON)
    }

    private func studyObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(IOSIntelligentUIProtocol.studyExampleJSON.utf8)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> IOSIntelligentUICardDefinition {
        try IOSIntelligentUIProtocol.decode(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    private func source(cardID: String, messageID: String = "message") -> IOSIntelligentUISource {
        .init(conversationID: "conversation", messageID: messageID, textPartIndex: 0, cardID: cardID)
    }
}
