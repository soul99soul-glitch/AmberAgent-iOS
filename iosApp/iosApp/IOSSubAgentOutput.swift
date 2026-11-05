import Foundation
@preconcurrency import Shared

struct IOSSubAgentOutputStep: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let detail: String?
    let status: IOSAdvancedTaskStatus
}

struct IOSSubAgentOutputSnapshot: Codable, Equatable, Sendable {
    let summary: String
    let steps: [IOSSubAgentOutputStep]
    let isFinal: Bool
}

struct IOSSubAgentStructuredDigest: Codable, Equatable, Sendable {
    let conclusion: String
    let keyPoints: [String]
    let needsUserDecision: Bool
    let decisionPrompt: String?
    let deliverableHint: String?
    let checkpointPolicy: String?

    init(
        conclusion: String,
        keyPoints: [String] = [],
        needsUserDecision: Bool = false,
        decisionPrompt: String? = nil,
        deliverableHint: String? = nil,
        checkpointPolicy: String? = nil
    ) {
        self.conclusion = conclusion
        self.keyPoints = keyPoints
        self.needsUserDecision = needsUserDecision
        self.decisionPrompt = decisionPrompt
        self.deliverableHint = deliverableHint
        self.checkpointPolicy = checkpointPolicy
    }

    var formattedSummary: String {
        var lines: [String] = ["核心结论：\(conclusion)"]
        if let deliverableHint = deliverableHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !deliverableHint.isEmpty {
            lines.append("交付物：\(deliverableHint)")
        }
        if !keyPoints.isEmpty {
            lines.append("关键产出要点：")
            for point in keyPoints {
                lines.append("• \(point)")
            }
        }
        if needsUserDecision {
            if let prompt = decisionPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty,
               prompt != conclusion {
                lines.append("下一步拍板：需用户拍板（\(prompt)）")
            } else {
                lines.append("下一步拍板：需用户拍板确认下一步方向")
            }
        } else {
            lines.append("下一步拍板：无需额外拍板")
        }
        return lines.joined(separator: "\n")
    }

    func toMetadataDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "conclusion": conclusion,
            "key_points": keyPoints,
            "needs_user_decision": needsUserDecision,
            "formatted_summary": formattedSummary,
        ]
        if let decisionPrompt, !decisionPrompt.isEmpty {
            dict["decision_prompt"] = decisionPrompt
        }
        if let deliverableHint, !deliverableHint.isEmpty {
            dict["deliverable_hint"] = deliverableHint
        }
        if let checkpointPolicy, !checkpointPolicy.isEmpty {
            dict["checkpoint_policy"] = checkpointPolicy
        }
        return dict
    }
}

enum IOSSubAgentOutputProjection {
    static let progressReportingInstruction = "When the task permits progress updates, publish one or two concise sentences of verified work and useful findings in ordinary assistant text at meaningful checkpoints. Report completed work or a concrete blocker; do not expose private reasoning, invent progress, or narrate every tool call."
    static let maxSummaryLength = 1_000
    static let maxStepDetailLength = 100
    static let maxSteps = 4
    static let eventType = "subagent_public_output"

    static func snapshot(
        messages: [UIMessage],
        isFinal: Bool,
        fallbackSummary: String? = nil
    ) -> IOSSubAgentOutputSnapshot? {
        let steps = recentToolSteps(in: messages)
        let assistantText = messages
            .filter { $0.role == MessageRole.assistant }
            .flatMap(\.parts)
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .last
        let summary = bounded(assistantText ?? fallbackSummary ?? "", limit: maxSummaryLength) ?? ""
        guard !summary.isEmpty || !steps.isEmpty else { return nil }
        return IOSSubAgentOutputSnapshot(summary: summary, steps: steps, isFinal: isFinal)
    }

    static func generatedMessages(
        finalMessages: [UIMessage],
        displayMessages: [UIMessage]
    ) -> [UIMessage] {
        guard finalMessages.count >= displayMessages.count else { return [] }
        return Array(finalMessages.dropFirst(displayMessages.count))
    }

    static func snapshot(
        task: IOSAdvancedTaskRecord,
        liveText: String? = nil
    ) -> IOSSubAgentOutputSnapshot? {
        let isFinal = task.status.isTerminal
        let summary: String?
        if isFinal {
            summary = summaryFromStoredResult(task.resultSummary) ??
                bounded(task.error, limit: maxSummaryLength)
        } else {
            summary = bounded(liveText ?? "", limit: maxSummaryLength)
        }
        guard let summary, !summary.isEmpty else {
            return isFinal
                ? IOSSubAgentOutputSnapshot(summary: "", steps: [], isFinal: true)
                : nil
        }
        return IOSSubAgentOutputSnapshot(summary: summary, steps: [], isFinal: isFinal)
    }

    static func summaryFromStoredResult(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var pieces: [String] = []
            if let summary = object["summary"] as? String {
                pieces.append(summary)
            } else if let conclusion = object["conclusion"] as? String {
                pieces.append(conclusion)
            }
            if let findings = object["findings"] as? String {
                pieces.append(findings)
            } else if let findings = object["findings"] as? [Any] {
                pieces.append(contentsOf: findings.compactMap { $0 as? String })
            } else if let keyPoints = object["key_points"] as? [Any] {
                pieces.append(contentsOf: keyPoints.compactMap { $0 as? String })
            }
            if let needsDecision = object["needs_user_decision"] as? Bool, needsDecision {
                if let prompt = (object["decision_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !prompt.isEmpty {
                    pieces.append("需用户拍板：\(prompt)")
                } else {
                    pieces.append("需用户拍板确认下一步")
                }
            }
            let result = pieces
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return result.isEmpty ? nil : bounded(result, limit: maxSummaryLength)
        }
        // A truncated JSON report is not a safe structured value. Do not show
        // it as if it were a valid report; plain-text fallback output remains
        // public assistant text and is safe to display as bounded text.
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return nil }
        return bounded(trimmed, limit: maxSummaryLength)
    }

    static func structuredDigest(
        from raw: String,
        deliverableHint: String? = nil,
        checkpointPolicy: String? = nil
    ) -> IOSSubAgentStructuredDigest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "[run ended without assistant output]" else {
            return nil
        }
        let normalizedHint = deliverableHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHint = (normalizedHint?.isEmpty == false) ? normalizedHint : nil
        let normalizedPolicy = IOSOrchestrationCheckpointPolicy(rawPolicy: checkpointPolicy)?.rawValue
            ?? checkpointPolicy?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePolicy = (normalizedPolicy?.isEmpty == false) ? normalizedPolicy : nil
        let policyRequiresDecision = IOSOrchestrationCheckpointPolicy(rawPolicy: effectivePolicy) == .pauseForDecision

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let conclusionRaw = (object["conclusion"] as? String)
                ?? (object["summary"] as? String)
                ?? ""
            let conclusion = cleanLine(conclusionRaw)
            var keyPoints: [String] = []
            if let arr = (object["key_points"] as? [Any]) ?? (object["findings"] as? [Any]) {
                keyPoints = arr.compactMap { $0 as? String }.map(cleanLine).filter { !$0.isEmpty }
            } else if let str = (object["key_points"] as? String) ?? (object["findings"] as? String) {
                keyPoints = str.components(separatedBy: .newlines).map(cleanLine).filter { !$0.isEmpty }
            }
            guard !conclusion.isEmpty || !keyPoints.isEmpty else { return nil }
            let resolvedConclusion = conclusion.isEmpty ? keyPoints.removeFirst() : conclusion
            let explicitDecision = object["needs_user_decision"] as? Bool
            let decisionPrompt = cleanLine(
                (object["decision_prompt"] as? String) ?? (object["next_step"] as? String) ?? ""
            )
            let inferredDecision = detectDecisionSignal(in: trimmed)
            let needsDecision = explicitDecision ?? (policyRequiresDecision || inferredDecision.needsDecision)
            return IOSSubAgentStructuredDigest(
                conclusion: String(resolvedConclusion.prefix(240)),
                keyPoints: Array(keyPoints.prefix(4)).map { String($0.prefix(160)) },
                needsUserDecision: needsDecision,
                decisionPrompt: decisionPrompt.isEmpty ? inferredDecision.prompt : decisionPrompt,
                deliverableHint: effectiveHint ?? (object["deliverable_hint"] as? String),
                checkpointPolicy: effectivePolicy ?? (object["checkpoint_policy"] as? String)
            )
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return nil
        }

        let lines = stripCodeFences(from: trimmed)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isNoiseLogLine($0) }
        guard !lines.isEmpty else { return nil }

        var paragraphLines: [String] = []
        var bulletLines: [String] = []
        for line in lines {
            if let bullet = extractBulletText(from: line) {
                bulletLines.append(bullet)
            } else {
                let cleaned = cleanLine(line)
                if !cleaned.isEmpty, !isSectionHeaderOnly(cleaned) {
                    paragraphLines.append(cleaned)
                }
            }
        }

        let conclusionSource = paragraphLines.first ?? bulletLines.first ?? cleanLine(lines[0])
        guard !conclusionSource.isEmpty else { return nil }
        let conclusion = String(firstConciseStatement(from: conclusionSource, maxChars: 240))

        var keyPoints: [String] = []
        for item in bulletLines where item != conclusion {
            let concise = firstConciseStatement(from: item, maxChars: 160)
            if !concise.isEmpty, !keyPoints.contains(concise) {
                keyPoints.append(concise)
            }
            if keyPoints.count >= 4 { break }
        }
        if keyPoints.isEmpty, paragraphLines.count > 1 {
            for item in paragraphLines.dropFirst() where item != conclusion {
                let concise = firstConciseStatement(from: item, maxChars: 160)
                if !concise.isEmpty, !keyPoints.contains(concise) {
                    keyPoints.append(concise)
                }
                if keyPoints.count >= 4 { break }
            }
        }

        let decisionSignal = detectDecisionSignal(in: trimmed)
        let needsDecision = policyRequiresDecision || decisionSignal.needsDecision
        return IOSSubAgentStructuredDigest(
            conclusion: conclusion,
            keyPoints: keyPoints,
            needsUserDecision: needsDecision,
            decisionPrompt: decisionSignal.prompt,
            deliverableHint: effectiveHint,
            checkpointPolicy: effectivePolicy
        )
    }

    static func structuredResultSummary(
        from raw: String,
        deliverableHint: String? = nil,
        checkpointPolicy: String? = nil
    ) -> String? {
        guard let digest = structuredDigest(
            from: raw,
            deliverableHint: deliverableHint,
            checkpointPolicy: checkpointPolicy
        ) else {
            return summaryFromStoredResult(raw)
        }
        return bounded(digest.formattedSummary, limit: maxSummaryLength)
    }

    @MainActor
    @discardableResult
    static func syncTaskResultSummary(
        in taskStore: IOSAdvancedTaskStore,
        childThreadId: String? = nil,
        runId: String? = nil,
        taskId: String? = nil,
        rawText: String,
        deliverableHint: String? = nil,
        checkpointPolicy: String? = nil,
        status: IOSAdvancedTaskStatus? = nil
    ) -> IOSAdvancedTaskRecord? {
        guard let formatted = structuredResultSummary(
            from: rawText,
            deliverableHint: deliverableHint,
            checkpointPolicy: checkpointPolicy
        ) else {
            return nil
        }
        let targetRecord = taskStore.tasks.first { record in
            if let taskId, record.id == taskId { return true }
            if let childThreadId {
                if record.id == childThreadId || record.metadata["child_thread_id"] == childThreadId {
                    return true
                }
            }
            if let runId {
                if record.id == runId || record.metadata["run_id"] == runId || record.metadata["execution_id"] == runId {
                    return true
                }
            }
            return false
        }
        guard let targetRecord else { return nil }
        var extraMetadata: [String: String] = [:]
        if let digest = structuredDigest(from: rawText, deliverableHint: deliverableHint, checkpointPolicy: checkpointPolicy) {
            extraMetadata["needs_user_decision"] = digest.needsUserDecision ? "true" : "false"
            if let hint = digest.deliverableHint { extraMetadata["deliverable_hint"] = hint }
            if let policy = digest.checkpointPolicy { extraMetadata["checkpoint_policy"] = policy }
        }
        return taskStore.updateTask(
            id: targetRecord.id,
            status: status,
            resultSummary: formatted,
            metadata: extraMetadata.isEmpty ? nil : extraMetadata
        )
    }

    private static func stripCodeFences(from text: String) -> String {
        var result: [String] = []
        var insideFence = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if !insideFence {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func isNoiseLogLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("[tool") || lower.hasPrefix("tool_call:") || lower.hasPrefix("step ")
            || line == "---" || line == "***"
    }

    private static func isSectionHeaderOnly(_ line: String) -> Bool {
        let normalized = line.replacingOccurrences(of: "：", with: ":").trimmingCharacters(in: .whitespaces)
        return ["核心结论", "核心结论:", "结论", "结论:", "关键要点", "关键要点:", "关键产出要点", "关键产出要点:", "总结", "总结:"].contains(normalized)
    }

    private static func extractBulletText(from line: String) -> String? {
        let prefixes = ["- ", "* ", "• ", "· "]
        for prefix in prefixes where line.hasPrefix(prefix) {
            let body = cleanLine(String(line.dropFirst(prefix.count)))
            return body.isEmpty ? nil : body
        }
        if let range = line.range(of: #"^\d+[\.\、\)]\s*"#, options: .regularExpression) {
            let body = cleanLine(String(line[range.upperBound...]))
            return body.isEmpty ? nil : body
        }
        return nil
    }

    private static func cleanLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") || text.hasPrefix(">") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        for prefix in ["核心结论：", "核心结论:", "结论：", "结论:", "总结：", "总结:"] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    private static func firstConciseStatement(from text: String, maxChars: Int) -> String {
        let cleaned = cleanLine(text)
        guard cleaned.count > maxChars else { return cleaned }
        return String(cleaned.prefix(maxChars))
    }

    private static func detectDecisionSignal(in text: String) -> (needsDecision: Bool, prompt: String?) {
        let decisionKeywords = [
            "需要你拍板", "需要您拍板", "请拍板", "待你拍板", "待您拍板",
            "待你确认", "待您确认", "请确认下一步", "需要你决定", "需要您决定",
            "请选择下一步", "是否继续深入", "pause_for_decision"
        ]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = cleanLine(rawLine)
            guard !line.isEmpty else { continue }
            if decisionKeywords.contains(where: { line.contains($0) }) {
                return (true, String(line.prefix(140)))
            }
        }
        return (false, nil)
    }

    private static func recentToolSteps(in messages: [UIMessage]) -> [IOSSubAgentOutputStep] {
        var seen = Set<String>()
        let tools = messages
            .filter { $0.role == MessageRole.assistant }
            .flatMap(\.parts)
            .compactMap { $0 as? UIMessagePart.Tool }
            .filter { tool in
                tool.toolCallId.isEmpty || seen.insert(tool.toolCallId).inserted
            }
        return tools.suffix(maxSteps).enumerated().map { index, tool in
            let executed = !tool.output.isEmpty
            let failure = ChatToolOutputFormatter.failureReason(from: tool.output)
            let status: IOSAdvancedTaskStatus
            if !executed {
                status = tool.approvalState is ToolApprovalState.Pending ? .approvalRequired : .running
            } else if outputStatus(in: tool.output) == "cancelled" {
                status = .cancelled
            } else if outputStatus(in: tool.output) == "interrupted" {
                status = .interrupted
            } else if failure != nil {
                status = .failed
            } else {
                status = .completed
            }
            let title = ChatToolStepModel.friendlyToolTitle(tool.toolName, executed: executed)
            let detail = safeDetail(for: tool)
            return IOSSubAgentOutputStep(
                id: tool.toolCallId.isEmpty ? "tool-\(index)" : tool.toolCallId,
                title: title,
                detail: detail,
                status: status
            )
        }
    }

    private static func safeDetail(for tool: UIMessagePart.Tool) -> String? {
        let name = tool.toolName
        guard !tool.output.isEmpty else { return nil }
        if let failure = ChatToolOutputFormatter.failureReason(from: tool.output) {
            return bounded(failure, limit: maxStepDetailLength)
        }
        // Subagent/task inputs are intentionally not copied into the detail;
        // the report/assistant text is the public output for those calls.
        if name == "subagent_dispatch" || name == "subagent_report"
            || name == "spawn_agent" || name == "followup_task" {
            return nil
        }
        let allowed = name == "search_web"
            || name == "scrape_web"
            || name == "file_read_selected"
            || name == "permissions_status"
            || name == "runtime_status"
            || name == "tools_list"
            || name.hasPrefix("workspace_")
            || name.hasPrefix("wm_")
        guard allowed else { return nil }
        let model = ChatToolStepModel(tool: tool)
        return bounded(model.detail, limit: maxStepDetailLength)
    }

    private static func outputStatus(in output: [UIMessagePart]) -> String? {
        for text in output.compactMap({ ($0 as? UIMessagePart.Text)?.text }) {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = object["status"] as? String else { continue }
            return status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return nil
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(limit))
    }
}

@MainActor
enum IOSSubAgentOutputLoader {
    static func load(
        activity: IOSSubAgentActivity,
        task: IOSAdvancedTaskRecord?
    ) async throws -> IOSSubAgentOutputSnapshot? {
        if activity.id.hasPrefix("task:") {
            guard let task else { return nil }
            if task.status.isTerminal,
               let encoded = task.metadata["public_output"],
               let data = encoded.data(using: .utf8),
               let stored = try? JSONDecoder().decode(IOSSubAgentOutputSnapshot.self, from: data) {
                return stored
            }
            let executionId = task.metadata["execution_id"]
            let toolCallId = task.metadata["tool_call_id"]
            if !task.status.isTerminal,
               let toolCallId,
               let model = SubAgentLiveRegistry.shared.model(
                    forToolCallId: toolCallId,
                    executionId: executionId
               ) {
                return model.publicOutputSnapshot
                    ?? IOSSubAgentOutputProjection.snapshot(task: task, liveText: model.text)
            }
            return IOSSubAgentOutputProjection.snapshot(task: task)
        }

        guard activity.id.hasPrefix("run:") else { return nil }
        let runId = String(activity.id.dropFirst("run:".count))
        // The terminal archive may arrive while Live Activity teardown still
        // retains the old job. Prefer that final snapshot over its live copy.
        if activity.canDismiss, let final = try await IOSSubAgentOutputArchive.load(runId: runId) {
            return final
        }
        if let live = IOSChatBackgroundGenerationCoordinator.shared
            .subAgentPublicOutput(runId: runId) {
            return live
        }
        if activity.canDismiss { return nil }
        return try await IOSSubAgentOutputArchive.load(runId: runId)
    }
}

@MainActor
enum IOSSubAgentOutputArchive {
    private static let eventPrefix = "subagent-public-output:"
    private static let sharedDatabase = IosDatabaseFactory.shared.createDatabase()

    static func archive(
        runId: String,
        conversationId: KotlinUuid,
        snapshot: IOSSubAgentOutputSnapshot,
        database: AgentRuntimeDatabase? = nil
    ) async {
        let database = database ?? sharedDatabase
        let child = await withCheckedContinuation { continuation in
            database.threadEdgeDao().edgeFor(childThreadId: conversationId.toHexDashString()) { @Sendable edge, error in
                continuation.resume(returning: error == nil && edge != nil)
            }
        }
        guard child else { return }
        guard let data = try? JSONEncoder().encode(snapshot),
              let payload = String(data: data, encoding: .utf8) else { return }
        let event = AgentRunEvent(
            eventId: eventPrefix + runId,
            type: IOSSubAgentOutputProjection.eventType,
            payloadType: IOSSubAgentOutputProjection.eventType,
            payload: payload,
            payloadSchemaVersion: 1,
            isFinal: false,
            ts: Int64(Date().timeIntervalSince1970 * 1_000),
            turnId: nil,
            stepId: nil,
            toolCallId: nil
        )
        let store = RoomAgentEventStore(dao: database.agentRuntimeDao())
        let inserted = await withCheckedContinuation { continuation in
            store.appendRunEvent(runId: runId, event: event) { @Sendable value, error in
                continuation.resume(returning: error == nil && (value?.boolValue ?? false))
            }
        }
        if inserted {
            NotificationCenter.default.post(name: .amberSubAgentRunsDidChange, object: nil)
        }
    }

    static func load(runId: String, database: AgentRuntimeDatabase? = nil) async throws -> IOSSubAgentOutputSnapshot? {
        let database = database ?? sharedDatabase
        let payload: String? = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String?, Error>) in
            database.agentRuntimeDao().listEventsForRun(id: runId) { @Sendable rows, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: rows?.last(where: {
                    $0.type == IOSSubAgentOutputProjection.eventType
                })?.payload)
            }
        }
        guard let payload,
              let data = payload.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(IOSSubAgentOutputSnapshot.self, from: data)
    }
}
