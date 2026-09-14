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
            }
            if let findings = object["findings"] as? String {
                pieces.append(findings)
            } else if let findings = object["findings"] as? [Any] {
                pieces.append(contentsOf: findings.compactMap { $0 as? String })
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
