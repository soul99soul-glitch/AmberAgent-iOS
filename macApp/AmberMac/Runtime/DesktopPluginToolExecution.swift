import Foundation
import JavaScriptCore

extension DesktopPluginStore {
    // MARK: Tool Dispatch (Agent Engine & Recipe Integration)

    nonisolated static func parseQualifiedToolName(_ name: String) -> (pluginID: String, toolName: String)? {
        guard name.hasPrefix("plugin__") else { return nil }
        let remainder = name.dropFirst("plugin__".count)
        guard let range = remainder.range(of: "__") else { return nil }
        let pluginID = String(remainder[..<range.lowerBound])
        let toolName = String(remainder[range.upperBound...])
        guard !pluginID.isEmpty, !toolName.isEmpty else { return nil }
        return (pluginID, toolName)
    }

    func toolEffect(for qualifiedName: String) -> DesktopToolEffect {
        guard let parsed = Self.parseQualifiedToolName(qualifiedName),
              let plugin = plugins.first(where: { $0.id == parsed.pluginID && $0.enabled }) else {
            return .sideEffect
        }
        if let dynamic = runtimeHosts[plugin.id]?.dynamicTools[parsed.toolName] {
            return dynamic.manifest.effect
        }
        guard let tool = plugin.manifest.tools.first(where: { $0.name == parsed.toolName }) else {
            return .sideEffect
        }
        return tool.effect
    }

    func executeTool(qualifiedName: String, argumentsJSON: String, workspaceDirectory: URL? = nil) async throws -> String {
        guard let parsed = Self.parseQualifiedToolName(qualifiedName) else {
            throw DesktopRuntimeError.message("无效的插件工具名称：\(qualifiedName)。")
        }
        guard let plugin = plugins.first(where: { $0.id == parsed.pluginID }) else {
            throw DesktopRuntimeError.message("插件 \(parsed.pluginID) 未安装。")
        }
        guard plugin.enabled else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 当前已停用，请先在设置 → 插件中启用。")
        }
        let dynamicTool = runtimeHosts[plugin.id]?.dynamicTools[parsed.toolName]?.manifest
        guard let tool = dynamicTool ?? plugin.manifest.tools.first(where: { $0.name == parsed.toolName }) else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 不包含工具 \(parsed.toolName)。")
        }

        if plugin.manifest.isV3 {
            try requirePermission(plugin: plugin, permission: "agent.tools")
        }

        let argsData = argumentsJSON.data(using: .utf8) ?? Data("{}".utf8)
        let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]

        // Host-native calendar: no JavaScript can reach EventKit, so the host runs these tools itself.
        if plugin.id == DesktopAppleScheduleTools.pluginID {
            return try await DesktopAppleScheduleTools.perform(tool: tool.name, argumentsJSON: argumentsJSON,
                service: calendarService, now: referenceDateProvider())
        }

        // Built-in Feishu Suite (Calendar CalDAV + Bot Webhook/OpenAPI) handlers + JS execution
        if plugin.id == "feishu_calendar" {
            if hasFeishuRemoteCredentials && (tool.name == "list_events" || tool.name == "freebusy") {
                _ = try? await syncFeishuCalendar()
            }
            switch tool.name {
            case "create_event":
                return try await withIdempotencyLock(key: args["idempotency_key"] as? String) {
                    let isLocal = !hasFeishuRemoteCredentials
                    if let key = DesktopFeishuIdempotency.normalize(args["idempotency_key"] as? String),
                       let stored = DesktopFeishuIdempotency.read(key, isLocalDemo: isLocal, from: readPluginStorage(pluginID: "feishu_calendar")) {
                        return DesktopFeishuReplay.payload(from: stored, tool: "create_event")
                    }
                    let summary = (args["summary"] as? String) ?? ""
                    let startTime = (args["start_time"] as? String) ?? ""
                    let endTime = (args["end_time"] as? String) ?? ""
                    guard !summary.isEmpty, !startTime.isEmpty, !endTime.isEmpty else {
                        throw DesktopRuntimeError.message("create_event 需要提供非空的 summary、start_time 与 end_time。")
                    }
                    let location = (args["location"] as? String) ?? "飞书会议"
                    let attendees = (args["attendees"] as? [String]) ?? []
                    let notes = (args["notes"] as? String) ?? ""
                    let created = try await createCalendarEvent(
                        summary: summary,
                        startTime: startTime,
                        endTime: endTime,
                        location: location,
                        attendees: attendees,
                        notes: notes
                    )
                    let createOutput = try Self.encodeJSONObject([
                        "ok": true,
                        "plugin": "feishu_calendar",
                        "mode": created.source,
                        "event": [
                            "id": created.id,
                            "summary": created.summary,
                            "start_time": created.startTime,
                            "end_time": created.endTime,
                            "location": created.location,
                            "attendees": created.attendees,
                            "notes": created.notes,
                            "source": created.source
                        ],
                        "total_events": calendarEvents.count
                    ])
                    recordIdempotentWrite(
                        key: args["idempotency_key"] as? String,
                        result: createOutput,
                        target: created.id,
                        isLocalDemo: created.source == "local"
                    )
                    return createOutput
                }

            case "bot_send_message":
                return try await withIdempotencyLock(key: args["idempotency_key"] as? String) {
                    let receiveID = (args["receive_id"] as? String) ?? ""
                    let isLocal = !isFeishuBotMessageRemote(receiveID: receiveID)
                    if let key = DesktopFeishuIdempotency.normalize(args["idempotency_key"] as? String),
                       let stored = DesktopFeishuIdempotency.read(key, isLocalDemo: isLocal, from: readPluginStorage(pluginID: "feishu_calendar")) {
                        return DesktopFeishuReplay.payload(from: stored, tool: "bot_send_message")
                    }
                    let title = (args["title"] as? String) ?? "Amber 智能体通知"
                    let content = (args["content"] as? String) ?? ""
                    let msgType = (args["msg_type"] as? String) ?? "interactive"
                    let activity = try await sendFeishuBotMessage(
                        title: title,
                        content: content,
                        msgType: msgType,
                        receiveID: receiveID
                    )
                    let sendOutput = try Self.encodeJSONObject([
                        "ok": true,
                        "plugin": "feishu_calendar",
                        "channel": activity.channel,
                        "message_id": activity.id,
                        "title": activity.title,
                        "target": activity.target
                    ])
                    recordIdempotentWrite(
                        key: args["idempotency_key"] as? String,
                        result: sendOutput,
                        target: activity.target,
                        isLocalDemo: activity.channel == "local"
                    )
                    return sendOutput
                }

            case "bot_fetch_chat_history":
                let chatID = (args["chat_id"] as? String) ?? ""
                let limit = (args["limit"] as? Int) ?? 15
                let (messages, activity) = try await fetchFeishuChatHistory(chatID: chatID, limit: limit)
                return try Self.encodeJSONObject([
                    "ok": true,
                    "plugin": "feishu_calendar",
                    "channel": activity.channel,
                    "chat_id": activity.target,
                    "count": messages.count,
                    "messages": messages
                ])

            case "bot_read_doc":
                let docInput = (args["document"] as? String) ?? ""
                let (docID, title, content, activity) = try await readFeishuDocument(documentInput: docInput)
                return try Self.encodeJSONObject([
                    "ok": true,
                    "plugin": "feishu_calendar",
                    "channel": activity.channel,
                    "document_id": docID,
                    "title": title,
                    "content": content,
                    "url": activity.documentURL ?? ""
                ])

            case "bot_create_doc":
                return try await withIdempotencyLock(key: args["idempotency_key"] as? String) {
                    let isLocal = !computeHasFeishuOpenAPICredentials()
                    if let key = DesktopFeishuIdempotency.normalize(args["idempotency_key"] as? String),
                       let stored = DesktopFeishuIdempotency.read(key, isLocalDemo: isLocal, from: readPluginStorage(pluginID: "feishu_calendar")) {
                        return DesktopFeishuReplay.payload(from: stored, tool: tool.name)
                    }
                    let title = (args["title"] as? String) ?? ""
                    let content = (args["content"] as? String) ?? ""
                    let folderToken = (args["folder_token"] as? String) ?? ""
                    let activity = try await createFeishuDocument(title: title, content: content, folderToken: folderToken)
                    let docOutput = try Self.encodeJSONObject([
                        "ok": true,
                        "plugin": "feishu_calendar",
                        "channel": activity.channel,
                        "document_id": activity.target,
                        "title": activity.title,
                        "url": activity.documentURL ?? ""
                    ])
                    recordIdempotentWrite(
                        key: args["idempotency_key"] as? String,
                        result: docOutput,
                        target: activity.target,
                        isLocalDemo: activity.channel == "local"
                    )
                    return docOutput
                }

            default:
                break
            }
        }

        // The meeting closeout: one call that writes the minutes document and then the group receipt under
        // deterministic keys, so re-running the loop after a review cannot double-post either of them.
        if plugin.id == "feishu_calendar", tool.name == "meeting_closeout" {
            return try await feishuMeetingCloseout(arguments: args)
        }

        if plugin.manifest.isV3 {
            let host = ensureRuntimeHost(for: plugin)
            return try await host.invokeTool(
                plugin: plugin,
                tool: tool,
                arguments: args,
                workspaceDirectory: workspaceDirectory ?? self.workspaceDirectory
            )
        }

        return try await evaluateJSTool(
            plugin: plugin,
            tool: tool,
            argumentsData: argsData,
            workspaceDirectory: workspaceDirectory
        )
    }

    /// Writes the minutes document and the group receipt for one meeting.
    /// Keys default to `meeting:<date>:<receive_id>:<title>:<minutes_digest>` so the same meeting loop is idempotent
    /// without the model having to invent a key; an explicit `idempotency_key` overrides both.
    func feishuMeetingCloseout(arguments: [String: Any]) async throws -> String {
        let title = ((arguments["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = ((arguments["minutes"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !minutes.isEmpty else {
            throw DesktopRuntimeError.message("meeting_closeout 需要非空的 title 与 minutes。")
        }
        let day = Self.dateFormatter.string(from: referenceDateProvider())
        let rawReceiveID = ((arguments["receive_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultReceiveID = settingValue(pluginID: "feishu_calendar", key: "default_receive_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReceiveID = rawReceiveID.isEmpty ? defaultReceiveID : rawReceiveID
        let receiveSegment = resolvedReceiveID.isEmpty ? "default" : String(resolvedReceiveID.prefix(24))
        let minutesDigest = DesktopFeishuIdempotency.shortDigest(minutes)
        let defaultBase = "meeting:\(day):\(receiveSegment):\(String(title.prefix(32))):\(minutesDigest)"
        let base = DesktopFeishuIdempotency.normalize(arguments["idempotency_key"] as? String) ?? defaultBase

        return try await withIdempotencyLock(key: base) {
            let docIsLocal = !computeHasFeishuOpenAPICredentials()
            var document: [String: Any]
            var documentReplayed = false
            if let stored = DesktopFeishuIdempotency.read(base + ":doc", isLocalDemo: docIsLocal,
                                                          from: readPluginStorage(pluginID: "feishu_calendar")) {
                documentReplayed = true
                document = (try? JSONSerialization.jsonObject(with: Data(stored.result.utf8)) as? [String: Any]) ?? [:]
            } else {
                let activity = try await createFeishuDocument(title: title, content: minutes)
                document = ["ok": true, "document_id": activity.target, "title": activity.title,
                            "url": activity.documentURL ?? "", "channel": activity.channel]
                recordIdempotentWrite(key: base + ":doc",
                    result: try Self.encodeJSONObject(document), target: activity.target,
                    isLocalDemo: activity.channel == "local")
            }

            // The receipt only ships once the document exists, so the group never gets a dead link.
            // Re-read storage after the document write so we never inspect a stale pre-await snapshot.
            let documentURL = (document["url"] as? String) ?? ""
            let receiptBody = ((arguments["receipt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "纪要已归档：\(title)\n\(documentURL.isEmpty ? "" : documentURL)"
            let receiptIsLocal = !isFeishuBotMessageRemote(receiveID: rawReceiveID)
            var receipt: [String: Any]
            var receiptReplayed = false
            if let stored = DesktopFeishuIdempotency.read(base + ":receipt", isLocalDemo: receiptIsLocal,
                                                          from: readPluginStorage(pluginID: "feishu_calendar")) {
                receiptReplayed = true
                receipt = (try? JSONSerialization.jsonObject(with: Data(stored.result.utf8)) as? [String: Any]) ?? [:]
            } else if arguments["send_receipt"] as? Bool == false {
                receipt = ["ok": true, "skipped": true]
            } else {
                let activity = try await sendFeishuBotMessage(title: "会后回执 · \(title)", content: receiptBody,
                    msgType: "interactive", receiveID: rawReceiveID)
                receipt = ["ok": true, "message_id": activity.id, "title": activity.title, "target": activity.target]
                recordIdempotentWrite(key: base + ":receipt",
                    result: try Self.encodeJSONObject(receipt), target: activity.target,
                    isLocalDemo: activity.channel == "local")
            }

            // Recipe bindings only read one level (`${step.x.output.field}`), so the two things a workflow needs are
            // also exposed flat. The nested objects stay for the transcript card.
            return try Self.encodeJSONObject([
                "ok": true,
                "plugin": "feishu_calendar",
                "idempotency_key": base,
                "document": document,
                "receipt": receipt,
                "document_id": document["document_id"] ?? "",
                "url": document["url"] ?? "",
                "message_id": receipt["message_id"] ?? "",
                "replayed": documentReplayed && receiptReplayed,
                "document_replayed": documentReplayed,
                "receipt_replayed": receiptReplayed
            ])
        }
    }

    func isFeishuBotMessageRemote(receiveID: String) -> Bool {
        let cleanTarget = receiveID.trimmingCharacters(in: .whitespacesAndNewlines)
        let webhookURL = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (!webhookURL.isEmpty && cleanTarget.isEmpty) || computeHasFeishuOpenAPICredentials()
    }

    func withIdempotencyLock<T>(key rawKey: String?, operation: () async throws -> T) async rethrows -> T {
        guard let key = DesktopFeishuIdempotency.normalize(rawKey) else {
            return try await operation()
        }
        while inFlightIdempotencyWaiters[key] != nil {
            await withCheckedContinuation { continuation in
                inFlightIdempotencyWaiters[key, default: []].append(continuation)
            }
        }
        inFlightIdempotencyWaiters[key] = []
        defer {
            let waiters = inFlightIdempotencyWaiters.removeValue(forKey: key) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
        return try await operation()
    }

    /// Remembers a confirmed write under the caller's key so the same meeting loop cannot post twice.
    func recordIdempotentWrite(key rawKey: String?, result: String, target: String, isLocalDemo: Bool = false) {
        guard let key = DesktopFeishuIdempotency.normalize(rawKey) else { return }
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        DesktopFeishuIdempotency.write(.init(key: key, result: result, target: target,
            recordedAt: Self.dateTimeFormatter.string(from: referenceDateProvider())),
            isLocalDemo: isLocalDemo, into: &storage)
        writePluginStorage(pluginID: "feishu_calendar", storage: storage)
    }

    private final class SandboxHTTPBox: @unchecked Sendable {
        var result: Result<(Data, Int), Error>?
    }

    func performSynchronousHTTPRequest(request: URLRequest, host: String) throws -> String {
        let transport = self.httpTransport
        let box = SandboxHTTPBox()
        let semaphore = DispatchSemaphore(value: 0)
        let capturedRequest = request
        Task.detached {
            do {
                let response = try await transport.send(request: capturedRequest)
                box.result = .success(response)
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 22) == .timedOut {
            throw DesktopRuntimeError.message("外部请求超时（20 秒）：\(host)")
        }
        switch box.result {
        case .success(let (data, status)):
            let bodyText = String(decoding: data, as: UTF8.self)
            let parsedJSON = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
            let payload: [String: Any] = [
                "ok": (200...299).contains(status),
                "status": status,
                "body": bodyText,
                "text": bodyText,
                "json": parsedJSON
            ]
            return try Self.encodeJSONObject(payload)
        case .failure(let error):
            throw error
        case .none:
            throw DesktopRuntimeError.message("外部请求未返回结果：\(host)")
        }
    }

    nonisolated static func resolveAuthorizedWorkspaceFileURL(
        rootDirectory: URL,
        relativePath: String,
        allowedPrefixes: [String],
        createParents: Bool
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DesktopRuntimeError.message("工作区文件路径无效或包含越界访问：\(relativePath)")
        }

        let normalizedPath = components.joined(separator: "/")
        let normalizedPrefixes = allowedPrefixes.compactMap { raw -> String? in
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return clean.isEmpty ? nil : clean
        }
        let isAuthorized = normalizedPrefixes.contains { prefix in
            prefix == "*" || normalizedPath == prefix || normalizedPath.hasPrefix(prefix + "/")
        }
        guard isAuthorized else {
            throw DesktopRuntimeError.message("插件未授权访问工作区路径 \(normalizedPath)（允许前缀：\(allowedPrefixes.joined(separator: ", "))）。")
        }

        let manager = FileManager.default
        if let kind = try? manager.attributesOfItem(atPath: rootDirectory.path)[.type],
           kind as? FileAttributeType == .typeSymbolicLink {
            throw DesktopRuntimeError.message("工作区路径不能包含符号链接。")
        }
        let standardizedRoot = rootDirectory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(rootDirectory.lastPathComponent, isDirectory: true)
        if createParents {
            try manager.createDirectory(at: standardizedRoot, withIntermediateDirectories: true)
        }

        var url = standardizedRoot
        for component in components {
            url.appendPathComponent(String(component))
            if let kind = try? manager.attributesOfItem(atPath: url.path)[.type],
               kind as? FileAttributeType == .typeSymbolicLink {
                throw DesktopRuntimeError.message("工作区路径不能包含符号链接：\(relativePath)")
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(standardizedRoot.path + "/") else {
            throw DesktopRuntimeError.message("文件路径越出了当前会话工作区：\(relativePath)")
        }
        if createParents {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return url
    }

    func evaluateJSTool(
        plugin: DesktopInstalledPlugin,
        tool: DesktopPluginToolManifest,
        argumentsData: Data,
        workspaceDirectory: URL?
    ) async throws -> String {
        let initialStorage = readPluginStorage(pluginID: plugin.id)
        var settingsMap: [String: String] = [:]
        for field in plugin.manifest.settingsSchema where field.kind != .secret {
            settingsMap[field.key] = settingValue(pluginID: plugin.id, key: field.key)
        }
        settingsMap["today"] = Self.dateFormatter.string(from: referenceDateProvider())
        settingsMap["mode"] = (plugin.id == "feishu_calendar" && hasFeishuRemoteCredentials) ? "feishu" : "local"
        let frozenSettingsMap = settingsMap
        let transport = self.httpTransport
        let targetWorkspaceDir = workspaceDirectory ?? self.workspaceDirectory

        let (jsonString, updatedStorage, storageMutated) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(String, [String: String], Bool), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let context = JSContext() else {
                    continuation.resume(throwing: DesktopRuntimeError.message("无法初始化插件 JavaScript 沙箱。"))
                    return
                }
                var jsException: String?
                context.exceptionHandler = { _, exception in
                    jsException = exception?.toString() ?? "未知脚本错误"
                }

                var currentStorage = initialStorage
                var storageMutated = false
                let arguments = (try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any]) ?? [:]

                let getSettingBlock: @convention(block) (String) -> String = { key in
                    frozenSettingsMap[key] ?? ""
                }
                let getStorageBlock: @convention(block) (String) -> String = { key in
                    currentStorage[key] ?? ""
                }
                let setStorageBlock: @convention(block) (String, String) -> Void = { key, value in
                    currentStorage[key] = value
                    storageMutated = true
                }
                let httpFetchBlock: @convention(block) (String, String) -> String = { urlString, optionsJSON in
                    guard let url = URL(string: urlString),
                          url.scheme?.lowercased() == "https",
                          let host = url.host?.lowercased() else {
                        return "__AMBER_ERR__:插件仅允许访问 HTTPS 地址：\(urlString)"
                    }
                    let allowedDomains = plugin.manifest.capabilities.networkDomains.map { $0.lowercased() }
                    let permitted = allowedDomains.contains { allowed in
                        host == allowed || host.hasSuffix("." + allowed)
                    }
                    guard permitted else {
                        return "__AMBER_ERR__:插件 \(plugin.manifest.name) 未授权访问域名 \(host)（允许列表：\(allowedDomains.joined(separator: ", "))）。"
                    }

                    let optionsData = Data(optionsJSON.utf8)
                    let options = (try? JSONSerialization.jsonObject(with: optionsData) as? [String: Any]) ?? [:]
                    let method = ((options["method"] as? String) ?? "GET").uppercased()
                    var request = URLRequest(url: url)
                    request.httpMethod = method
                    request.timeoutInterval = 20
                    if let headers = options["headers"] as? [String: Any] {
                        for (k, v) in headers {
                            request.setValue(String(describing: v), forHTTPHeaderField: k)
                        }
                    }
                    if let bodyString = options["body"] as? String {
                        request.httpBody = Data(bodyString.utf8)
                    } else if let bodyObj = options["body"],
                              !(bodyObj is NSNull),
                              JSONSerialization.isValidJSONObject(bodyObj),
                              let data = try? JSONSerialization.data(withJSONObject: bodyObj) {
                        request.httpBody = data
                    }

                    let box = SandboxHTTPBox()
                    let semaphore = DispatchSemaphore(value: 0)
                    let capturedRequest = request
                    Task.detached {
                        do {
                            let response = try await transport.send(request: capturedRequest)
                            box.result = .success(response)
                        } catch {
                            box.result = .failure(error)
                        }
                        semaphore.signal()
                    }
                    if semaphore.wait(timeout: .now() + 22) == .timedOut {
                        return "__AMBER_ERR__:外部请求超时（20 秒）：\(host)"
                    }
                    switch box.result {
                    case .success(let (data, status)):
                        let bodyText = String(decoding: data, as: UTF8.self)
                        let parsedJSON = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
                        let payload: [String: Any] = [
                            "ok": (200...299).contains(status),
                            "status": status,
                            "body": bodyText,
                            "text": bodyText,
                            "json": parsedJSON
                        ]
                        if let encoded = try? DesktopPluginStore.encodeJSONObject(payload) {
                            return encoded
                        }
                        return #"{"ok":false,"status":500,"body":""}"#
                    case .failure(let error):
                        return "__AMBER_ERR__:\(error.localizedDescription)"
                    case .none:
                        return "__AMBER_ERR__:外部请求未返回结果：\(host)"
                    }
                }
                let workspaceReadBlock: @convention(block) (String) -> String = { relativePath in
                    do {
                        let url = try DesktopPluginStore.resolveAuthorizedWorkspaceFileURL(
                            rootDirectory: targetWorkspaceDir,
                            relativePath: relativePath,
                            allowedPrefixes: plugin.manifest.capabilities.workspaceReadPrefixes,
                            createParents: false
                        )
                        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                            return "__AMBER_ERR__:工作区文件不存在或不是普通文件：\(relativePath)"
                        }
                        let data = try Data(contentsOf: url)
                        guard let text = String(data: data, encoding: .utf8) else {
                            return "__AMBER_ERR__:工作区文件不是有效的 UTF-8 文本：\(relativePath)"
                        }
                        return text
                    } catch {
                        return "__AMBER_ERR__:\(error.localizedDescription)"
                    }
                }
                let workspaceWriteBlock: @convention(block) (String, String) -> String = { relativePath, content in
                    guard tool.effect == .sideEffect || tool.effect == .idempotent else {
                        return "__AMBER_ERR__:只读工具（\(tool.name)，effect=\(tool.effect.rawValue)）禁止调用 amber.workspace.write 写入工作区文件；请将工具 effect 声明为 sideEffect 或 idempotent。"
                    }
                    do {
                        let url = try DesktopPluginStore.resolveAuthorizedWorkspaceFileURL(
                            rootDirectory: targetWorkspaceDir,
                            relativePath: relativePath,
                            allowedPrefixes: plugin.manifest.capabilities.workspaceWritePrefixes,
                            createParents: true
                        )
                        try Data(content.utf8).write(to: url, options: .atomic)
                        return "ok"
                    } catch {
                        return "__AMBER_ERR__:\(error.localizedDescription)"
                    }
                }

                context.setObject(getSettingBlock, forKeyedSubscript: "__amberGetSetting" as NSString)
                context.setObject(getStorageBlock, forKeyedSubscript: "__amberGetStorage" as NSString)
                context.setObject(setStorageBlock, forKeyedSubscript: "__amberSetStorage" as NSString)
                context.setObject(httpFetchBlock, forKeyedSubscript: "__amberHttpFetch" as NSString)
                context.setObject(workspaceReadBlock, forKeyedSubscript: "__amberWorkspaceRead" as NSString)
                context.setObject(workspaceWriteBlock, forKeyedSubscript: "__amberWorkspaceWrite" as NSString)

                let bootstrap = """
                function __amberUnwrap(raw) {
                    if (typeof raw === 'string' && raw.indexOf('__AMBER_ERR__:') === 0) {
                        throw new Error(raw.slice('__AMBER_ERR__:'.length));
                    }
                    return raw;
                }
                const amber = Object.freeze({
                    settings: Object.freeze({
                        get: function(key) { return __amberGetSetting(String(key)); }
                    }),
                    storage: Object.freeze({
                        get: function(key) { return __amberGetStorage(String(key)); },
                        set: function(key, val) { __amberSetStorage(String(key), typeof val === 'string' ? val : JSON.stringify(val)); }
                    }),
                    http: Object.freeze({
                        fetch: function(url, options) {
                            const raw = __amberUnwrap(__amberHttpFetch(String(url), options == null ? '{}' : JSON.stringify(options)));
                            return JSON.parse(raw);
                        }
                    }),
                    workspace: Object.freeze({
                        read: function(path) {
                            return __amberUnwrap(__amberWorkspaceRead(String(path)));
                        },
                        write: function(path, content) {
                            __amberUnwrap(__amberWorkspaceWrite(String(path), typeof content === 'string' ? content : JSON.stringify(content)));
                            return true;
                        }
                    })
                });
                """
                context.evaluateScript(bootstrap)
                context.evaluateScript(plugin.scriptSource)
                if let jsException {
                    continuation.resume(throwing: DesktopRuntimeError.message("插件 \(plugin.manifest.name) 脚本加载失败：\(jsException)"))
                    return
                }

                guard let fn = context.objectForKeyedSubscript(tool.entry), !fn.isUndefined else {
                    continuation.resume(throwing: DesktopRuntimeError.message("插件 \(plugin.manifest.name) 缺少入口函数 \(tool.entry)。"))
                    return
                }
                guard let resultValue = fn.call(withArguments: [arguments]) else {
                    continuation.resume(throwing: DesktopRuntimeError.message("插件工具 \(tool.name) 未返回结果。"))
                    return
                }
                if let jsException {
                    continuation.resume(throwing: DesktopRuntimeError.message("插件工具 \(tool.name) 执行异常：\(jsException)"))
                    return
                }

                let serialized: String
                if let json = context.objectForKeyedSubscript("JSON")?
                    .objectForKeyedSubscript("stringify")?
                    .call(withArguments: [resultValue])?
                    .toString(),
                   json != "undefined" {
                    serialized = json
                } else {
                    serialized = resultValue.toString() ?? "{}"
                }
                continuation.resume(returning: (serialized, currentStorage, storageMutated))
            }
        }

        if storageMutated {
            writePluginStorage(pluginID: plugin.id, storage: updatedStorage)
            if plugin.id == "feishu_calendar" {
                loadCalendarEventsFromStorage()
                loadBotActivitiesFromStorage()
            }
            rebuildProjections()
        }

        return jsonString
    }

}
