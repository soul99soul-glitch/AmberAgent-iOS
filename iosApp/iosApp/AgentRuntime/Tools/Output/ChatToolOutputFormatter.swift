import Foundation
@preconcurrency import Shared

/// 工具输出硬上限（对齐 exec 工具 `max_output_chars` 语义）。所有工具的文本输出
/// 经统一收口：总输出超限时截断并追加可见标记；JSON 形态输出保形截断，不破坏
/// ok/status/exit_code 等判定键。
@MainActor
enum ChatToolOutputFormatter {
    private typealias WebMountArrayCandidate = (path: [Any], key: String, array: [Any], count: Int)

    /// Parse one immutable output snapshot once and let every timeline consumer
    /// read the same result. The cache key includes every text part's contents
    /// and part ordering, so a same-id/same-count streaming replacement cannot
    /// reuse a stale terminal state or failure reason.
    nonisolated static func analysis(for output: [UIMessagePart]) -> ChatToolOutputAnalysis {
        chatToolOutputAnalysisCache.analysis(for: output)
    }

    /// Fast path for repeated projections of the same KMP Tool snapshot. The
    /// cache keeps a weak identity check and falls back to the exact output key
    /// when a wrapper is recreated or an address is reused.
    nonisolated static func analysis(for tool: UIMessagePart.Tool) -> ChatToolOutputAnalysis {
        chatToolOutputAnalysisCache.analysis(for: tool)
    }

    static func subAgentOutcome(
        for toolName: String,
        output: IOSLocalToolExecutionOutput
    ) -> IOSAgentToolOutcome {
        switch output {
        case .selectedFilePreview(let read):
            return .filled(IOSWorkspaceStore.json([
                "ok": true,
                "tool": toolName,
                "file_name": read.fileName,
                "file_type": read.fileType,
                "bytes_read": read.bytesRead,
                "total_bytes": read.totalBytes,
                "character_count": read.characterCount,
                "is_truncated": read.isTruncated,
                "note": read.note ?? "",
                "preview": read.preview
            ]))
        case .permissionsStatus(let snapshot):
            let capabilities = snapshot.capabilities.map { item in
                [
                    "id": item.id,
                    "title": item.title,
                    "status": item.status,
                    "policy": item.policy,
                    "model_tools": item.modelToolNames,
                    "blocked_tools": item.blockedToolNames
                ] as [String: Any]
            }
            return .filled(IOSWorkspaceStore.json([
                "ok": true,
                "tool": toolName,
                "platform": snapshot.platform,
                "capabilities": capabilities
            ]))
        case .workspaceResult(let result), .webMountResult(let result), .terminalResult(let result), .ishExecuteResult(let result), .ishHandoffResult(let result):
            return .filled(result)
        case .needsUserAction(let reason):
            return .denied(reason)
        case .denied(let reason):
            return .denied(reason)
        case .failed(let message):
            return .failed(message)
        }
    }

    /// Workspace 工具输出 JSON 的失败原因（`{"ok":false,...}`）；成功或解析
    /// 不出 ok 键 ⇒ nil。recipe step 语义是 stop-on-failure（§10.3.6）：recipe
    /// 路由与评测的隔离 workspace 执行都必须把 ok:false 当成 step 失败，
    /// 而不是「步骤成功、输出恰好是失败 JSON」的 false-green（收口计划 §2.2）。
    nonisolated static func workspaceFailureReason(inOutputJSON outputJSON: String) -> String? {
        guard let data = outputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            return nil
        }
        guard !ok else { return nil }
        return (object["error"] as? String)
            ?? (object["reason"] as? String)
            ?? "workspace tool failed"
    }

    static func workspaceResultText(
        for toolCall: UIMessagePart.Tool,
        output: IOSLocalToolExecutionOutput
    ) -> String {
        switch output {
        case .workspaceResult(let result):
            return result
        case .terminalResult(let result):
            return result
        case .ishExecuteResult(let result):
            return result
        case .ishHandoffResult(let result):
            return result
        case .needsUserAction(let reason):
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "needs_user_action": true,
                "reason": reason
            ])
        case .denied(let reason):
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "denied": true,
                "reason": reason
            ])
        case .failed(let message):
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "error": message
            ])
        case .selectedFilePreview:
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "error": "Unexpected selected-file output for Workspace tool."
            ])
        case .permissionsStatus(let snapshot):
            return IOSWorkspaceStore.json([
                "ok": true,
                "tool": toolCall.toolName,
                "platform": snapshot.platform
            ])
        case .webMountResult:
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "error": "Unexpected WebMount output for Workspace tool."
            ])
        }
    }

    static func ishHandoffResultText(
        for toolCall: UIMessagePart.Tool,
        output: IOSLocalToolExecutionOutput
    ) -> String {
        let canReturnExecutionOutput = IOSRemoteTerminalToolCatalog.supportedToolNames.contains(toolCall.toolName)
            || IOSAmberShellToolCatalog.supportedToolNames.contains(toolCall.toolName)
            || IOSEmbeddedIshToolCatalog.supportedToolNames.contains(toolCall.toolName)
        switch output {
        case .terminalResult(let result):
            return result
        case .ishExecuteResult(let result):
            return result
        case .ishHandoffResult(let result):
            return result
        case .needsUserAction(let reason):
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "needs_user_action": true,
                "reason": reason,
                "stdout_available": canReturnExecutionOutput,
                "stderr_available": canReturnExecutionOutput,
                "exit_code_available": false
            ])
        case .denied(let reason):
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "denied": true,
                "reason": reason,
                "stdout_available": canReturnExecutionOutput,
                "stderr_available": canReturnExecutionOutput,
                "exit_code_available": false
            ])
        case .failed(let message):
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "error": message,
                "stdout_available": canReturnExecutionOutput,
                "stderr_available": canReturnExecutionOutput,
                "exit_code_available": false
            ])
        default:
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "error": "Unexpected output for terminal tool.",
                "stdout_available": canReturnExecutionOutput,
                "stderr_available": canReturnExecutionOutput,
                "exit_code_available": false
            ])
        }
    }

    static func webMountResultText(
        for toolCall: UIMessagePart.Tool,
        output: IOSLocalToolExecutionOutput
    ) -> String {
        func contextualResult(_ fields: [String: Any]) -> String {
            var fields = fields
            if let data = toolCall.input.data(using: .utf8),
               let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let sessionId = (input["session_id"] as? String)?.nilIfBlank {
                fields["session_id"] = sessionId
            }
            return IOSWebMountController.json(fields)
        }
        switch output {
        case .webMountResult(let result):
            return result
        case .terminalResult, .ishExecuteResult, .ishHandoffResult:
            return contextualResult([
                "ok": false,
                "tool": toolCall.toolName,
                "error": "Unexpected iSH output for WebMount tool."
            ])
        case .needsUserAction(let reason):
            return contextualResult([
                "ok": false,
                "tool": toolCall.toolName,
                "needs_user_action": true,
                "reason": reason
            ])
        case .denied(let reason):
            return contextualResult([
                "ok": false,
                "tool": toolCall.toolName,
                "denied": true,
                "reason": reason
            ])
        case .failed(let message):
            return contextualResult([
                "ok": false,
                "tool": toolCall.toolName,
                "error": message
            ])
        case .selectedFilePreview:
            return contextualResult([
                "ok": false,
                "tool": toolCall.toolName,
                "error": "Unexpected selected-file output for WebMount tool."
            ])
        case .workspaceResult:
            return contextualResult([
                "ok": false,
                "tool": toolCall.toolName,
                "error": "Unexpected Workspace output for WebMount tool."
            ])
        case .permissionsStatus(let snapshot):
            return contextualResult([
                "ok": true,
                "tool": toolCall.toolName,
                "platform": snapshot.platform
            ])
        }
    }

    nonisolated static func toolFailureJSON(
        toolName: String,
        reason: String,
        denied: Bool = false,
        cancelled: Bool = false,
        status: String? = nil
    ) -> String {
        IOSToolFailurePayload.json(
            toolName: toolName, reason: reason, denied: denied, cancelled: cancelled, status: status
        )
    }

    /// Structured error for a tool call whose `input` failed
    /// `UIMessagePart.Tool.parseInputStrict()` (I-2, fail-closed). Not executed —
    /// this is the entire output the model sees, so it must both satisfy the
    /// `tool_arguments_invalid` / `message` / `raw_prefix` contract callers rely on
    /// and be recognized as a failure by `failureReason(from:)` above (hence `ok`
    /// and `reason`, matched the same way `toolFailureJSON` is).
    static func toolArgumentsInvalidJSON(
        toolName: String,
        message: String,
        rawPrefix: String
    ) -> String {
        let payload: [String: Any] = [
            "ok": false,
            "tool": toolName,
            "error": "tool_arguments_invalid",
            "reason": message,
            "message": message,
            "raw_prefix": rawPrefix
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(toolName) failed: tool_arguments_invalid: \(message)"
        }
        return text
    }

    /// 工具输出收口上限（对齐 exec 工具 `max_output_chars` 语义）：文本总量超
    /// [maxChars] 时截断并追加可见标记。JSON 形态输出保形截断（保留所有键与
    /// ok/status/exit_code 判定），普通文本保留头部、截断尾部。已带
    /// `[tool output compacted]` 压缩标记的输出豁免，不二次截断。
    static func cappedToolOutputParts(
        _ parts: [UIMessagePart],
        maxChars: Int = IOSToolOutputLimits.maxOutputChars
    ) -> [UIMessagePart] {
        let texts = parts.compactMap { $0 as? UIMessagePart.Text }
        guard !texts.isEmpty else { return parts }
        let totalChars = texts.reduce(0) { $0 + $1.text.count }
        guard totalChars > maxChars else { return parts }
        guard !partsContainsCompactedMarker(parts) else { return parts }
        if texts.count == 1,
           let only = texts.first,
           let capped = cappedStructuredJSON(only.text, maxChars: maxChars) {
            return parts.map { part in
                guard let text = part as? UIMessagePart.Text else { return part }
                return PromptTranscript.shared.doCopyText(part: text, text: capped)
            }
        }
        return cappedPlainTextParts(parts, maxChars: maxChars)
    }

    private static func partsContainsCompactedMarker(_ parts: [UIMessagePart]) -> Bool {
        parts.contains { part in
            guard let text = part as? UIMessagePart.Text else { return false }
            return text.text.contains(IOSToolOutputLimits.compactedToolOutputMarker)
        }
    }

    /// JSON 对象保形截断：从最长字符串值开始减半，保持所有键（含 ok/status/
    /// exit_code 判定键）与结构，最终追加 truncated 标记。不可保形时返回 nil。
    private static func cappedStructuredJSON(_ raw: String, maxChars: Int) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if isWebMountPayload(object) {
            return cappedWebMountJSON(object, raw: raw, maxChars: maxChars)
        }
        var working: [String: Any] = object
        var string = jsonString(working)
        guard string.count > maxChars else { return raw }
        var truncated = false
        var iterations = 0
        while string.count > maxChars, iterations < 128 {
            iterations += 1
            // 描述文本保留至少 12 字符；定位字段和状态值由下方遍历排除。
            guard let longest = longestStringValue(in: working, minimumLength: 12),
                  longest.value.count > 12 else { break }
            let shorter = String(longest.value.prefix(max(longest.value.count / 2, 12)))
            working = replacingValue(at: longest.path, in: working, with: shorter) as! [String: Any]
            truncated = true
            string = jsonString(working)
        }
        // 只剩不可裁短的字段时保留 JSON，避免转为纯文本截断而破坏操作引用。
        guard truncated else { return raw }
        working["truncated"] = true
        working["truncation_note"] = IOSToolOutputLimits.truncationMarker(
            droppedChars: max(raw.count - string.count, 0)
        )
        string = jsonString(working)
        if string.count > maxChars {
            working["truncation_note"] = nil
            string = jsonString(working)
        }
        return string
    }

    private static func isWebMountPayload(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if (object["tool"] as? String)?.hasPrefix("wm_") == true
                || (object["session_id"] as? String) != nil && (object["snapshot_id"] as? String) != nil
                || object["interactive_elements"] != nil || object["visual_candidates"] != nil {
                return true
            }
            return object.values.contains { isWebMountPayload($0) }
        }
        if let array = value as? [Any] {
            return array.contains { isWebMountPayload($0) }
        }
        return false
    }

    private static func cappedWebMountJSON(
        _ original: [String: Any],
        raw: String,
        maxChars: Int
    ) -> String {
        var working = original
        var fields: [String: [String: Any]] = [:]

        func rendered(budgetExceeded: Bool) -> String {
            var payload = working
            payload["truncated"] = true
            var truncation: [String: Any] = [
                "fields": fields,
                "read_more": "Use wm_find or wm_get with the same session_id and snapshot_id, or observe again to retrieve omitted entries."
            ]
            if budgetExceeded {
                truncation["budget_exceeded"] = true
                payload["budget_exceeded"] = true
            }
            payload["truncation"] = truncation
            payload["truncation_note"] = IOSToolOutputLimits.truncationMarker(
                droppedChars: max(raw.count - jsonString(working).count, 0)
            )
            return jsonString(payload)
        }

        while rendered(budgetExceeded: false).count > maxChars,
              let candidate = webMountArrayPaths(in: working).first(where: {
                  let minimum = $0.key == "links" ? 3 : 0
                  return $0.count > minimum && ($0.key == "visual_candidates" || $0.key == "links")
              }) {
            guard dropWebMountArray(candidate, from: &working, fields: &fields) else { break }
        }

        while rendered(budgetExceeded: false).count > maxChars,
              let candidate = longestStringValue(
                  in: working,
                  minimumLength: 96,
                  protectedKey: webMountProtectedStringKey,
                  minimumLengthForKey: webMountDescriptionFloor
              ),
              let key = candidate.path.last as? String {
            let floor = webMountDescriptionFloor(for: key)
            guard candidate.value.count > floor else { break }
            let replacement = String(candidate.value.prefix(max(floor, candidate.value.count / 2)))
            guard let next = replacingValue(
                at: candidate.path,
                in: working,
                with: replacement
            ) as? [String: Any] else { break }
            working = next
            let path = webMountPath(candidate.path)
            let originalChars = fields[path]?["original_chars"] as? Int ?? candidate.value.count
            fields[path] = [
                "original_chars": originalChars,
                "returned_chars": replacement.count
            ]
        }

        while rendered(budgetExceeded: false).count > maxChars,
              let candidate = webMountArrayPaths(in: working).first(where: {
                  $0.count > 6 && ["interactive_elements", "interactive_nodes", "elements"].contains($0.key)
              }) {
            guard dropWebMountArray(candidate, from: &working, fields: &fields) else { break }
        }

        let result = rendered(budgetExceeded: false)
        return result.count <= maxChars ? result : rendered(budgetExceeded: true)
    }

    private static func webMountArrayPaths(
        in value: Any,
        path: [Any] = []
    ) -> [WebMountArrayCandidate] {
        var result: [WebMountArrayCandidate] = []
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                guard let child = object[key] else { continue }
                if let array = child as? [Any], webMountArrayPriority(for: key) != nil {
                    result.append((path + [key], key, array, array.count))
                }
                result.append(contentsOf: webMountArrayPaths(in: child, path: path + [key]))
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                result.append(contentsOf: webMountArrayPaths(in: child, path: path + [index]))
            }
        }
        return result.sorted {
            let left = webMountArrayPriority(for: $0.key) ?? 99
            let right = webMountArrayPriority(for: $1.key) ?? 99
            return left == right
                ? webMountPath($0.path) < webMountPath($1.path)
                : left < right
        }
    }

    private static func dropWebMountArray(
        _ candidate: WebMountArrayCandidate,
        from working: inout [String: Any],
        fields: inout [String: [String: Any]]
    ) -> Bool {
        let returnedCount = candidate.count - 1
        guard let next = replacingValue(
            at: candidate.path,
            in: working,
            with: Array(candidate.array.prefix(returnedCount))
        ) as? [String: Any] else { return false }
        working = next
        let path = webMountPath(candidate.path)
        let originalCount = fields[path]?["original_count"] as? Int ?? candidate.count
        fields[path] = ["original_count": originalCount, "returned_count": returnedCount]
        return true
    }

    private static func webMountArrayPriority(for key: String) -> Int? {
        switch key {
        case "visual_candidates": return 0
        case "links": return 1
        case "interactive_elements", "interactive_nodes": return 2
        case "elements": return 3
        default: return nil
        }
    }

    private static func webMountProtectedStringKey(_ key: String) -> Bool {
        let key = key.lowercased()
        return key == "id" || key == "ref" || key.hasSuffix("_id") || key.hasSuffix("_ref")
            || key == "selector" || key == "target"
            || key.contains("url")
            || ["status", "error_code", "tool", "method", "href", "src", "origin"].contains(key)
    }

    private static func webMountDescriptionFloor(for key: String) -> Int {
        switch key.lowercased() {
        case "visible_text": return 1_024
        case "title": return 160
        case "text", "name", "label", "description", "nearby_text", "reason", "message", "error", "detail": return 160
        default: return 96
        }
    }

    private static func webMountPath(_ path: [Any]) -> String {
        path.map { value in
            if let key = value as? String { return key }
            return "[\(value as? Int ?? 0)]"
        }.joined(separator: ".")
    }

    private static func cappedPlainTextParts(_ parts: [UIMessagePart], maxChars: Int) -> [UIMessagePart] {
        var remaining = maxChars
        var droppedChars = 0
        var result: [UIMessagePart] = []
        for part in parts {
            guard let text = part as? UIMessagePart.Text else {
                result.append(part)
                continue
            }
            if remaining <= 0 {
                droppedChars += text.text.count
                continue
            }
            let keep = String(text.text.prefix(remaining))
            droppedChars += text.text.count - keep.count
            remaining -= keep.count
            result.append(PromptTranscript.shared.doCopyText(part: text, text: keep))
        }
        guard droppedChars > 0, let lastTextIndex = result.indices.last(where: { result[$0] is UIMessagePart.Text }) else {
            return result
        }
        let last = result[lastTextIndex] as! UIMessagePart.Text
        let marked = PromptTranscript.shared.doCopyText(
            part: last,
            text: last.text + IOSToolOutputLimits.truncationMarker(droppedChars: droppedChars)
        )
        result[lastTextIndex] = marked
        return result
    }

    /// 树中（字典/数组递归）最长的字符串值及其路径。
    private static func longestStringValue(
        in value: Any,
        minimumLength: Int,
        path: [Any] = [],
        protectedKey: ((String) -> Bool)? = nil,
        minimumLengthForKey: ((String) -> Int)? = nil
    ) -> (path: [Any], value: String)? {
        // A locator is reused as a complete fingerprint by wm_find.
        if protectedKey != nil, path.contains(where: { $0 as? String == "locator" }) { return nil }
        if let string = value as? String, string.count > minimumLength {
            return (path, string)
        }
        if let dict = value as? [String: Any] {
            var best: (path: [Any], value: String)?
            for (key, child) in dict {
                // 这些值会被后续工具用来定位目标或判断结果，不能裁短。
                if child is String,
                   key == "id" || key == "ref" || key.hasSuffix("_id") || key.hasSuffix("_ref")
                    || ["selector", "status", "error_code", "tool", "method"].contains(key)
                    || protectedKey?(key) == true {
                    continue
                }
                if let candidate = longestStringValue(
                    in: child,
                    minimumLength: minimumLengthForKey?(key) ?? minimumLength,
                    path: path + [key],
                    protectedKey: protectedKey,
                    minimumLengthForKey: minimumLengthForKey
                ),
                   candidate.value.count > (best?.value.count ?? 0) {
                    best = candidate
                }
            }
            return best
        }
        if let array = value as? [Any] {
            var best: (path: [Any], value: String)?
            for (index, child) in array.enumerated() {
                if let candidate = longestStringValue(
                    in: child,
                    minimumLength: minimumLength,
                    path: path + [index],
                    protectedKey: protectedKey,
                    minimumLengthForKey: minimumLengthForKey
                ),
                   candidate.value.count > (best?.value.count ?? 0) {
                    best = candidate
                }
            }
            return best
        }
        return nil
    }

    /// 按路径（String 键 / Int 下标）替换树中的字符串值。
    private static func replacingValue(
        at path: [Any],
        index: Int = 0,
        in value: Any,
        with replacement: Any
    ) -> Any {
        guard index < path.count else { return value }
        let key = path[index]
        if let dict = value as? [String: Any], let keyString = key as? String {
            var next = dict
            if index == path.count - 1 {
                next[keyString] = replacement
            } else if let child = next[keyString] {
                next[keyString] = replacingValue(at: path, index: index + 1, in: child, with: replacement)
            }
            return next
        }
        if let array = value as? [Any], let arrayIndex = key as? Int {
            var next = array
            if index == path.count - 1 {
                next[arrayIndex] = replacement
            } else if arrayIndex < next.count {
                next[arrayIndex] = replacingValue(
                    at: path,
                    index: index + 1,
                    in: next[arrayIndex],
                    with: replacement
                )
            }
            return next
        }
        return value
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    nonisolated static func failureReason(from output: [UIMessagePart]) -> String? {
        analysis(for: output).failureReason
    }

    nonisolated static func imageFailureReason(from output: [UIMessagePart]) -> String? {
        analysis(for: output).imageFailureReason
    }

    nonisolated static func imageFailureReason(
        in messages: [UIMessage],
        matching targetToolCall: UIMessagePart.Tool? = nil
    ) -> String? {
        for message in messages where message.role == MessageRole.assistant {
            for case let tool as UIMessagePart.Tool in message.parts {
                guard tool.toolName == "generate_image",
                      !tool.output.isEmpty else {
                    continue
                }
                if let targetToolCall,
                   chatToolCallKey(tool) != chatToolCallKey(targetToolCall) {
                    continue
                }
                if let reason = imageFailureReason(from: tool.output) {
                    return reason
                }
            }
        }
        return nil
    }

}
