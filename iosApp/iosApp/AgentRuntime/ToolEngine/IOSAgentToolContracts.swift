import Foundation
@preconcurrency import Shared

// MARK: - Multi-turn tool execution engine
//
// A reusable Swift-side engine that runs a model ↔ tool execution loop:
//
//   call model → extract pending tool calls → execute each via the registry
//   → fill tool outputs in place → call model again, until no tool calls
//   remain or maxSteps is reached.
//
// This generalizes the ad-hoc single-tool-per-round loop that `ChatViewModel`
// hard-codes for the chat surface (maxToolResumeCount, messagesByFinishingToolCall,
// pendingXxxToolCall). SubAgent, Deep Read, and a more robust chat tool flow
// all build on it. It implements Amber's multi-turn model/tool semantics —
// batch execution and approval pauses — while reusing KMP message/part mechanics that
// already work on iOS.
//
// No KMP changes: `UIMessagePart.Tool`, `UIMessage`, `MessageChunk`,
// `ToolApprovalState`, and `TextGenerationParams` are all commonMain types
// already exposed via Shared.framework.

/// Outcome of executing a single tool call inside the engine.
///
/// NOTE: deliberately named `IOSAgentToolOutcome` (not `IOSToolExecutionResult`)
/// to avoid colliding with the pre-existing `IOSToolExecutionResult` enum in
/// `DocumentAccessStore.swift`, which models the local-tool-executor surface
/// (selectedFilePreview / workspaceResult / etc.) and is a different concept.
public enum IOSAgentToolOutcome: Sendable {
    /// Tool produced a JSON/text result string (the same shape `ChatViewModel`
    /// feeds into `messagesByFinishingToolCall(outputText:)`).
    case filled(String)
    /// Tool produced structured parts (e.g. an image part). Engine wraps them
    /// as the tool's output list.
    case filledParts([UIMessagePart])
    /// Tool returned fresh context after human control. Preserve its output,
    /// resolve the rest of this batch as not sent, and let the provider replan.
    case replanRequired([UIMessagePart])
    /// Tool needs foreground user approval before it can run. The engine
    /// pauses and surfaces this so the caller can resume after approval.
    case needsApproval(String)
    /// Tool was denied (policy/capability gate). Output is an honest denial
    /// string rather than an error.
    case denied(String)
    /// Tool failed to execute. Output is an honest failure string.
    case failed(String)
    /// A nested durable transaction could not record its terminal after the
    /// underlying side effect returned. The engine must not publish output or
    /// request another provider round.
    case durabilityFailure(String)
    /// The executor dispatched a side effect, then lost the ability to verify
    /// whether it applied. The engine must persist the unknown state and stop;
    /// it must never ask the provider for another round or replay the call.
    case outcomeUnknown([UIMessagePart])
}

public struct IOSToolOutcomeUnknownSignal: Sendable, Equatable {
    public let toolCallId: String
    public let toolName: String

    public init(toolCallId: String, toolName: String) {
        self.toolCallId = toolCallId
        self.toolName = toolName
    }
}

/// A single tool executor. The engine routes a pending `UIMessagePart.Tool`
/// to the registered executor by `toolName`. Implementations are thin adapters
/// over the existing Swift executors (search / workspace / webmount / memory /
/// image / mcp / subagent / council) — they must NOT block the caller on UI;
/// approval is communicated via `.needsApproval`.
public protocol IOSToolExecutor: AnyObject {
    func execute(
        name: String,
        arguments: String,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome

    /// P0-2 B2: 携带完整 Tool(含 toolCallId)的执行入口。**必须是协议要求**
    /// (带默认实现)而不是纯扩展方法——纯扩展方法在 `any IOSToolExecutor`
    /// 存在类型上静态派发,具体实现永远不会被调到。默认转发三参版本,现有
    /// 执行器零改动;需要 toolCallId 的实现(前台内核适配器——审批盒与回填
    /// 都按 toolCallId 键控)覆盖此方法,引擎经 witness table 动态派发到它。
    func execute(
        tool: UIMessagePart.Tool,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome
}

extension IOSToolExecutor {
    public func execute(
        tool: UIMessagePart.Tool,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        await execute(
            name: tool.toolName,
            arguments: tool.input,
            isUserInitiated: isUserInitiated
        )
    }
}

/// Abstraction over the model call so the engine is unit-testable without a
/// live HTTP provider. `OpenAIKmpProviderAdapter` wraps the real KMP provider
/// and dispatches to the OpenAI or Claude executor based on the provider's
/// sealed type; tests inject a scripted provider.
public protocol IOSAgentTextProvider: Sendable {
    /// Non-streaming generation. Returns the full message chunk (which may
    /// contain assistant text and/or tool calls in `choices[].message.parts`).
    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk

}

/// Optional streaming capability — only the real provider adapter conforms. The
/// engine uses it for live subagent token streaming; non-streaming conformers
/// (e.g. test doubles) fall back to a blocking `generateText` with no live
/// tokens, and the engine loop behaves identically.
public protocol IOSAgentStreamingProvider: Sendable {
    func prepareRequest(
        providerSetting: ProviderSetting,
        params: TextGenerationParams
    ) async throws -> (ProviderSetting, TextGenerationParams)

    func supportsStreaming(providerSetting: ProviderSetting) -> Bool

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onChunk: @escaping @Sendable (MessageChunk) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (KotlinThrowable) -> Void
    ) -> Kotlinx_coroutines_coreJob?
}

public extension IOSAgentStreamingProvider {
    func prepareRequest(
        providerSetting: ProviderSetting,
        params: TextGenerationParams
    ) async throws -> (ProviderSetting, TextGenerationParams) {
        (providerSetting, params)
    }

    func supportsStreaming(providerSetting: ProviderSetting) -> Bool { true }
}

/// Process-wide KMP providers. Each provider lazily owns its Ktor client, so a
/// fresh instance per run or call re-pays DNS/TCP/TLS on every request. The
/// providers hold no per-request state, and Ktor clients are safe to share.

public struct IOSAgentToolEngineResult: Sendable {
    /// The message list after the loop completed (tools executed, outputs
    /// filled in place). Includes the final assistant turn.
    public let messages: [UIMessage]
    /// Number of model round-trips performed.
    public let stepsExecuted: Int
    /// A tool that requested foreground approval and paused the loop, if any.
    /// The caller resolves approval and re-invokes the engine to continue.
    public let pendingApproval: IOSPendingToolApproval?
    /// Whether the loop ended because `maxSteps` was reached while tool calls
    /// were still pending (the caller may treat this as a soft failure).
    public let hitStepLimit: Bool
    /// Provider failure captured by the engine. Callers that own a durable run
    /// can map this to their normal failure terminal instead of parsing the
    /// compatibility transcript message appended below.
    public let providerFailureMessage: String?
    /// Durable tool-terminal write failure. The executor may already have
    /// produced a side effect, so callers must stop and keep the run
    /// recoverable instead of treating this as an ordinary provider failure.
    public let durabilityFailureMessage: String?
    /// A side-effect call whose result cannot be inferred. Its output is
    /// already present in `messages`; callers must surface user reconciliation.
    public let toolOutcomeUnknown: IOSToolOutcomeUnknownSignal?
    /// Whether the provider terminated because its output budget was exhausted.
    /// This remains distinct from transport/provider failures even though both
    /// keep `providerFailureMessage` for the existing user-facing message.
    public let hitOutputLimit: Bool
    /// Whether the caller cancelled the run while the provider was in flight.
    public let wasCancelled: Bool
    /// I-5: the loop ended because `IOSToolLoopGuard` detected the model
    /// repeating an identical tool call a 3rd time and stopped the run.
    /// Distinct from `hitStepLimit` — this is "the model was stuck", not "the
    /// budget ran out" — so callers must not fold it into a normal-completion
    /// terminal (see docs/IOS_AGENT_HARDENING_PLAN_2026-07-29.md §W5, I-5).
    public let guardStopped: Bool
    /// A foreground root's `wait_agent` yielded its run back to the host so
    /// queued user input can start a fresh turn. Background wait results never
    /// set this flag.
    public let yielded: Bool

    public init(
        messages: [UIMessage],
        stepsExecuted: Int,
        pendingApproval: IOSPendingToolApproval?,
        hitStepLimit: Bool,
        providerFailureMessage: String? = nil,
        durabilityFailureMessage: String? = nil,
        toolOutcomeUnknown: IOSToolOutcomeUnknownSignal? = nil,
        hitOutputLimit: Bool = false,
        wasCancelled: Bool = false,
        guardStopped: Bool = false,
        yielded: Bool = false
    ) {
        self.messages = messages
        self.stepsExecuted = stepsExecuted
        self.pendingApproval = pendingApproval
        self.hitStepLimit = hitStepLimit
        self.providerFailureMessage = providerFailureMessage
        self.durabilityFailureMessage = durabilityFailureMessage
        self.toolOutcomeUnknown = toolOutcomeUnknown
        self.hitOutputLimit = hitOutputLimit
        self.wasCancelled = wasCancelled
        self.guardStopped = guardStopped
        self.yielded = yielded
    }
}

/// A tool call that needs foreground approval before the engine can continue.
public struct IOSPendingToolApproval: Sendable {
    public let toolCallId: String
    public let toolName: String
    public let arguments: String
    public let reason: String
}

/// P1-d: mailbox drain 的返回盒。KMP `UIMessage` 非 Sendable，@MainActor 闭包
/// 不能把 `[UIMessage]` 返回到 nonisolated 引擎上下文——照
/// `IOSChatBackgroundRetryMessages` 先例用 @unchecked Sendable 盒跨边界
/// （drain 闭包内不可变，引擎拿到后只读展开）。
public struct IOSMailboxDrainResult: @unchecked Sendable {
    /// drain 后应作为下一轮 working 的消息列表（含渲染信封追加）。
    public let values: [UIMessage]

    public init(values: [UIMessage]) {
        self.values = values
    }
}


// Immutable crossing from a provider step to its MainActor transport.
struct UncheckedUIMessageBox: @unchecked Sendable {
    let value: [UIMessage]
    init(_ value: [UIMessage]) { self.value = value }
}


/// A model-only first-round signal. Hold partial prefixes while streaming so
/// neither the complete marker nor a split fragment flashes in chat.
enum IOSAssistantContinuationMarker {
    static let token = "<amber-continue/>"
    private static let opening = "<amber-continue"
    private static let closing = "</amber-continue>"
    private static let stagesAttribute = try! NSRegularExpression(pattern: #"\bstages\s*=\s*([\"'])(.*?)\1"#)

    private struct Parsed {
        var ranges: [NSRange] = []
        var stages: [String] = []
        var hasCompleteMarker = false
    }

    private static func parse(_ text: String, final: Bool) -> Parsed {
        let source = text as NSString
        let prefixLength = (opening as NSString).length
        var result = Parsed()
        var cursor = 0
        while cursor < source.length {
            let found = source.range(of: opening, options: [],
                                     range: NSRange(location: cursor, length: source.length - cursor))
            guard found.location != NSNotFound else { break }
            let afterName = NSMaxRange(found)
            if afterName < source.length {
                let character = source.character(at: afterName)
                guard character == 0x3E || character == 0x2F || character == 0x20 ||
                        character == 0x09 || character == 0x0A || character == 0x0D else {
                    cursor = afterName
                    continue
                }
            }
            let end = source.range(of: ">", options: [],
                                   range: NSRange(location: afterName, length: source.length - afterName))
            guard end.location != NSNotFound else {
                result.ranges.append(NSRange(location: found.location, length: source.length - found.location))
                cursor = source.length
                break
            }
            let header = source.substring(with: NSRange(location: found.location, length: NSMaxRange(end) - found.location))
            let selfClosing = header.dropLast().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
            let markerEnd: Int
            var stageText: String?
            if selfClosing {
                markerEnd = NSMaxRange(end)
                let headerRange = NSRange(location: 0, length: (header as NSString).length)
                if let match = stagesAttribute.firstMatch(in: header, range: headerRange), match.numberOfRanges > 2 {
                    stageText = (header as NSString).substring(with: match.range(at: 2))
                }
            } else {
                let contentStart = NSMaxRange(end)
                let close = source.range(of: closing, options: [],
                                         range: NSRange(location: contentStart, length: source.length - contentStart))
                guard close.location != NSNotFound else {
                    result.ranges.append(NSRange(location: found.location, length: source.length - found.location))
                    cursor = source.length
                    break
                }
                markerEnd = NSMaxRange(close)
                stageText = source.substring(with: NSRange(location: contentStart, length: close.location - contentStart))
            }
            result.hasCompleteMarker = true
            result.ranges.append(NSRange(location: found.location, length: markerEnd - found.location))
            if let stageText, result.stages.isEmpty {
                result.stages = stageText.split(separator: "|", omittingEmptySubsequences: true).prefix(3).compactMap { item in
                    let clean = item.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty, !clean.contains("<"), !clean.contains(">") else { return nil }
                    let normalized = clean.hasPrefix("正在") ? clean : "正在" + clean
                    return String(normalized.prefix(14))
                }
            }
            cursor = markerEnd
        }
        // A prefix may span arbitrary streaming chunks or text parts.
        if cursor < source.length {
            let limit = min(prefixLength - 1, source.length - cursor)
            if limit > 0 {
                for length in stride(from: limit, through: 1, by: -1) {
                    if text.hasSuffix(String(opening.prefix(length))) && (!final || length >= 6) {
                        result.ranges.append(NSRange(location: source.length - length, length: length))
                        break
                    }
                }
            }
        }
        return result
    }

    static func contains(in message: UIMessage?) -> Bool {
        guard let message else { return false }
        return parse(message.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(), final: true).hasCompleteMarker
    }

    static func stages(in message: UIMessage?) -> [String] {
        guard let message else { return [] }
        return parse(message.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(), final: true).stages
    }

    private static func removalRanges(in text: String, final: Bool) -> [NSRange] {
        parse(text, final: final).ranges
    }

    private static func mayContainMarker(_ text: String) -> Bool {
        if text.contains(opening) { return true }
        let tail = text.suffix(opening.count - 1)
        guard let start = tail.lastIndex(of: "<") else { return false }
        return opening.hasPrefix(tail[start...])
    }

    static func filteredText(_ text: String, final: Bool) -> String {
        guard mayContainMarker(text) else { return text }
        let ranges = removalRanges(in: text, final: final)
        guard !ranges.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for range in ranges.reversed() { result.deleteCharacters(in: range) }
        return result as String
    }

    static func filteredMessage(_ message: UIMessage, final: Bool) -> UIMessage {
        guard message.parts.contains(where: {
            guard let text = $0 as? UIMessagePart.Text else { return false }
            return mayContainMarker(text.text)
        }) else { return message }
        let joined = message.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
        let ranges = removalRanges(in: joined, final: final)
        guard !ranges.isEmpty else { return message }
        var offset = 0
        let parts = message.parts.map { part -> UIMessagePart in
            guard let text = part as? UIMessagePart.Text else { return part }
            let length = (text.text as NSString).length
            let partRange = NSRange(location: offset, length: length)
            offset += length
            let filtered = NSMutableString(string: text.text)
            for range in ranges.reversed() {
                let overlap = NSIntersectionRange(partRange, range)
                if overlap.length > 0 {
                    filtered.deleteCharacters(in: NSRange(location: overlap.location - partRange.location, length: overlap.length))
                }
            }
            guard filtered as String != text.text else { return part }
            return PromptTranscript.shared.doCopyText(part: text, text: filtered as String)
        }
        return UIMessage(id: message.id, role: message.role, parts: parts,
                         annotations: message.annotations, createdAt: message.createdAt,
                         finishedAt: message.finishedAt, modelId: message.modelId,
                         usage: message.usage, translation: message.translation)
    }
}

extension TextGenerationParams {
    func replacingReasoningLevel(_ level: ReasoningLevel) -> TextGenerationParams {
        TextGenerationParams(model: model, temperature: temperature, topP: topP, maxTokens: maxTokens,
                             tools: tools, reasoningLevel: level, customHeaders: customHeaders, customBody: customBody)
    }

    /// P0-a: a copy of these params carrying a different tool declaration list.
    /// Kotlin data-class default args don't bridge to Swift, so rebuild all
    /// fields explicitly (same shape makeTextGenerationParams uses).
    func replacingTools(_ tools: [Tool]) -> TextGenerationParams {
        TextGenerationParams(
            model: model,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            tools: tools,
            reasoningLevel: reasoningLevel,
            customHeaders: customHeaders,
            customBody: customBody
        )
    }
}
