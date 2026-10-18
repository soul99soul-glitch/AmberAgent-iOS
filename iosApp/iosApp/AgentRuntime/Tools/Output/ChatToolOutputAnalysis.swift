import Foundation
@preconcurrency import Shared

/// The parsed view of a tool output used by the timeline and activity island.
///
/// `UIMessagePart.Tool.output` is a value snapshot in KMP: output is a `val`
/// and streaming merges create a new `Tool`. The only mutable property on a
/// message part is metadata, which is intentionally outside this projection.
/// Keeping the exact text parts in the cache key therefore invalidates a
/// completed-output entry when a same-id tool receives a different result,
/// while allowing all consumers of one snapshot to share its JSON parse.
final class ChatToolOutputAnalysis {
    let firstJSONObject: [String: Any]?
    let jsonObjects: [[String: Any]]
    /// Non-blank text parts in their original form for result summaries.
    let textParts: [String]
    let failureReason: String?
    let imageFailureReason: String?
    let indicatesFailure: Bool
    /// `firstJSONObject["prior_tool_receipt"]` and its nested `result` JSON string,
    /// parsed once per output snapshot instead of on every step-model init.
    let priorToolReceipt: [String: Any]?
    let priorToolReceiptResult: [String: Any]?
    /// Per-snapshot memo for presentations derived from this analysis.
    let derivedValues = ChatToolAnalysisMemo()

    var joinedText: String { textParts.joined(separator: "\n") }

    init(output: [UIMessagePart]) {
        var parsedObjects: [[String: Any]] = []
        var nonEmptyTexts: [String] = []
        var trimmedTexts: [String] = []
        var imageCount = 0

        for part in output {
            if let text = part as? UIMessagePart.Text {
                let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                nonEmptyTexts.append(text.text)
                trimmedTexts.append(trimmed)
                guard let data = trimmed.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                parsedObjects.append(object)
            } else if part is UIMessagePart.Image {
                imageCount += 1
            }
        }

        self.firstJSONObject = parsedObjects.first
        self.jsonObjects = parsedObjects
        self.textParts = nonEmptyTexts
        self.failureReason = Self.failureReason(in: parsedObjects)
        self.imageFailureReason = Self.imageFailureReason(
            in: parsedObjects,
            textParts: trimmedTexts,
            hasImage: imageCount > 0
        )
        self.indicatesFailure = Self.indicatesFailure(in: parsedObjects.first)
        let prior = parsedObjects.first?["prior_tool_receipt"] as? [String: Any]
        self.priorToolReceipt = prior
        self.priorToolReceiptResult = (prior?["result"] as? String).flatMap {
            $0.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func failureReason(in objects: [[String: Any]]) -> String? {
        for object in objects {
            if object["ok"] as? Bool == false {
                return stringValue(in: object, keys: ["reason", "error", "detail", "message"])
                    ?? "工具执行失败"
            }
            if object["denied"] as? Bool == true {
                return stringValue(in: object, keys: ["reason", "error", "detail", "message"])
                    ?? "用户已拒绝"
            }
            if let status = (object["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ["error", "failed", "failure", "denied", "timed_out", "timeout"].contains(status) {
                return stringValue(in: object, keys: ["reason", "error", "detail", "message"])
                    ?? "工具执行失败"
            }
            if let exitCode = object["exit_code"] as? Int, exitCode != 0 {
                return stringValue(in: object, keys: ["stderr", "error", "reason", "message"])
                    ?? "exit \(exitCode)"
            }
            // 兼容已持久化的旧 engine 错误结果，不覆盖明确的成功结果。
            if object["ok"] == nil, object["status"] == nil {
                if let denied = stringValue(in: object, keys: ["denied"]) { return denied }
                if let error = stringValue(in: object, keys: ["error"]) { return error }
            }
        }
        return nil
    }

    private static func indicatesFailure(in object: [String: Any]?) -> Bool {
        guard let object else { return false }
        if let ok = object["ok"] as? Bool { return !ok }
        if object["denied"] as? Bool == true { return true }
        if let status = object["status"] as? String {
            return ["failed", "error", "denied", "timed_out", "cancelled"].contains(status.lowercased())
        }
        if let exitCode = object["exit_code"] as? Int { return exitCode != 0 }
        return false
    }

    private static func imageFailureReason(
        in objects: [[String: Any]],
        textParts: [String],
        hasImage: Bool
    ) -> String? {
        guard !textParts.isEmpty else { return nil }
        var sawStructuredSuccess = false
        for object in objects {
            if let reason = failureReason(in: [object]) {
                return reason
            }
            if object["ok"] as? Bool == true {
                sawStructuredSuccess = true
                continue
            }
            if let status = (object["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ["ok", "success", "succeeded", "completed"].contains(status) {
                sawStructuredSuccess = true
                continue
            }
            if (object["source"] as? String) == "generate_image", object["files"] != nil {
                sawStructuredSuccess = true
                continue
            }
            if (object["tool"] as? String) == "generate_image",
               let reason = stringValue(in: object, keys: ["reason", "error", "detail", "message"]) {
                return reason
            }
        }

        if hasImage || sawStructuredSuccess { return nil }
        return textParts.first
    }
}

/// Thread-safe memo attached to one immutable `ChatToolOutputAnalysis` snapshot.
final class ChatToolAnalysisMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func value<T>(forKey key: String, compute: () -> T) -> T {
        lock.lock()
        if let cached = values[key] as? T {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let computed = compute()
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[key] as? T { return cached }
        values[key] = computed
        return computed
    }
}

final class ChatToolOutputAnalysisCache: @unchecked Sendable {
    private final class ToolEntry {
        weak var tool: UIMessagePart.Tool?
        let analysis: ChatToolOutputAnalysis

        init(tool: UIMessagePart.Tool, analysis: ChatToolOutputAnalysis) {
            self.tool = tool
            self.analysis = analysis
        }
    }

    private struct Key: Hashable {
        let partKinds: [String]
        let textParts: [String]

        init(output: [UIMessagePart]) {
            var partKinds: [String] = []
            var textParts: [String] = []
            for part in output {
                if let text = part as? UIMessagePart.Text {
                    partKinds.append("text")
                    textParts.append(text.text)
                } else if part is UIMessagePart.Image {
                    // Image URL changes do not affect this projection; the
                    // count/type is all image failure rendering consumes.
                    partKinds.append("image")
                } else {
                    partKinds.append(String(reflecting: type(of: part)))
                }
            }
            self.partKinds = partKinds
            self.textParts = textParts
        }
    }

    private let lock = NSLock()
    private var values: [Key: ChatToolOutputAnalysis] = [:]
    private var order: [Key] = []
    private var toolValues: [ObjectIdentifier: ToolEntry] = [:]
    private var toolOrder: [ObjectIdentifier] = []
    // A single assistant message can legitimately contain dozens or hundreds
    // of sequential SSH/job calls. Keep the common tool-row working set hot;
    // the cache still has a hard bound and stores only parsed JSON projections.
    private let maxEntries = 512

    func analysis(for output: [UIMessagePart]) -> ChatToolOutputAnalysis {
        guard !output.isEmpty else { return ChatToolOutputAnalysis(output: []) }
        let key = Key(output: output)
        lock.lock()
        if let cached = values[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = ChatToolOutputAnalysis(output: output)

        lock.lock()
        defer { lock.unlock() }
        if let cached = values[key] { return cached }
        values[key] = parsed
        order.append(key)
        if order.count > maxEntries {
            let evicted = order.removeFirst()
            values.removeValue(forKey: evicted)
        }
        return parsed
    }

    func analysis(for tool: UIMessagePart.Tool) -> ChatToolOutputAnalysis {
        let identifier = ObjectIdentifier(tool)
        lock.lock()
        if let cached = toolValues[identifier], cached.tool === tool {
            lock.unlock()
            return cached.analysis
        }
        lock.unlock()

        // KMP Tool is a value snapshot for all fields used here (`output` is a
        // val); only metadata is mutable and it is outside this projection.
        let parsed = analysis(for: tool.output)

        lock.lock()
        defer { lock.unlock() }
        if let cached = toolValues[identifier], cached.tool === tool {
            return cached.analysis
        }
        toolValues[identifier] = ToolEntry(tool: tool, analysis: parsed)
        toolOrder.append(identifier)
        if toolOrder.count > maxEntries {
            let evicted = toolOrder.removeFirst()
            toolValues.removeValue(forKey: evicted)
        }
        return parsed
    }
}

let chatToolOutputAnalysisCache = ChatToolOutputAnalysisCache()

