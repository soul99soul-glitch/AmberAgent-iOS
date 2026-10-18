import XCTest
import Combine
import SwiftUI
import CoreText
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

/// Task B: consecutive phone-automation steps project into one collapsible row
/// whose identity never changes while the run grows.
@MainActor
final class ChatPhoneToolGroupingTests: XCTestCase {
    private func assistant(_ parts: [UIMessagePart], finished: Bool = true) -> UIMessage {
        UIMessage(id: KotlinUuid.companion.random(), role: MessageRole.assistant, parts: parts, annotations: [],
            createdAt: chatNowLocalDateTime(), finishedAt: finished ? chatNowLocalDateTime() : nil,
            modelId: nil, usage: nil, translation: nil)
    }

    private func phone(
        _ id: String,
        name: String = "phone_act",
        result: String? = #"{"outcome":"completed","fresh_observation_available":true}"#,
        approval: ToolApprovalState = ToolApprovalState.Auto.shared,
        input: String = #"{"action":"tap"}"#
    ) -> UIMessagePart.Tool {
        UIMessagePart.Tool(toolCallId: id, toolName: name, input: input,
            output: result.map { [UIMessagePart.Text(text: $0, metadata: nil)] } ?? [],
            approvalState: approval, streamIndex: nil, metadata: nil)
    }

    private func reasoning(_ text: String = "思考下一步") -> UIMessagePart.Reasoning {
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        return UIMessagePart.Reasoning(reasoning: text, createdAt: instant, finishedAt: instant, metadata: nil)
    }

    private func id(_ message: UIMessage) -> String { ChatMessageProjector.messageId(for: message) }

    private func project(
        _ messages: [UIMessage],
        event: ChatEvent = .toolResultAppended,
        expanded: Set<String> = [],
        generating: Bool = false,
        startIndex: Int = 0,
        variants: [Int: Int] = [:]
    ) -> NativeTimelineProjection {
        let hashes = ChatRowContentHashCache()
        return NativeTimelineProjector.build(
            messages: messages, event: event, isGenerationActive: generating,
            variantInfoProvider: { index in
                variants[index].map { IOSConversationStore.VariantInfo(variantCount: $0, selectedIndex: 0) }
            },
            contentHashProvider: { row, streaming in
                streaming ? hashes.streamingTailLayoutToken(for: row) : hashes.contentHash(for: row)
            },
            startIndex: startIndex,
            expandedPhoneToolGroupIDs: expanded
        )
    }

    private func messageEntries(_ projection: NativeTimelineProjection) -> [NativeTimelineEntry] {
        projection.entries.filter { $0.kind == .message }
    }

    func testGroupingBoundaries() throws {
        let messages = [
            UIMessage.companion.user(prompt: "打开设置"),
            assistant([reasoning(), phone("call_0")]),
            assistant([phone("call_1", name: "phone_observe")]),
            assistant([reasoning()]),                                   // reasoning-only: stays in the run
            assistant([phone("call_2"), UIMessagePart.Text(text: "  \n", metadata: nil)]),
            assistant([UIMessagePart.Text(text: "已打开设置。", metadata: nil)]), // text breaks
            assistant([phone("call_0")]),                               // provider ids repeat
            assistant([UIMessagePart.Tool(toolCallId: "web", toolName: "search_web", input: "{}", output: [],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)]), // other tool breaks
            assistant([phone("call_0")]),
            UIMessage.companion.user(prompt: "继续"),                   // user breaks
            assistant([phone("d1"), UIMessagePart.Text(text: "顺便说明", metadata: nil)]) // phone + text: own row
        ]
        let entries = messageEntries(project(messages))
        XCTAssertEqual(entries.count, messages.count, "grouping never removes or re-keys entries")
        XCTAssertNil(entries[0].phoneToolGroup)
        let head = try XCTUnwrap(entries[1].phoneToolGroup?.headSummary)
        XCTAssertEqual(head.id, id(messages[1]), "keyed on the first message UUID")
        XCTAssertEqual(head.anchorID, "phone-tool-group-" + id(messages[1]))
        XCTAssertEqual(head.stepCount, 3)
        XCTAssertEqual(head.latestTool.toolCallId, "call_2")
        XCTAssertFalse(head.isExpanded)
        for index in 2...4 {
            XCTAssertEqual(entries[index].phoneToolGroup, .member(groupID: head.id, isExpanded: false))
            XCTAssertTrue(entries[index].phoneToolGroup?.isCollapsedMember == true)
        }
        XCTAssertNil(entries[5].phoneToolGroup)
        XCTAssertEqual(entries[6].phoneToolGroup?.headSummary?.stepCount, 1)
        XCTAssertEqual(entries[6].phoneToolGroup?.headSummary?.id, id(messages[6]))
        XCTAssertNil(entries[7].phoneToolGroup)
        XCTAssertEqual(entries[8].phoneToolGroup?.headSummary?.id, id(messages[8]))
        XCTAssertNotEqual(entries[6].phoneToolGroup?.groupID, entries[8].phoneToolGroup?.groupID,
                          "repeated provider toolCallIds never collide")
        XCTAssertNil(entries[9].phoneToolGroup)
        XCTAssertNil(entries[10].phoneToolGroup)
        // Leading reasoning-only messages never start a run.
        let leading = [assistant([reasoning()]), assistant([phone("x1")])]
        let leadingEntries = messageEntries(project(leading))
        XCTAssertNil(leadingEntries[0].phoneToolGroup)
        XCTAssertEqual(leadingEntries[1].phoneToolGroup?.headSummary?.id, id(leading[1]))
    }

    /// Variant switchers, citations and the message context menu must stay reachable.
    func testVariantsAndCitationsBreakTheRun() throws {
        let cited = UIMessage(id: KotlinUuid.companion.random(), role: MessageRole.assistant,
            parts: [phone("v2")], annotations: [UIMessageAnnotation.UrlCitation(title: "来源", url: "https://example.com")],
            createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(), modelId: nil, usage: nil, translation: nil)
        let messages = [UIMessage.companion.user(prompt: "go"), assistant([phone("v1")]), assistant([phone("v-regen")]),
                        cited, assistant([phone("v3")])]
        XCTAssertEqual(ChatPhoneToolGrouping.membership(of: cited), .breaking)
        let entries = messageEntries(project(messages, variants: [2: 2]))
        XCTAssertEqual(entries[1].phoneToolGroup?.headSummary?.stepCount, 1)
        XCTAssertNil(entries[2].phoneToolGroup, "a regenerated step keeps its variant switcher")
        XCTAssertNil(entries[3].phoneToolGroup, "a cited step keeps its citations")
        XCTAssertEqual(entries[4].phoneToolGroup?.headSummary?.id, id(messages[4]))
    }

    /// The loaded history window (~60 messages) must not truncate a long run:
    /// id, step count and start time come from the run's true first message, and
    /// revealing earlier history keeps the group id (and its expanded state).
    func testRunStartingBeforeTheHistoryWindowKeepsIdentityCountAndStart() throws {
        var messages = [UIMessage.companion.user(prompt: "长自动化")]
        for index in 0..<100 {
            messages.append(index % 10 == 9 ? assistant([reasoning()]) : assistant([phone("call_\(index % 3)")]))
        }
        let totalSteps = 90
        let trueFirst = messages[1]
        // Window starts on a reasoning-only member of the run.
        let windowStart = messages.count - 60
        XCTAssertEqual(ChatPhoneToolGrouping.membership(of: messages[windowStart]), .phone)
        let neutralStart = 10 // messages[10] is reasoning-only (index 9 of the loop)
        XCTAssertEqual(ChatPhoneToolGrouping.membership(of: messages[neutralStart]), .neutral)

        for start in [windowStart, neutralStart, 0] {
            for expanded in [Set<String>(), [id(trueFirst)]] {
                let entries = messageEntries(project(messages, expanded: expanded, startIndex: start))
                let heads = entries.compactMap { $0.phoneToolGroup?.headSummary }
                XCTAssertEqual(heads.count, 1, "start=\(start)")
                let head = try XCTUnwrap(heads.first)
                XCTAssertEqual(head.id, id(trueFirst), "start=\(start): id from the true first message")
                XCTAssertEqual(head.stepCount, totalSteps, "start=\(start): steps before the window count")
                XCTAssertEqual(head.startedAt, ChatImageGenerationResumeProjection.date(from: trueFirst.createdAt))
                XCTAssertEqual(head.isExpanded, !expanded.isEmpty)
                let headEntry = try XCTUnwrap(entries.first { $0.phoneToolGroup?.headSummary != nil })
                XCTAssertEqual(ChatPhoneToolGrouping.membership(of: try XCTUnwrap(headEntry.message)), .phone,
                               "the header is drawn by a loaded phone step")
                XCTAssertTrue(entries.filter { $0.role == MessageRole.assistant }.allSatisfy { $0.phoneToolGroup != nil },
                              "every loaded assistant message is in the run")
            }
        }
        // The regrouping pass (run per streaming delta while a run is live) stays cheap,
        // including the backward scan over the part of the run outside the window.
        var windowEntries = project(messages, startIndex: windowStart).entries
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<20 {
            ChatPhoneToolGrouping.annotate(&windowEntries, messages: messages, expandedGroupIDs: [],
                                           isGenerationActive: true)
        }
        let perPassMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000 / 20
        print("[PERF-PHONE-GROUP] annotate 60-row window of a 90-step run: \(perPassMs)ms/pass")
        XCTAssertLessThan(perPassMs, 8)

        // A configuration notice above the first row is not between steps.
        let withNotice = NativeTimelineProjector.build(messages: messages, event: .toolResultAppended,
            configurationIssue: .missingProvider, startIndex: windowStart)
        XCTAssertEqual(withNotice.entries.first?.kind, .configurationIssue(compact: true))
        let noticeHead = try XCTUnwrap(withNotice.entries.compactMap { $0.phoneToolGroup?.headSummary }.first)
        XCTAssertEqual(noticeHead.id, id(trueFirst))
        XCTAssertEqual(noticeHead.stepCount, totalSteps)

        // Render identity of already-loaded rows is unchanged by revealing history.
        let narrow = messageEntries(project(messages, startIndex: windowStart)).map(\.id)
        let wide = messageEntries(project(messages, startIndex: 0)).map(\.id)
        XCTAssertEqual(Array(wide.suffix(narrow.count)), narrow)
    }

    func testIdentityStaysStableWhileTheRunGrowsThroughStreaming() throws {
        let cache = NativeTimelineProjectionCache()
        let hashes = ChatRowContentHashCache()
        let renderStore = ChatRenderStateStore()
        var revision = 0
        var messages = [UIMessage.companion.user(prompt: "自动操作"), assistant([phone("s1")])]
        func project(_ event: ChatEvent) -> NativeTimelineProjection {
            revision += 1
            return cache.projection(messages: messages, event: event, sourceRevision: revision,
                startIndex: 0, configurationIssue: nil, isGenerationActive: true,
                isLoading: false, isRecognizingImages: false, contextCompactState: .idle,
                contextCompactBoundaries: [], viewportState: ChatViewportState(),
                displaySettingSignature: "", generativeUiSettingSignature: "",
                renderStateRevision: 0, reasoningLevelLabel: nil, streamedMessageIDs: [],
                renderStateStore: renderStore, variantInfoProvider: { _ in nil },
                contentHashProvider: { row, streaming in
                    streaming ? hashes.streamingTailLayoutToken(for: row) : hashes.contentHash(for: row)
                })
        }
        let first = project(.toolResultAppended)
        let headID = try XCTUnwrap(messageEntries(first).last?.id)
        let firstSummary = try XCTUnwrap(messageEntries(first).last?.phoneToolGroup?.headSummary)
        XCTAssertEqual(firstSummary.stepCount, 1)

        // Next step: the model starts thinking in a new assistant message.
        messages.append(assistant([reasoning()], finished: false))
        let thinking = project(.assistantStreamDelta)
        let thinkingEntries = messageEntries(thinking)
        XCTAssertEqual(thinkingEntries[1].id, headID, "head row identity is unchanged")
        XCTAssertTrue(thinkingEntries[2].phoneToolGroup?.isCollapsedMember == true)
        XCTAssertTrue(thinkingEntries[1].phoneToolGroup?.headSummary?.isLive == true)

        // Streaming tail: the phone call arrives in the same message (tail replacement path).
        let tailID = thinkingEntries[2].id
        let tailMessage = messages[2]
        messages[2] = UIMessage(id: tailMessage.id, role: tailMessage.role,
            parts: [reasoning(), phone("s2", result: nil, input: #"{"act"#)], annotations: [],
            createdAt: tailMessage.createdAt, finishedAt: nil, modelId: nil, usage: nil, translation: nil)
        let streaming = project(.assistantStreamDelta)
        let streamingEntries = messageEntries(streaming)
        XCTAssertEqual(streamingEntries.map(\.id), thinkingEntries.map(\.id), "no row identity changes while streaming")
        XCTAssertEqual(streamingEntries[2].id, tailID)
        let streamingSummary = try XCTUnwrap(streamingEntries[1].phoneToolGroup?.headSummary)
        XCTAssertEqual(streamingSummary.id, firstSummary.id, "group id stays the first message UUID")
        XCTAssertEqual(streamingSummary.stepCount, 2)
        XCTAssertEqual(streamingSummary.latestTool.toolCallId, "s2")
        XCTAssertNotEqual(streamingEntries[1].renderDigest, thinkingEntries[1].renderDigest,
                          "the header shows the new latest step")

        // Tool arguments keep streaming: the header (content signature) does not change.
        messages[2] = UIMessage(id: tailMessage.id, role: tailMessage.role,
            parts: [reasoning(), phone("s2", result: nil, input: #"{"action":"tap","ref":"r9"}"#)], annotations: [],
            createdAt: tailMessage.createdAt, finishedAt: nil, modelId: nil, usage: nil, translation: nil)
        let moreArgs = project(.assistantStreamDelta)
        XCTAssertEqual(messageEntries(moreArgs)[1].renderDigest, streamingEntries[1].renderDigest)

        // The result arrives (tool message path): status changes the head signature once.
        messages[2] = UIMessage(id: tailMessage.id, role: tailMessage.role,
            parts: [reasoning(), phone("s2", input: #"{"action":"tap","ref":"r9"}"#)], annotations: [],
            createdAt: tailMessage.createdAt, finishedAt: nil, modelId: nil, usage: nil, translation: nil)
        let result = project(.toolResultAppended)
        let resultEntries = messageEntries(result)
        XCTAssertEqual(resultEntries.map(\.id), thinkingEntries.map(\.id))
        XCTAssertNotEqual(resultEntries[1].renderDigest, streamingEntries[1].renderDigest)
        let full = self.project(messages, generating: true)
        XCTAssertEqual(messageEntries(full).map(\.phoneToolGroup), resultEntries.map(\.phoneToolGroup),
                       "incremental paths agree with a full build")
    }

    func testSignaturesAreStableForIdenticalContentAndChangeOnStepStatus() throws {
        let user = UIMessage.companion.user(prompt: "go")
        let step1 = assistant([phone("g1")])
        let pending = assistant([phone("g2", result: nil)])
        let a = messageEntries(project([user, step1, pending]))
        let b = messageEntries(project([user, step1, pending]))
        XCTAssertEqual(a[1].phoneToolGroup?.headSummary?.signature, b[1].phoneToolGroup?.headSummary?.signature)
        XCTAssertEqual(a[1].renderDigest, b[1].renderDigest)

        let done = UIMessage(id: pending.id, role: pending.role, parts: [phone("g2")], annotations: [],
            createdAt: pending.createdAt, finishedAt: pending.finishedAt, modelId: nil, usage: nil, translation: nil)
        let c = messageEntries(project([user, step1, done]))
        XCTAssertNotEqual(a[1].phoneToolGroup?.headSummary?.signature, c[1].phoneToolGroup?.headSummary?.signature)
        XCTAssertEqual(a.map(\.id), c.map(\.id))
        XCTAssertEqual(c[2].phoneToolGroup, .member(groupID: id(step1), isExpanded: false))
    }

    func testExpandedStateIsPresentationInputThatChangesContentOnce() throws {
        let messages = [UIMessage.companion.user(prompt: "go"), assistant([phone("e1")]),
                        assistant([reasoning()]), assistant([phone("e2")])]
        let groupID = id(messages[1])
        let collapsed = messageEntries(project(messages))
        let expanded = messageEntries(project(messages, expanded: [groupID]))
        let expandedAgain = messageEntries(project(messages, expanded: [groupID]))
        XCTAssertEqual(collapsed.map(\.id), expanded.map(\.id), "toggling never changes render identity")
        XCTAssertEqual(expanded[1].phoneToolGroup?.headSummary?.isExpanded, true)
        XCTAssertEqual(expanded[2].phoneToolGroup, .member(groupID: groupID, isExpanded: true))
        XCTAssertTrue(expanded[3].phoneToolGroup?.isExpandedMember == true)
        for index in 1...3 {
            XCTAssertNotEqual(collapsed[index].renderDigest, expanded[index].renderDigest)
            XCTAssertEqual(expanded[index].renderDigest, expandedAgain[index].renderDigest)
            XCTAssertEqual(collapsed[index].baseRenderDigest, expanded[index].baseRenderDigest,
                           "the message's own content signature is untouched")
        }
        XCTAssertNil(collapsed[0].phoneToolGroup)
        XCTAssertEqual(collapsed[0].renderDigest, expanded[0].renderDigest)
    }

    func testAttentionSurfacesInCollapsedHeader() throws {
        let user = UIMessage.companion.user(prompt: "go")
        let approval = messageEntries(project([user, assistant([phone("t1")]),
            assistant([phone("t2", result: nil, approval: ToolApprovalState.Pending.shared)])]))
        let approvalSummary = try XCTUnwrap(approval[1].phoneToolGroup?.headSummary)
        XCTAssertEqual(approvalSummary.attention, .approvalPending)
        XCTAssertEqual(approvalSummary.attentionCount, 1)

        let unknown = messageEntries(project([user,
            assistant([phone("u1", name: "phone_run_goal", result: #"{"status":"unknown","outcome":"unknown"}"#)]),
            assistant([phone("u2")])]))
        XCTAssertEqual(unknown[1].phoneToolGroup?.headSummary?.attention, .outcomeUnknown,
                       "an unknown outcome on an older step stays visible")

        let oldFailure = messageEntries(project([user,
            assistant([phone("f1", result: #"{"ok":false,"error":"no element"}"#)]), assistant([phone("f2")])]))
        XCTAssertNil(oldFailure[1].phoneToolGroup?.headSummary?.attention, "a failure the agent recovered from is not an alert")
        let latestFailure = messageEntries(project([user,
            assistant([phone("f1")]), assistant([phone("f2", result: #"{"ok":false,"error":"no element"}"#)])]))
        XCTAssertEqual(latestFailure[1].phoneToolGroup?.headSummary?.attention, .failed)

        // An unknown outcome before the loaded window is still surfaced.
        var long = [user, assistant([phone("w0", name: "phone_run_goal", result: #"{"status":"unknown","outcome":"unknown"}"#)])]
        long += (0..<70).map { _ in assistant([phone("w")]) }
        let windowed = messageEntries(project(long, startIndex: long.count - 60))
        XCTAssertEqual(windowed.compactMap { $0.phoneToolGroup?.headSummary }.first?.attention, .outcomeUnknown)

        let summary = try XCTUnwrap(approval[1].phoneToolGroup?.headSummary)
        let label = ChatPhoneToolGroupHeader.accessibilityLabel(
            summary: summary, latestStep: ChatToolStepModel(tool: summary.latestTool), state: .active)
        XCTAssertTrue(label.contains("2"), label)
    }

    func testLiveRunHasNoFinishTimeAndFinishedRunDoes() throws {
        let messages = [UIMessage.companion.user(prompt: "go"), assistant([phone("l1")]), assistant([phone("l2", result: nil)])]
        let live = try XCTUnwrap(messageEntries(project(messages, event: .toolCallStarted, generating: true))[1]
            .phoneToolGroup?.headSummary)
        XCTAssertTrue(live.isLive)
        XCTAssertNil(live.finishedAt)
        XCTAssertNotNil(live.startedAt)
        let done = try XCTUnwrap(messageEntries(project(messages))[1].phoneToolGroup?.headSummary)
        XCTAssertFalse(done.isLive)
        XCTAssertNotNil(done.finishedAt)
        // One positional format, live (Text(timerInterval:)) and finished alike.
        XCTAssertEqual(ChatPhoneToolGroupHeader.elapsedText(seconds: 65, locale: Locale(identifier: "en_US")), "1:05")
        XCTAssertEqual(ChatPhoneToolGroupHeader.elapsedText(seconds: 3_723, locale: Locale(identifier: "en_US")), "1:02:03")
    }

    func testAnchorIntoCollapsedGroupMapsToTheGroupToExpand() throws {
        let cache = NativeTimelineProjectionCache()
        let messages = [UIMessage.companion.user(prompt: "go"), assistant([phone("r1")]), assistant([phone("r2")])]
        func project(revision: Int, expanded: Set<String>) {
            _ = cache.projection(messages: messages, event: .conversationLoaded, sourceRevision: revision,
                startIndex: 0, configurationIssue: nil, isGenerationActive: false,
                isLoading: false, isRecognizingImages: false, contextCompactState: .idle,
                contextCompactBoundaries: [], viewportState: ChatViewportState(),
                displaySettingSignature: "", generativeUiSettingSignature: "",
                renderStateRevision: 0, reasoningLevelLabel: nil, streamedMessageIDs: [],
                renderStateStore: ChatRenderStateStore(), variantInfoProvider: { _ in nil },
                expandedPhoneToolGroupIDs: expanded, contentHashProvider: { _, _ in 0 })
        }
        project(revision: 1, expanded: [])
        let groupIDs = cache.collapsedPhoneToolGroupIDsByAnchor()
        XCTAssertEqual(groupIDs[ChatToolCallAnchorTarget.id(messageID: id(messages[2]), toolCallID: "r2")], id(messages[1]))
        XCTAssertEqual(groupIDs[ChatToolCallAnchorTarget.id(messageID: id(messages[1]), toolCallID: "r1")], id(messages[1]))
        project(revision: 2, expanded: [id(messages[1])])
        XCTAssertTrue(cache.collapsedPhoneToolGroupIDsByAnchor().isEmpty, "expanded steps are their own anchors")
    }

    /// Replay evidence: the real timeline renders one header row while collapsed and
    /// nested steps (head + member bubbles, 12 pt inset) when expanded.
    func testCaptureTimelineCollapsedAndExpanded() async throws {
        let messages = [UIMessage.companion.user(prompt: "帮我在设置里打开蓝牙"),
                        assistant([reasoning("先观察当前界面"), phone("cap0", name: "phone_observe")]),
                        assistant([phone("cap1")]),
                        assistant([reasoning("确认开关位置")]),
                        assistant([phone("cap2")]),
                        assistant([UIMessagePart.Text(text: "蓝牙已经打开。", metadata: nil)])]
        let groupID = id(messages[1])
        let store = ChatPhoneToolGroupExpansionStore.shared
        defer { store.setExpanded(false, groupID: groupID) }
        for expanded in [false, true] {
            store.setExpanded(expanded, groupID: groupID)
            let defaults = UserDefaults(suiteName: "PhoneGroupVisual-\(UUID().uuidString)")!
            let settings = IOSSharedSettingsStore(userDefaults: defaults)
            let view = NativeChatTimelineView(
                signal: ChatMessageUpdateSignal(), configurationIssue: nil, isGenerationActive: false,
                isLoading: false, isRecognizingImages: false,
                contextCompactState: ChatContextCompactState(status: .idle, summary: "", updatedAt: Date()),
                contextCompactBoundaries: [], followGeneration: false,
                displaySetting: settings.displaySetting, generativeUiSetting: settings.agentRuntime.generativeUi,
                reasoningLevelLabel: nil, workspaceStore: IOSWorkspaceStore(), scrollToBottomTrigger: 0,
                scrollToBottomSource: .button, messageAnchor: nil, currentConversationID: "phone-group-visual",
                messagesProvider: { messages }, variantInfoProvider: { _ in nil },
                onAction: { _ in }, onViewportStateChange: { _ in }, onDismissKeyboard: {}
            )
            let host = UIHostingController(rootView: view)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            window.backgroundColor = .systemBackground
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 400_000_000)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let name = expanded ? "phone-group-timeline-expanded" : "phone-group-timeline-collapsed"
            try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    func testGroupStringsAreLocalized() {
        for language in ["en", "ru", "ja", "ko", "zh-Hant"] {
            for key in ["手机操作 · %ld 步", "%ld 步待你批准", "%ld 步结果未知，需核对", "最新一步%@",
                        "轻点展开步骤", "轻点收起步骤", "展开步骤", "收起步骤"] {
                let value = IOSAppLocalization.string(key, defaultValue: "<missing>",
                    language: IOSAppLanguage(storedValue: language))
                XCTAssertNotEqual(value, "<missing>", "\(language): \(key)")
                if language != "zh-Hant" {
                    XCTAssertNotEqual(value, key, "\(language) must translate \(key)")
                }
                XCTAssertEqual(value.components(separatedBy: "%").count, key.components(separatedBy: "%").count,
                               "\(language): format specifiers preserved in \(key)")
            }
        }
    }
}
