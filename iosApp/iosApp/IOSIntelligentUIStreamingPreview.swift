import Foundation

/// Received content only. This projection has no draft, receipt, or run authority.
struct IOSIntelligentUIStreamingPreview: Equatable, Sendable {
    struct StudyPrompt: Equatable, Sendable, Identifiable {
        let id: String
        let prompt: String
    }

    var cardID: String?
    var goal: String?
    var question: String?
    var options: [IOSIntelligentUICardDefinition.Option] = []
    var fields: [IOSIntelligentUICardDefinition.Field] = []
    var components: [IOSIntelligentUIComponent] = []
    var studyPrompts: [StudyPrompt] = []
    var isRootComplete = false
    var issue: String?

    var hasContent: Bool {
        goal != nil || question != nil || !options.isEmpty || !fields.isEmpty || !components.isEmpty || !studyPrompts.isEmpty
    }

    var componentCount: Int {
        func count(_ nodes: [IOSIntelligentUIComponent]) -> Int {
            nodes.reduce(0) { $0 + 1 + count($1.children ?? []) }
        }
        return count(components)
    }

    static func complete(_ definition: IOSIntelligentUICardDefinition) -> Self {
        Self(cardID: definition.cardID, goal: definition.goal,
             question: definition.question.isEmpty ? nil : definition.question,
             options: definition.options, fields: definition.fields, components: definition.components,
             studyPrompts: definition.study?.items.map { StudyPrompt(id: $0.id, prompt: $0.prompt) } ?? [],
             isRootComplete: true)
    }
}

/// A lexer for received JSON boundaries, not a JSON repairer. Complete values are
/// decoded at their closing boundary; incomplete values never reach the preview.
struct IOSIntelligentUIStreamingPreviewScanner {
    private(set) var preview: IOSIntelligentUIStreamingPreview?

    private struct Frame {
        let isObject: Bool
        let path: [String]
        let start: Int
        var key: String?
        var expectsKey = true
    }

    private var processedCount = 0
    private var checkpoint: [UInt16] = []
    private var fence = FenceLine()
    private var ordinaryFence: (character: UInt16, count: Int)?
    private var taskFenceCount: Int?
    private var payloadStart: Int?
    private var frames: [Frame] = []
    private var stringStart: Int?
    private var stringIsKey = false
    private var stringPath: [String] = []
    private var escaped = false
    private var primitiveStart: Int?
    private var primitivePath: [String] = []
    private var rootEnded = false
    private var version: Int?
    private var kind: String?
    private var received = IOSIntelligentUIStreamingPreview()
    private var candidates: [IOSIntelligentUIComponent] = []
    private var changed = false

    mutating func reset() { self = Self() }

    mutating func reconcile(_ text: String) {
        reset()
        update(with: text)
    }

    mutating func update(with text: String) {
        let string = text as NSString
        let count = string.length
        let matches = checkpointMatches(in: string)
        guard count != processedCount || !matches else { return }
        if count < processedCount || !matches { reset() }
        changed = false
        let units = Self.units(in: string, range: NSRange(location: processedCount, length: count - processedCount))
        for (index, unit) in units.enumerated() {
            let offset = processedCount + index
            if taskFenceCount != nil { consumeJSON(unit, at: offset, in: string) }
            if unit == 10 {
                finishLine(nextLine: offset + 1)
                fence = FenceLine()
            } else {
                fence.consume(unit)
            }
        }
        processedCount = count
        let length = min(24, count)
        checkpoint = Self.units(in: string, range: NSRange(location: count - length, length: length))
        if changed { publish() }
    }

    private mutating func finishLine(nextLine: Int) {
        guard let marker = fence.marker else { return }
        if let taskFenceCount {
            if marker.character == 96 && marker.count >= taskFenceCount && marker.info == .empty {
                self.taskFenceCount = nil
                payloadStart = nil
                preview = nil
                changed = false
            }
            return
        }
        if let ordinaryFence {
            if marker.character == ordinaryFence.character && marker.count >= ordinaryFence.count && marker.info == .empty {
                self.ordinaryFence = nil
            }
        } else if marker.character == 96 && marker.info == .taskUI {
            taskFenceCount = marker.count
            payloadStart = nextLine
            frames = []
            stringStart = nil
            primitiveStart = nil
            escaped = false
            rootEnded = false
            version = nil
            kind = nil
            received = IOSIntelligentUIStreamingPreview()
            candidates = []
            preview = nil
        } else {
            ordinaryFence = (marker.character, marker.count)
        }
    }

    private mutating func consumeJSON(_ unit: UInt16, at offset: Int, in string: NSString) {
        guard !rootEnded, let payloadStart else { return }
        guard offset - payloadStart <= 131_072, frames.count <= 20 else {
            received.issue = "收到的界面内容超出支持范围。"
            rootEnded = true
            changed = true
            return
        }
        if let start = stringStart {
            if escaped { escaped = false; return }
            if unit == 92 { escaped = true; return }
            if unit == 34 {
                let raw = Self.fragment(in: string, start: start, end: offset + 1)
                if let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) {
                    if stringIsKey, !frames.isEmpty {
                        frames[frames.count - 1].key = value
                    } else {
                        receiveString(value, path: stringPath)
                    }
                }
                stringStart = nil
            }
            return
        }
        if let start = primitiveStart {
            if Self.isDelimiter(unit) {
                if primitivePath == ["version"] {
                    let raw = Self.fragment(in: string, start: start, end: offset)
                    version = try? JSONDecoder().decode(Int.self, from: Data(raw.utf8))
                    changed = true
                }
                primitiveStart = nil
            } else { return }
        }
        switch unit {
        case 34:
            stringStart = offset
            stringIsKey = frames.last?.isObject == true && frames.last?.expectsKey == true
            stringPath = valuePath()
        case 123, 91:
            let path = valuePath()
            if unit == 91 {
                switch path {
                case ["fields"]: received.fields = []; changed = true
                case ["options"]: received.options = []; changed = true
                case ["components"]: candidates = []; changed = true
                case ["study", "items"]: received.studyPrompts = []; changed = true
                default: break
                }
            }
            frames.append(Frame(isObject: unit == 123, path: path, start: offset))
        case 125, 93:
            guard let frame = frames.popLast(), frame.isObject == (unit == 125) else { return }
            if frame.isObject {
                receiveObject(Self.fragment(in: string, start: frame.start, end: offset + 1), path: frame.path)
                if frames.isEmpty { rootEnded = true }
            }
        case 58:
            if !frames.isEmpty { frames[frames.count - 1].expectsKey = false }
        case 44:
            if !frames.isEmpty, frames[frames.count - 1].isObject {
                frames[frames.count - 1].expectsKey = true
                frames[frames.count - 1].key = nil
            }
        case 9, 10, 13, 32: break
        default:
            primitiveStart = offset
            primitivePath = valuePath()
        }
    }

    private func valuePath() -> [String] {
        guard let frame = frames.last else { return [] }
        return frame.isObject ? frame.path + (frame.key.map { [$0] } ?? []) : frame.path
    }

    private mutating func receiveString(_ value: String, path: [String]) {
        switch path {
        case ["card_id"]: if Self.validID(value) { received.cardID = value; changed = true }
        case ["kind"]: kind = value; changed = true
        case ["goal"]: if Self.validText(value, maximum: 500) { received.goal = value; changed = true }
        case ["question"]: if Self.validText(value, maximum: 300) { received.question = value; changed = true }
        default: break
        }
    }

    private mutating func receiveObject(_ raw: String, path: [String]) {
        let data = Data(raw.utf8)
        switch path {
        case []:
            do {
                received = .complete(try IOSIntelligentUIProtocol.decode(raw))
                candidates = received.components
            } catch { received.issue = "收到的界面尚未通过协议校验。" }
            changed = true
        case ["fields"]:
            guard received.fields.count < 16,
                  Self.hasOnlyKeys(data, allowed: ["id", "label", "required", "placeholder", "type"]),
                  let field = try? JSONDecoder().decode(IOSIntelligentUICardDefinition.Field.self, from: data),
                  Self.validID(field.id), Self.validText(field.label, maximum: 100),
                  field.placeholder.map({ Self.validText($0, maximum: 200) }) ?? true,
                  ["text", "number", "bool", "date", "time", "choice", "multiChoice", "presentation"].contains(field.type ?? "text"),
                  !received.fields.contains(where: { $0.id == field.id }) else { return }
            received.fields.append(field)
            changed = true
        case ["options"]:
            guard received.options.count < 8,
                  Self.hasOnlyKeys(data, allowed: ["id", "title", "summary", "tradeoffs", "recommended"]),
                  let option = try? JSONDecoder().decode(IOSIntelligentUICardDefinition.Option.self, from: data),
                  Self.validID(option.id), Self.validText(option.title, maximum: 100), Self.validText(option.summary, maximum: 1_000),
                  (option.tradeoffs?.count ?? 0) <= 4, (option.tradeoffs ?? []).allSatisfy({ Self.validText($0, maximum: 500) }),
                  !received.options.contains(where: { $0.id == option.id }) else { return }
            received.options.append(option)
            changed = true
        case ["components"]:
            guard candidates.count < IOSIntelligentUIComponentCatalog.maximumNodes,
                  let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let fieldIDs = Set(received.fields.map(\.id)).union(Self.references(in: rawObject))
            if let node = try? IOSIntelligentUIProtocol.decodePreviewComponent(raw, allowedFieldIDs: fieldIDs) {
                candidates.append(node)
                changed = true
            }
        case ["study", "items"]:
            guard received.studyPrompts.count < 40,
                  Self.hasOnlyStudyKeys(data),
                  let item = try? JSONDecoder().decode(IOSIntelligentUIStudyDefinition.Item.self, from: data),
                  Self.validID(item.id), Self.validText(item.prompt, maximum: 1_000),
                  Self.validText(item.answer, maximum: 2_000),
                  !received.studyPrompts.contains(where: { $0.id == item.id }) else { return }
            do { try IOSIntelligentUIStudyDefinition.validate(item) }
            catch { return }
            received.studyPrompts.append(.init(id: item.id, prompt: item.prompt))
            changed = true
        default: break
        }
    }

    private mutating func publish() {
        guard version == 1, let kind, ["decision", "form", "explore", "study"].contains(kind) else {
            preview = nil
            return
        }
        if !received.isRootComplete {
            let fieldIDs = Set(received.fields.map(\.id))
            var valid: [IOSIntelligentUIComponent] = []
            for node in candidates {
                if (try? IOSIntelligentUIComponentCatalog.validate(valid + [node], allowedFieldIDs: fieldIDs)) != nil {
                    valid.append(node)
                }
            }
            let numberFields = Set(received.fields.filter { $0.type == "number" }.map(\.id))
            received.components = valid.filter { node in
                (try? IOSIntelligentUIComponentCatalog.validateValueReferences(
                    [node], numberFieldIDs: numberFields, inputComponents: valid
                )) != nil
            }
            if kind != "study" { received.studyPrompts = [] }
        }
        preview = received.hasContent ? received : nil
    }

    private func checkpointMatches(in string: NSString) -> Bool {
        guard processedCount > 0 else { return true }
        guard processedCount <= string.length else { return false }
        return Self.units(in: string, range: NSRange(location: processedCount - checkpoint.count, length: checkpoint.count)) == checkpoint
    }

    private static func units(in string: NSString, range: NSRange) -> [UInt16] {
        var units = [UInt16](repeating: 0, count: range.length)
        if !units.isEmpty { units.withUnsafeMutableBufferPointer { string.getCharacters($0.baseAddress!, range: range) } }
        return units
    }

    private static func fragment(in string: NSString, start: Int, end: Int) -> String {
        string.substring(with: NSRange(location: start, length: end - start))
    }

    private static func isDelimiter(_ unit: UInt16) -> Bool { [9, 10, 13, 32, 44, 93, 125].contains(unit) }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maximum
    }

    private static func hasOnlyKeys(_ data: Data, allowed: Set<String>) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Set(object.keys).isSubset(of: allowed)
    }

    private static func hasOnlyStudyKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["id", "prompt", "answer", "detail", "options", "correct_option_id"]) else { return false }
        guard let rawOptions = object["options"], !(rawOptions is NSNull) else { return true }
        guard let options = rawOptions as? [[String: Any]] else { return false }
        return options.allSatisfy { Set($0.keys).isSubset(of: ["id", "label"]) }
    }

    private static func references(in object: [String: Any]) -> Set<String> {
        var fields = Set<String>()
        if let id = object["field_id"] as? String { fields.insert(id) }
        if let id = object["value_field_id"] as? String { fields.insert(id) }
        for row in object["rows"] as? [[String: Any]] ?? [] {
            if let id = row["value_field_id"] as? String { fields.insert(id) }
        }
        for child in object["children"] as? [[String: Any]] ?? [] { fields.formUnion(references(in: child)) }
        return fields
    }

    /// Probe fence syntax while reading a line; ordinary prose is never retained.
    private struct FenceLine {
        enum Info { case empty, taskUI, other }
        private var indentation = 0
        private var character: UInt16?
        private var count = 0
        private var infoStarted = false
        private var trailingSpace = false
        private var matched = 0
        private var invalid = false
        private var otherInfo = false
        private static let taskUI = Array("task-ui".utf16)

        var marker: (character: UInt16, count: Int, info: Info)? {
            guard !invalid, let character, count >= 3 else { return nil }
            let info: Info = !infoStarted ? .empty : (!otherInfo && matched == Self.taskUI.count ? .taskUI : .other)
            return (character, count, info)
        }

        mutating func consume(_ unit: UInt16) {
            guard !invalid else { return }
            if character == nil {
                if unit == 32 { indentation += 1; invalid = indentation > 3 }
                else if unit == 96 || unit == 126 { character = unit; count = 1 }
                else { invalid = true }
                return
            }
            if !infoStarted && matched == 0 && !trailingSpace && unit == character {
                count += 1
                return
            }
            let whitespace = UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            if whitespace {
                trailingSpace = true
                return
            }
            if infoStarted && trailingSpace { otherInfo = true }
            infoStarted = true
            trailingSpace = false
            if matched < Self.taskUI.count && Self.taskUI[matched] == unit { matched += 1 }
            else { otherInfo = true }
        }
    }
}
