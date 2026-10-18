import Foundation
import Darwin
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class IOSWebMountLocalCommands {
    private unowned let controller: IOSWebMountController
    private let stations: IOSWebMountStationCommands
    private var sessionStore: IOSWebMountSessionStore { controller.sessionStore }
    private var registry: IOSWebMountRegistry { controller.registry }
    private var settings: IOSWebMountSettings { controller.settings }
    private var cookieStore: IOSWebMountCookieStoreProtocol { controller.cookieStore }
    private var resolveHost: IOSWebMountHostResolver { controller.resolveHost }
    private var lastAgentObservation: [String: (runId: String, url: String, documentId: String, urlRevision: Int)] = [:]

    init(controller: IOSWebMountController, stations: IOSWebMountStationCommands) {
        self.controller = controller
        self.stations = stations
    }

    func openResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?,
        allowUnlistedHosts: Bool
    ) async throws -> String {
        let requestedSiteId = (args["site_id"] as? String)?.nilIfBlank
        let resolvedSite = controller.siteFromArgs(args)
        if requestedSiteId != nil, resolvedSite == nil {
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "error_code": "site_binding_required",
                "reason": "wm_open received an unknown WebMount station."
            ])
        }
        if let resolvedSite, !resolvedSite.enabled {
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "reason": "WebMount station is disabled",
                "site_id": resolvedSite.id
            ])
        }
        let site = resolvedSite
        if !allowUnlistedHosts, site == nil {
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "error_code": "host_not_allowed",
                "reason": "wm_open requires a registered WebMount station. Add or restore the site before opening this URL."
            ])
        }
        guard let rawURL = (args["url"] as? String)?.nilIfBlank ?? site?.homepageURL else {
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "error_code": "missing_url",
                "reason": "wm_open requires url when no WebMount station is selected."
            ])
        }
        let policy = IOSWebMountURLPolicy(
            settings: settings,
            extraAllowedHosts: registry.sites.flatMap(\.allowedHosts),
            allowUnlistedHosts: allowUnlistedHosts,
            allowFakeIPFallback: true
        )
        switch await policy.validateResolvedPublicHost(
            rawURL,
            site: site,
            resolveHost: resolveHost
        ) {
        case .failure(let error):
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "error_code": error.errorCode,
                "reason": error.localizedDescription,
                "url": IOSWebMountRedactor.redactedURL(rawURL) ?? ""
            ])
        case .success(let url):
            let timeout = UInt64((args["timeout_ms"] as? Int) ?? 30_000).clamped(to: 1_000...60_000)
            if let sessionId = (args["session_id"] as? String)?.nilIfBlank,
               let record = sessionStore.record(sessionId: sessionId),
               record.needsReopen {
                if let context, let owner = record.ownerConversationId, owner != context.conversationId {
                    throw IOSWebMountSessionError.sessionBindingMismatch(sessionId)
                }
                guard sessionStore.reopen(sessionId: sessionId) != nil else {
                    return IOSWebMountController.json([
                        "ok": false,
                        "denied": true,
                        "session_id": sessionId,
                        "error_code": "session_reopen_unavailable",
                        "reason": "WebMount session needs to be reopened, but its runtime is unavailable."
                    ])
                }
            }
            let runtime = try controller.sessionRuntime(from: args, context: context)
            sessionStore.showCard(sessionId: runtime.snapshot.sessionId)
            (runtime as? IOSWebMountWKRuntime)?.setNavigationPolicy(
                policy,
                site: site,
                resolveHost: resolveHost
            )
            sessionStore.tag(sessionId: runtime.snapshot.sessionId, site: site)
            let before = try? await runtime.state()
            let snapshot = await runtime.open(url, timeoutMillis: timeout)
            if controller.agentOwnershipLost(sessionId: snapshot.sessionId, context: context) {
                sessionStore.markNeedsReopen(sessionId: snapshot.sessionId)
                controller.touch(sessionId: snapshot.sessionId, context: context)
                return IOSWebMountController.localNavigationOwnershipUnknown(
                    toolName: "wm_open",
                    sessionId: snapshot.sessionId
                )
            }
            let timedOut = snapshot.status == .failed
                && snapshot.error?.hasPrefix("load timed out after ") == true
            if timedOut {
                sessionStore.markNeedsReopen(sessionId: snapshot.sessionId)
            } else if snapshot.status != .failed {
                sessionStore.clearNeedsReopen(sessionId: snapshot.sessionId)
            }
            controller.touch(sessionId: snapshot.sessionId, context: context)
            let after = try? await runtime.state()
            if let after { _ = pageDrift(sessionId: snapshot.sessionId, page: after, context: context) }
            let pageChanged: Any
            if let before, let after {
                pageChanged = IOSWebMountController.webMountStateDiff(before: before, after: after)["changed"] ?? false
            } else {
                pageChanged = NSNull()
            }
            var response: [String: Any] = [
                "ok": snapshot.status != .failed,
                "session_id": snapshot.sessionId,
                "status": timedOut ? "unknown_after_action" : snapshot.status.rawValue,
                "error_code": timedOut ? "unknown_after_action" : "",
                "may_have_applied": timedOut,
                "dispatched": snapshot.status == .failed ? NSNull() : true as Any,
                "page_changed": pageChanged,
                "goal_verified": false,
                "navigation_ready": snapshot.status == .ready,
                "url": snapshot.currentURL ?? snapshot.requestedURL ?? "",
                "title": IOSWebMountRedactor.redactedText(snapshot.title ?? ""),
                "error": IOSWebMountRedactor.redactedText(snapshot.error ?? ""),
                "waited": true
            ]
            if snapshot.status == .failed {
                response["final_observation"] = await controller.boundedFinalObservation(runtime: runtime)
            }
            if snapshot.status == .ready, let currentHost = snapshot.currentURL.flatMap({ URL(string: $0)?.host?.lowercased() }),
               let memory = stations.siteMemorySummary(host: currentHost, sessionId: snapshot.sessionId) {
                response["site_memory"] = memory
                response["untrusted_site_memory"] = true
            }
            return IOSWebMountController.json(response)
        }
    }

    private static func runtimeFailure(_ result: [String: Any], sessionId: String) -> String? {
        guard result["ok"] as? Bool == false else { return nil }
        var failure = result
        failure["session_id"] = sessionId
        return IOSWebMountController.json(IOSWebMountRedactor.redactedJSONObject(failure))
    }

    func pageDrift(
        sessionId: String,
        page: [String: Any],
        context: IOSWebMountExecutionContext?
    ) -> [String: Any] {
        guard let context, context.isAgentInvocation,
              let url = IOSWebMountRedactor.redactedURL(page["url"] as? String),
              let documentId = (page["document_id"] as? String)?.nilIfBlank else { return [:] }
        let urlRevision = (page["url_revision"] as? Int) ?? (page["url_revision"] as? NSNumber)?.intValue ?? 0
        let previous = lastAgentObservation[sessionId]
        lastAgentObservation[sessionId] = (context.runId, url, documentId, urlRevision)
        guard let previous, previous.runId == context.runId,
              previous.url != url || previous.documentId != documentId || previous.urlRevision != urlRevision else { return [:] }
        return ["page_drift": true, "previous_url": previous.url, "current_url": url]
    }

    func stateResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try controller.sessionRuntime(from: args, context: context, requiresControl: false)
        let page = try await runtime.state()
        if let failure = Self.runtimeFailure(page, sessionId: runtime.snapshot.sessionId) { return failure }
        let drift = pageDrift(sessionId: runtime.snapshot.sessionId, page: page, context: context)
        controller.touch(sessionId: runtime.snapshot.sessionId, context: context)
        var response: [String: Any] = [
            "ok": true,
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": page["snapshot_id"] as? String ?? "",
            "page_revision": page["page_revision"] ?? 0,
            "state": runtime.snapshot.dictionary(redactURLs: true),
            "page": IOSWebMountRedactor.redactedJSONObject(page)
        ]
        response.merge(drift) { _, new in new }
        if let memory = stations.firstObservationSiteMemory(sessionId: runtime.snapshot.sessionId,
                                                  currentURL: page["url"] as? String ?? runtime.snapshot.currentURL) {
            response["site_memory"] = memory
            response["untrusted_site_memory"] = true
        }
        return IOSWebMountController.json(response)
    }

    /// wm_act 批量步骤的白名单：只放行与单动作派发管道一致的交互原语。
    private static let webMountActToolMap: [String: String] = [
        "find": "wm_find", "wait": "wm_wait",
        "click": "wm_click", "tap": "wm_tap", "type": "wm_type",
        "keys": "wm_keys", "scroll": "wm_scroll", "select": "wm_select",
    ]
    /// 批量步数上限：1-3 步任务是设计目标，8 是防滥用边界。
    private static let webMountActMaxSteps = 8
    /// 转发进单动作派发管道的参数键白名单（session/snapshot 由宿主注入；
    /// before_* 缺省时由宿主按上一步页面状态补齐）。
    private static let webMountActStepArgKeys: Set<String> = [
        "target", "selector", "locator", "text", "value", "key", "keys", "count", "option",
        "by_y", "dy", "dx", "to", "position", "direction", "x", "y",
        "condition", "url_contains", "ready_state", "require_page_change",
        "timeout_ms", "wait_ms", "postcondition",
        "click_count", "max_results", "stable_ms",
        "before_document_id", "before_url", "before_url_revision", "before_dom_revision",
    ]

    /// wm_act：一次调用串行执行一小批页面动作。逐步递归走 executeResult，
    /// 完整继承策略/快照/语义目标/控制权/高后果门——宿主只负责三件事：
    /// 逐步注入最新 snapshot_id（批量内 revision 必然推进，绑计划时点
    /// 会全部 stale）；find 步的首个匹配 ref 补给缺省 target 的后续步；
    /// 按 document_id 纪元熔断——导航使全部已枚举 ref 失效，剩余不再派发。
    func actResult(
        args: [String: Any],
        isUserInitiated: Bool,
        context: IOSWebMountExecutionContext?,
        allowUnlistedHosts: Bool,
        visualRead: IOSWebMountVisualReadHandler?
    ) async throws -> String {
        let sessionId = (args["session_id"] as? String)?.nilIfBlank ?? ""
        guard let rawSteps = args["steps"] as? [[String: Any]], !rawSteps.isEmpty else {
            return IOSWebMountController.json([
                "ok": false, "tool": "wm_act", "session_id": sessionId,
                "denied": true, "error_code": "steps_required",
                "reason": "wm_act requires a non-empty steps array.",
            ])
        }
        guard rawSteps.count <= Self.webMountActMaxSteps else {
            return IOSWebMountController.json([
                "ok": false, "tool": "wm_act", "session_id": sessionId,
                "denied": true, "error_code": "too_many_steps",
                "reason": "wm_act accepts at most \(Self.webMountActMaxSteps) steps per call.",
            ])
        }
        // agent 调用必须锚定近期观察——与单动作 snapshot_required 同契约；
        // 批量内逐步绑定的是宿主取的最新快照，顶层值只证明计划时点。
        if context?.isAgentInvocation == true,
           (args["snapshot_id"] as? String)?.nilIfBlank == nil {
            return IOSWebMountController.json([
                "ok": false, "tool": "wm_act", "session_id": sessionId,
                "denied": true, "error_code": "snapshot_required",
                "reason": "Agent WebMount mutations require snapshot_id from the latest observation.",
            ])
        }
        // 起始纪元：document_id。跨步复用的 ref 与快照都以同文档为前提；
        // 会话钉在解析时点——批量中途切换当前会话不会把剩余步骤发去别处。
        let runtime = try controller.sessionRuntime(from: args, context: context, requiresControl: false)
        let resolvedSessionId = runtime.snapshot.sessionId
        let epoch = try await runtime.state()
        if let expectedSnapshotId = (args["snapshot_id"] as? String)?.nilIfBlank,
           expectedSnapshotId != epoch["snapshot_id"] as? String {
            return IOSWebMountController.json([
                "ok": false, "tool": "wm_act", "session_id": resolvedSessionId,
                "error_code": "stale_snapshot", "requires_reobserve": true,
                "reason": "The WebMount snapshot changed before the batch started. Re-observe before retrying."
            ])
        }
        let epochDocumentId = epoch["document_id"] as? String ?? ""
        var currentSnapshotId = epoch["snapshot_id"] as? String ?? ""
        var lastRef: String?
        var lastAfter = epoch
        var stepReports: [[String: Any]] = []
        var completedCount = 0
        var dispatchedMutations = 0
        var mayHaveApplied = false
        var lastUncertainStatus: String?
        var abort: [String: Any]?

        for (index, step) in rawSteps.enumerated() {
            guard let action = (step["action"] as? String)?.lowercased(),
                  let toolName = Self.webMountActToolMap[action] else {
                abort = [
                    "index": index,
                    "action": (step["action"] as? String) ?? "",
                    "error_code": "unsupported_step_action",
                    "reason": "Unsupported step action '\(step["action"] ?? "?")'; wm_act steps support find/wait/click/tap/type/keys/scroll/select only.",
                ]
                break
            }
            var stepArgs: [String: Any] = ["session_id": resolvedSessionId]
            for key in Self.webMountActStepArgKeys {
                if let value = step[key] { stepArgs[key] = value }
            }
            // find 产出的首个匹配 ref 喂给缺省 target 的后续步。
            if stepArgs["target"] == nil, stepArgs["selector"] == nil,
               !(toolName == "wm_find" && stepArgs["locator"] != nil), let lastRef {
                stepArgs["target"] = lastRef
            }
            if !currentSnapshotId.isEmpty {
                stepArgs["snapshot_id"] = currentSnapshotId
            }
            // wait 的变更类条件需要基线：缺省时按上一步页面状态补齐，
            // 否则 document_changed/url_changed/require_page_change 必然
            // missing_wait_baseline。
            if toolName == "wm_wait" {
                for (key, source) in [
                    ("before_document_id", "document_id"),
                    ("before_url", "url"),
                    ("before_url_revision", "url_revision"),
                    ("before_dom_revision", "dom_revision"),
                ] where stepArgs[key] == nil {
                    if let value = lastAfter[source] { stepArgs[key] = value }
                }
            }
            let output = await controller.executeResult(
                toolName: toolName,
                input: IOSWebMountController.json(stepArgs),
                // Approval of a batch grants access to the browser session,
                // not approval of every later consequential step.
                isUserInitiated: isUserInitiated && context?.isAgentInvocation != true,
                context: context,
                allowUnlistedHosts: allowUnlistedHosts,
                visualRead: visualRead
            )
            let out = IOSWebMountController.parseObject(output)
            let status = (out["status"] as? String)?.lowercased() ?? ""
            let ok = out["ok"] as? Bool == true
            // 未验证步状态记账：成功批量也须把 dispatched_unverified/
            // ambiguous 透到顶层，供 uncertain notice（读顶层 status）。
            if ["dispatched_unverified", "ambiguous", "unknown_after_action"].contains(status) {
                lastUncertainStatus = status
            }
            mayHaveApplied = mayHaveApplied || (out["may_have_applied"] as? Bool == true)
            if let snap = (out["snapshot_id"] as? String)?.nilIfBlank {
                currentSnapshotId = snap
            }
            let after = out["after"] as? [String: Any] ?? [:]
            if !after.isEmpty { lastAfter = after }

            var report: [String: Any] = [
                "index": index, "action": action,
                "ok": ok,
                "status": out["status"] as? String ?? "",
                "dispatched": out["dispatched"] as? Bool ?? false,
                "page_changed": out["page_changed"] as? Bool ?? false,
            ]
            if action == "find" {
                let matches = (out["action"] as? [String: Any])?["matches"] as? [[String: Any]] ?? []
                lastRef = (matches.first?["ref"] as? String)?.nilIfBlank
                report["found"] = (out["action"] as? [String: Any])?["found"] as? Bool ?? false
                report["ref"] = lastRef ?? ""
            }
            stepReports.append(report)

            // 已派发的变更步先入账：后续中止（含导航熔断）时 may_have_applied
            // 必须如实反映"页面可能已变"，verified 结果也不能漏计。
            if out["dispatched"] as? Bool == true, !["wm_find", "wm_wait"].contains(toolName) {
                dispatchedMutations += 1
            }

            // 需要用户处理 / 结果未知：立即终止并原样透出内层原因。
            if out["needs_user_action"] as? Bool == true
                || out["requires_human"] as? Bool == true
                || status == "unknown_after_action" {
                // unknown 语义即"可能已生效"——即使内层字段缺失也必须置位。
                if status == "unknown_after_action" { mayHaveApplied = true }
                abort = [
                    "index": index, "action": action,
                    "error_code": out["error_code"] as? String ?? status,
                    "reason": out["reason"] as? String
                        ?? "Step requires user action or ended in an unknown state.",
                    "needs_user_action": out["needs_user_action"] as? Bool ?? false,
                    "requires_human": out["requires_human"] as? Bool ?? false,
                    // 批量内不弹审批卡：提示模型以单工具调用重发该步，
                    // 走完整的审批/人工交接流程。
                    "retry_hint": "Re-issue this step as a single \(toolName) call to surface its approval or handoff flow.",
                ]
                // gate 明细字段前向到顶层（审批/交接/unknown 检测器都读顶层）。
                for key in ["status", "target_ref", "target_label", "consequence"] {
                    if let value = out[key] { abort?[key] = value }
                }
                break
            }
            if !ok {
                abort = [
                    "index": index, "action": action,
                    "error_code": out["error_code"] as? String ?? "step_failed",
                    "reason": (out["reason"] as? String) ?? (out["error"] as? String) ?? "Step failed.",
                    "status": status,
                ]
                break
            }
            // 走到这里说明该步本身成功跑完（包括触发了中止的步——
            // 中止针对的是后续步，executed 如实记录已跑完的步数）。
            completedCount += 1
            // find 未命中：典型链（find→click）已断，不再派发后续。
            if action == "find", lastRef == nil {
                abort = [
                    "index": index, "action": action,
                    "error_code": "target_not_found",
                    "reason": "find step matched no element; dependent steps were not dispatched.",
                ]
                break
            }
            // 导航熔断：document 变换使全部已枚举 ref 失效。
            let afterDocumentId = after["document_id"] as? String ?? ""
            if !epochDocumentId.isEmpty, !afterDocumentId.isEmpty, afterDocumentId != epochDocumentId {
                abort = [
                    "index": index, "action": action,
                    "error_code": "page_navigated",
                    "reason": "Document changed mid-batch; remaining steps were not dispatched.",
                ]
                break
            }
        }

        var response: [String: Any] = [
            "ok": abort == nil,
            "tool": "wm_act",
            "session_id": resolvedSessionId,
            "executed": completedCount,
            "total": rawSteps.count,
            "may_have_applied": mayHaveApplied || dispatchedMutations > 0,
            "steps": stepReports,
            "final": [
                "url": lastAfter["url"] ?? "",
                "title": lastAfter["title"] ?? "",
                "document_id": lastAfter["document_id"] ?? "",
                "snapshot_id": currentSnapshotId,
            ],
        ]
        if let abort {
            response["aborted"] = abort
            // 顶出关键字段：中断终态（isWebMountInterruptedOutcome
            // 要顶层 status+may_have_applied）与失败归因都读顶层字段——
            // 与单工具输出形状对齐，aborted 内保留完整诊断。
            response["error_code"] = abort["error_code"]
            if let reason = abort["reason"] { response["reason"] = reason }
            if abort["needs_user_action"] as? Bool == true { response["needs_user_action"] = true }
            if abort["requires_human"] as? Bool == true { response["requires_human"] = true }
            if (abort["error_code"] as? String) == "unknown_after_action"
                || (abort["status"] as? String) == "unknown_after_action" {
                response["status"] = "unknown_after_action"
            } else if let abortStatus = abort["status"] as? String,
                      ["dispatched_unverified", "ambiguous"].contains(abortStatus) {
                response["status"] = abortStatus
            }
            for key in ["target_ref", "target_label", "consequence", "retry_hint"] {
                if let value = abort[key] { response[key] = value }
            }
        } else if let uncertain = lastUncertainStatus {
            // 成功批量但含未验证步：与单工具同形状透出 status——
            // uncertain notice 要求顶层 status+may_have_applied 同时在场。
            response["status"] = uncertain
        }
        return IOSWebMountController.json(response)
    }

    func observeResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try controller.sessionRuntime(from: args, context: context, requiresControl: false)
        let maxChars = ((args["max_chars"] as? Int) ?? 2_000).clamped(to: 0...8_000)
        let maxLinks = ((args["max_links"] as? Int) ?? 20).clamped(to: 0...40)
        let observation = try await runtime.observe(maxChars: maxChars, maxLinks: maxLinks)
        if let failure = Self.runtimeFailure(observation, sessionId: runtime.snapshot.sessionId) { return failure }
        let page = observation["page"] as? [String: Any] ?? [:]
        _ = pageDrift(sessionId: runtime.snapshot.sessionId, page: page, context: context)
        controller.touch(sessionId: runtime.snapshot.sessionId, context: context)
        var response: [String: Any] = [
            "ok": true,
            "tool": "wm_observe",
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": observation["snapshot_id"] as? String ?? page["snapshot_id"] as? String ?? "",
            "page_revision": observation["page_revision"] ?? page["page_revision"] ?? 0,
            "state": runtime.snapshot.dictionary(redactURLs: true),
            "page": IOSWebMountRedactor.redactedJSONObject(page),
            "visible_text": IOSWebMountRedactor.redactedJSONObject(observation["visible_text"] ?? ""),
            "links": IOSWebMountRedactor.redactedJSONObject(observation["links"] ?? []),
            "interactive_elements": IOSWebMountRedactor.redactedJSONObject(observation["interactive_elements"] ?? []),
            "visual_candidates": IOSWebMountRedactor.redactedJSONObject(observation["visual_candidates"] ?? []),
            "observation_consistency": observation["observation_consistency"] ?? "unknown",
            "truncated_fields": observation["truncated_fields"] ?? [],
            "redaction_applied": true,
            "read_more": "Use wm_find for a local target, then wm_get with session_id, snapshot_id and target. Use wm_extract with max_chars for more page text.",
            "untrusted_page_content": true,
            "redacted": true
        ]
        if let memory = stations.firstObservationSiteMemory(sessionId: runtime.snapshot.sessionId,
                                                  currentURL: page["url"] as? String ?? runtime.snapshot.currentURL) {
            response["site_memory"] = memory
            response["untrusted_site_memory"] = true
        }
        return IOSWebMountController.json(response)
    }

    func extractResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let mode = (args["mode"] as? String)?.nilIfBlank ?? "readable"
        let maxChars = ((args["max_chars"] as? Int) ?? 20_000).clamped(to: 0...80_000)
        let maxLinks = ((args["max_links"] as? Int) ?? 20).clamped(to: 0...100)
        let runtime = try controller.sessionRuntime(from: args, context: context, requiresControl: false)
        var result = try await runtime.extract(mode: mode, maxChars: maxChars, maxLinks: maxLinks)
        if let failure = Self.runtimeFailure(result, sessionId: runtime.snapshot.sessionId) { return failure }
        let credentialRedacted = IOSWebMountRedactor.redactCredentialGroups(in: &result, keys: ["text", "visible_text"])
        let drift = pageDrift(sessionId: runtime.snapshot.sessionId, page: result, context: context)
        controller.touch(sessionId: runtime.snapshot.sessionId, context: context)
        var response: [String: Any] = [
            "ok": true,
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": result["snapshot_id"] as? String ?? "",
            "page_revision": result["page_revision"] ?? 0,
            "credential_redacted": credentialRedacted,
            "result": IOSWebMountRedactor.redactedJSONObject(result)
        ]
        response.merge(drift) { _, new in new }
        return IOSWebMountController.json(response)
    }

    func getResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let kind = ((args["kind"] as? String)?.nilIfBlank ?? "text").lowercased()
        if kind == "html" {
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "reason": "wm_get kind=html is disabled on iOS because raw DOM can contain hidden tokens. Use text, value, or attr."
            ])
        }
        if kind == "value",
           Self.looksSensitiveSelector(args["selector"] as? String) ||
            Self.looksSensitiveSelector(args["target"] as? String) {
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "reason": "wm_get refused a value read from a selector that looks like a token, password, cookie, or secret field."
            ])
        }
        if kind == "attr", Self.looksSensitiveSelector(args["attr_name"] as? String) {
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "reason": "wm_get refused a sensitive token, password, cookie, secret, or authorization attribute."
            ])
        }
        if kind == "attr", (args["attr_name"] as? String)?.lowercased() == "value" {
            return IOSWebMountController.json([
                "ok": false,
                "denied": true,
                "reason": "wm_get attr_name=value is disabled on iOS. Use kind=value so sensitive fields can be checked."
            ])
        }
        let maxChars = ((args["max_chars"] as? Int) ?? 20_000).clamped(to: 0...100_000)
        let runtime = try controller.sessionRuntime(from: args, context: context, requiresControl: false)
        if let expectedSnapshot = (args["snapshot_id"] as? String)?.nilIfBlank {
            let page = try await runtime.state()
            guard page["snapshot_id"] as? String == expectedSnapshot else {
                return IOSWebMountController.json(["ok": false, "error_code": "stale_snapshot", "requires_reobserve": true,
                                  "session_id": runtime.snapshot.sessionId, "snapshot_id": page["snapshot_id"] ?? ""])
            }
        }
        var result = try await runtime.get(
            selector: (args["selector"] as? String)?.nilIfBlank,
            target: (args["target"] as? String)?.nilIfBlank,
            kind: kind,
            attrName: args["attr_name"] as? String,
            maxChars: maxChars
        )
        let credentialRedacted = kind == "text" || kind == "value"
            ? IOSWebMountRedactor.redactCredentialGroups(in: &result, keys: ["value"])
            : false
        let readTarget = (args["target"] as? String)?.nilIfBlank
            ?? (args["selector"] as? String)?.nilIfBlank
            ?? ""
        let unboundRead = !readTarget.hasPrefix("wm:")
        let drift = unboundRead && context?.isAgentInvocation == true
            ? pageDrift(sessionId: runtime.snapshot.sessionId, page: result, context: context)
            : [:]
        controller.touch(sessionId: runtime.snapshot.sessionId, context: context)
        var response: [String: Any] = [
            "ok": result["ok"] as? Bool ?? false,
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": result["snapshot_id"] as? String ?? "",
            "page_revision": result["page_revision"] ?? 0,
            "credential_redacted": credentialRedacted,
            "result": IOSWebMountRedactor.redactedJSONObject(result)
        ]
        response.merge(drift) { _, new in new }
        return IOSWebMountController.json(response)
    }

    func visualSnapshotResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try controller.sessionRuntime(from: args, context: context, requiresControl: false)
        let result = try await runtime.extract(mode: "snapshot", maxChars: 0, maxLinks: 80)
        if let failure = Self.runtimeFailure(result, sessionId: runtime.snapshot.sessionId) { return failure }
        controller.touch(sessionId: runtime.snapshot.sessionId, context: context)
        return IOSWebMountController.json([
            "ok": true,
            "tool": "wm_visual_snapshot",
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": result["snapshot_id"] as? String ?? "",
            "page_revision": result["page_revision"] ?? 0,
            "state": runtime.snapshot.dictionary(redactURLs: true),
            "result": IOSWebMountRedactor.redactedJSONObject(result),
            "redacted": true
        ])
    }

    func visualReadResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?,
        reader: IOSWebMountVisualReadHandler?
    ) async throws -> String {
        guard let reader else {
            return IOSWebMountController.json(["ok": false, "error_code": "vision_unavailable", "visual_verified": false,
                              "dom_only": true, "automatic_retry_allowed": false,
                              "reason": "No vision model reader is connected. Visual verification was not performed."])
        }
        let question = (args["question"] as? String)?.nilIfBlank
            ?? "Describe the visible page, loading errors, dialogs and controls. Verify whether the intended browser action visibly succeeded; state uncertainty."
        guard question.count <= 4_000 else {
            return IOSWebMountController.json(["ok": false, "error_code": "invalid_arguments", "reason": "question must be at most 4000 characters."])
        }
        let runtime = try controller.sessionRuntime(from: args, context: context, requiresControl: false)
        let before = try await runtime.state()
        let snapshotId = before["snapshot_id"] as? String ?? ""
        let capturedAt = IOSWebMountClock.nowMillis()
        let capture = try await runtime.screenshot()
        let afterCapture = try await runtime.state()
        guard !snapshotId.isEmpty, afterCapture["snapshot_id"] as? String == snapshotId else {
            return IOSWebMountController.json(["ok": false, "error_code": "page_changed", "requires_reobserve": true, "reason": "The page changed during capture. Wait for a stable page and retry visual reading."])
        }
        try Task.checkCancellation()
        let analysis = try await reader(capture, question)
        try Task.checkCancellation()
        let current = try? await runtime.state()
        let stale = current?["snapshot_id"] as? String != snapshotId
            || sessionStore.record(sessionId: runtime.snapshot.sessionId) == nil
        controller.touch(sessionId: runtime.snapshot.sessionId, context: context)
        return IOSWebMountController.json([
            "ok": !stale,
            "tool": "wm_visual_read",
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": snapshotId,
            "captured_at_ms": capturedAt,
            "width": capture.width,
            "height": capture.height,
            "verification_source": "screenshot",
            "observation_only": true,
            "untrusted_page_content": true,
            "requires_reobserve": stale,
            "error_code": stale ? "stale_visual_read" : "",
            "reason": stale ? "The page changed while the vision model was reading. This analysis describes an older screenshot; observe again before acting." : "",
            "analysis": IOSWebMountRedactor.redactedText(String(analysis.prefix(16_000)))
        ])
    }

    func screenshotResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try controller.sessionRuntime(from: args, context: context, requiresControl: false)
        let capture = try await runtime.screenshot()
        let artifact = try IOSWebMountScreenshotArtifactStore.save(capture, sessionId: runtime.snapshot.sessionId)
        controller.touch(sessionId: runtime.snapshot.sessionId, context: context)
        return IOSWebMountController.json([
            "ok": true,
            "tool": "wm_screenshot",
            "session_id": runtime.snapshot.sessionId,
            "state": runtime.snapshot.dictionary(redactURLs: true),
            "artifact": artifact,
            "redacted": true
        ])
    }

    func clearSessionResult(args: [String: Any]) async throws -> String {
        guard let siteId = (args["site_id"] as? String)?.nilIfBlank,
              let site = registry.site(id: siteId) else {
            return IOSWebMountController.json(["ok": false, "error": "wm_clear_session requires a valid site_id"])
        }
        let result = await cookieStore.clearSession(for: site)
        return IOSWebMountController.json([
            "ok": true,
            "site_id": result.siteId,
            "deleted_cookie_count": result.deletedCookieCount,
            "cleared_website_data_records": result.clearedWebsiteDataRecords,
            "redacted": true
        ])
    }

    private static func looksSensitiveSelector(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowercased = value.lowercased()
        return ["password", "passwd", "token", "csrf", "xsrf", "secret", "cookie", "authorization", "auth"].contains { marker in
            lowercased.contains(marker)
        }
    }

}
