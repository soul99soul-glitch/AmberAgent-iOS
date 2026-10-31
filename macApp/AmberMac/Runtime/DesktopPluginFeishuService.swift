import Foundation

extension DesktopPluginStore {
    // MARK: Feishu Calendar (CalDAV + OpenAPI) & Feishu Bot Storage & Remote Sync

    var feishuCalendarConnectionBadge: String {
        if hasFeishuCalDAVCredentials {
            return "CalDAV 直连"
        }
        if computeHasFeishuOpenAPICredentials() {
            return "飞书开放平台"
        }
        return "本地演示模式"
    }

    var feishuBotConnectionBadge: String {
        let webhook = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openAPI = computeHasFeishuOpenAPICredentials()
        if !webhook.isEmpty && openAPI {
            return "Webhook + 应用机器人"
        }
        if !webhook.isEmpty {
            return "群 Webhook 已就绪"
        }
        if openAPI {
            return "应用机器人已就绪"
        }
        return "本地沙箱模式"
    }

    func loadCalendarEventsFromStorage() {
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        if let rawEvents = storage["events"],
           let data = rawEvents.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([DesktopPluginEventItem].self, from: data) {
            let sorted = decoded.sorted { $0.startTime < $1.startTime }
            if calendarEvents != sorted { calendarEvents = sorted }
            return
        }
        let seeded = Self.defaultSeededEvents(now: referenceDateProvider())
        saveCalendarEventsToStorage(seeded, storage: &storage)
        if calendarEvents != seeded { calendarEvents = seeded }
    }

    func saveCalendarEventsToStorage(_ events: [DesktopPluginEventItem], storage: inout [String: String]) {
        let sorted = events.sorted { $0.startTime < $1.startTime }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(sorted) {
            storage["events"] = String(decoding: data, as: UTF8.self)
            writePluginStorage(pluginID: "feishu_calendar", storage: storage)
        }
        if calendarEvents != sorted { calendarEvents = sorted }
    }

    func loadBotActivitiesFromStorage() {
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        if let raw = storage["bot_activities"],
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([DesktopPluginBotActivityItem].self, from: data) {
            if botActivities != decoded { botActivities = decoded }
            return
        }
        let seeded = Self.defaultSeededBotActivities(now: referenceDateProvider())
        saveBotActivitiesToStorage(seeded, storage: &storage)
        if botActivities != seeded { botActivities = seeded }
    }

    func saveBotActivitiesToStorage(_ items: [DesktopPluginBotActivityItem], storage: inout [String: String]) {
        let trimmed = Array(items.prefix(50))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(trimmed) {
            storage["bot_activities"] = String(decoding: data, as: UTF8.self)
            writePluginStorage(pluginID: "feishu_calendar", storage: storage)
        }
        if botActivities != trimmed { botActivities = trimmed }
    }

    func deleteBotActivity(id: String) {
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        let next = botActivities.filter { $0.id != id }
        guard next != botActivities else { return }
        saveBotActivitiesToStorage(next, storage: &storage)
        rebuildProjections()
    }

    @discardableResult
    func createCalendarEvent(
        summary: String,
        startTime: String,
        endTime: String,
        location: String = "飞书会议",
        attendees: [String] = [],
        notes: String = ""
    ) async throws -> DesktopPluginEventItem {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSummary.isEmpty else {
            throw DesktopRuntimeError.message("日程主题不能为空。")
        }
        let normalizedStart = Self.normalizeDateTimeString(startTime, fallbackDate: referenceDateProvider())
        let normalizedEnd = Self.normalizeDateTimeString(endTime, fallbackDate: referenceDateProvider())
        let eventUID = "evt_" + UUID().uuidString.prefix(8).lowercased()
        var source = "local"

        if let feishuPlugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            if computeHasFeishuCalDAVCredentials() {
                let server = resolvedCalDAVServerURL()
                let base = server.hasSuffix("/") ? String(server.dropLast()) : server
                let putURL = "\(base)/\(eventUID).ics"
                let icsPayload = Self.buildICalendarEvent(
                    uid: eventUID,
                    summary: cleanSummary,
                    startTime: normalizedStart,
                    endTime: normalizedEnd,
                    location: location,
                    notes: notes
                )
                _ = try await performAuthorizedHTTP(
                    plugin: feishuPlugin,
                    urlString: putURL,
                    method: "PUT",
                    headers: [
                        "Authorization": try resolveCalDAVBasicAuthHeader(),
                        "Content-Type": "text/calendar; charset=utf-8"
                    ],
                    body: Data(icsPayload.utf8)
                )
                source = "feishu"
            } else if computeHasFeishuOpenAPICredentials() {
                let token = try await resolveFeishuAccessToken(plugin: feishuPlugin)
                let calendarID = settingValue(pluginID: "feishu_calendar", key: "default_calendar_id")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let targetCalendar = calendarID.isEmpty ? "primary" : calendarID
                let encodedCal = targetCalendar.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "primary"
                let endpoint = "https://open.feishu.cn/open-apis/calendar/v4/calendars/\(encodedCal)/events"
                let body: [String: Any] = [
                    "summary": cleanSummary,
                    "description": notes,
                    "start_time": ["timestamp": String(Self.parseTimestamp(normalizedStart, fallback: referenceDateProvider()))],
                    "end_time": ["timestamp": String(Self.parseTimestamp(normalizedEnd, fallback: referenceDateProvider().addingTimeInterval(3600)))]
                ]
                let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                _ = try await performAuthorizedHTTP(
                    plugin: feishuPlugin,
                    urlString: endpoint,
                    method: "POST",
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json; charset=utf-8"
                    ],
                    body: bodyData
                )
                source = "feishu"
            }
        }

        let item = DesktopPluginEventItem(
            id: eventUID,
            summary: cleanSummary,
            startTime: normalizedStart,
            endTime: normalizedEnd,
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            attendees: attendees,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = calendarEvents
        current.append(item)
        saveCalendarEventsToStorage(current, storage: &storage)
        rebuildProjections()
        return item
    }

    func deleteCalendarEvent(id: String) {
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        let next = calendarEvents.filter { $0.id != id }
        guard next != calendarEvents else { return }
        saveCalendarEventsToStorage(next, storage: &storage)
        rebuildProjections()
    }

    func computeHasFeishuCalDAVCredentials() -> Bool {
        let user = settingValue(pluginID: "feishu_calendar", key: "caldav_username")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = settingValue(pluginID: "feishu_calendar", key: "caldav_password")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !user.isEmpty && !pass.isEmpty
    }

    func computeHasFeishuOpenAPICredentials() -> Bool {
        let pat = settingValue(pluginID: "feishu_calendar", key: "personal_access_token")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pat.isEmpty { return true }
        let appID = settingValue(pluginID: "feishu_calendar", key: "app_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = settingValue(pluginID: "feishu_calendar", key: "app_secret")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !appID.isEmpty && !appSecret.isEmpty
    }

    func computeHasFeishuBotCredentials() -> Bool {
        let webhook = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !webhook.isEmpty || computeHasFeishuOpenAPICredentials()
    }

    func computeHasFeishuRemoteCredentials() -> Bool {
        computeHasFeishuCalDAVCredentials() || computeHasFeishuOpenAPICredentials()
    }

    func resolvedCalDAVServerURL() -> String {
        let raw = settingValue(pluginID: "feishu_calendar", key: "caldav_server")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "https://caldav.feishu.cn" : raw
    }

    func resolveCalDAVBasicAuthHeader() throws -> String {
        let user = settingValue(pluginID: "feishu_calendar", key: "caldav_username")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = settingValue(pluginID: "feishu_calendar", key: "caldav_password")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !pass.isEmpty else {
            throw DesktopRuntimeError.message("请先在设置 → 插件 → 飞书的「日历 (CalDAV)」中填写 CalDAV 用户名与密码。")
        }
        let encoded = Data("\(user):\(pass)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// Synchronizes events from Feishu CalDAV (`caldav.feishu.cn`) first, or falls back to Feishu OpenAPI (`open.feishu.cn`).
    @discardableResult
    func syncFeishuCalendar() async throws -> String {
        guard let pluginIndex = plugins.firstIndex(where: { $0.id == "feishu_calendar" }) else {
            throw DesktopRuntimeError.message("飞书插件未安装。")
        }
        let plugin = plugins[pluginIndex]
        guard hasFeishuRemoteCredentials else {
            let status = "本地演示模式（在插件设置中填入飞书 CalDAV 账号密码后即可直连同步个人日历）"
            updatePluginSyncStatus(id: "feishu_calendar", status: status)
            return status
        }
        isSyncingPluginID = "feishu_calendar"
        defer { isSyncingPluginID = nil }

        let remoteEvents: [DesktopPluginEventItem]
        let protocolLabel: String
        if computeHasFeishuCalDAVCredentials() {
            protocolLabel = "CalDAV"
            let endpoint = resolvedCalDAVServerURL()
            let reportXML = """
            <?xml version="1.0" encoding="utf-8" ?>
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
              <d:prop>
                <d:getetag/>
                <c:calendar-data/>
              </d:prop>
              <c:filter>
                <c:comp-filter name="VCALENDAR">
                  <c:comp-filter name="VEVENT"/>
                </c:comp-filter>
              </c:filter>
            </c:calendar-query>
            """
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: endpoint,
                method: "REPORT",
                headers: [
                    "Authorization": try resolveCalDAVBasicAuthHeader(),
                    "Depth": "1",
                    "Content-Type": "application/xml; charset=utf-8"
                ],
                body: Data(reportXML.utf8)
            )
            let parsedICS = Self.parseCalDAVEICSData(data: data, fallbackDate: referenceDateProvider())
            remoteEvents = parsedICS.isEmpty
                ? Self.parseFeishuEventsResponse(data: data, fallbackDate: referenceDateProvider())
                : parsedICS
        } else {
            protocolLabel = "OpenAPI"
            let token = try await resolveFeishuAccessToken(plugin: plugin)
            let calendarID = settingValue(pluginID: "feishu_calendar", key: "default_calendar_id")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let targetCalendar = calendarID.isEmpty ? "primary" : calendarID
            let encodedCal = targetCalendar.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "primary"
            let endpoint = "https://open.feishu.cn/open-apis/calendar/v4/calendars/\(encodedCal)/events"
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: endpoint,
                method: "GET",
                headers: ["Authorization": "Bearer \(token)"],
                body: nil
            )
            remoteEvents = Self.parseFeishuEventsResponse(data: data, fallbackDate: referenceDateProvider())
        }

        if !remoteEvents.isEmpty {
            var storage = readPluginStorage(pluginID: "feishu_calendar")
            let localOnly = calendarEvents.filter { $0.source == "local" }
            var mergedByID = Dictionary(uniqueKeysWithValues: localOnly.map { ($0.id, $0) })
            for remote in remoteEvents { mergedByID[remote.id] = remote }
            saveCalendarEventsToStorage(Array(mergedByID.values), storage: &storage)
            rebuildProjections()
        }
        let status = "已同步飞书日历 · \(protocolLabel)（共 \(calendarEvents.count) 项日程）"
        updatePluginSyncStatus(id: "feishu_calendar", status: status)
        return status
    }

    // MARK: Feishu Bot Actions (Webhook + OpenAPI Messages, Group History & Cloud Docs)

    @discardableResult
    func sendFeishuBotMessage(
        title: String = "",
        content: String,
        msgType: String = "interactive",
        receiveID: String = ""
    ) async throws -> DesktopPluginBotActivityItem {
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty else {
            throw DesktopRuntimeError.message("发送的飞书消息内容不能为空。")
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Amber 智能体通知"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTarget = receiveID.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTarget = settingValue(pluginID: "feishu_calendar", key: "default_receive_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTarget = cleanTarget.isEmpty ? defaultTarget : cleanTarget
        let webhookURL = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var channelUsed = "local"
        var targetLabel = resolvedTarget.isEmpty ? "飞书群机器人" : resolvedTarget

        if let plugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            if !webhookURL.isEmpty && cleanTarget.isEmpty {
                var bodyObj: [String: Any]
                if msgType == "text" {
                    bodyObj = [
                        "msg_type": "text",
                        "content": ["text": "\(cleanTitle)\n\(cleanContent)"]
                    ]
                } else {
                    bodyObj = [
                        "msg_type": "interactive",
                        "card": Self.buildFeishuInteractiveCard(title: cleanTitle, markdown: cleanContent)
                    ]
                }
                let secret = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_secret")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !secret.isEmpty {
                    let ts = String(Int(referenceDateProvider().timeIntervalSince1970))
                    bodyObj["timestamp"] = ts
                    bodyObj["sign"] = Self.computeFeishuWebhookSign(timestamp: ts, secret: secret)
                }
                let bodyData = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])
                _ = try await performAuthorizedHTTP(
                    plugin: plugin,
                    urlString: webhookURL,
                    method: "POST",
                    headers: ["Content-Type": "application/json; charset=utf-8"],
                    body: bodyData
                )
                channelUsed = "webhook"
                targetLabel = "群自定义机器人 Webhook"
            } else if computeHasFeishuOpenAPICredentials() {
                guard !resolvedTarget.isEmpty else {
                    throw DesktopRuntimeError.message("使用飞书应用机器人发送消息时，需提供 receive_id 或在插件设置中填写默认消息接收 ID（如 oc_xxx）。")
                }
                let token = try await resolveFeishuAccessToken(plugin: plugin)
                let idType = Self.inferFeishuReceiveIDType(resolvedTarget)
                let endpoint = "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=\(idType)"
                let contentJSON: String
                let resolvedMsgType: String
                if msgType == "text" {
                    resolvedMsgType = "text"
                    contentJSON = try Self.encodeJSONObject(["text": "\(cleanTitle)\n\(cleanContent)"])
                } else {
                    resolvedMsgType = "interactive"
                    contentJSON = try Self.encodeJSONObject(Self.buildFeishuInteractiveCard(title: cleanTitle, markdown: cleanContent))
                }
                let payload = try JSONSerialization.data(
                    withJSONObject: [
                        "receive_id": resolvedTarget,
                        "msg_type": resolvedMsgType,
                        "content": contentJSON
                    ],
                    options: [.sortedKeys]
                )
                _ = try await performAuthorizedHTTP(
                    plugin: plugin,
                    urlString: endpoint,
                    method: "POST",
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json; charset=utf-8"
                    ],
                    body: payload
                )
                channelUsed = "openapi"
            }
        }

        let item = DesktopPluginBotActivityItem(
            id: "bot_" + UUID().uuidString.prefix(8).lowercased(),
            kind: msgType == "text" ? "message" : "card",
            title: cleanTitle,
            summary: cleanContent,
            channel: channelUsed,
            target: targetLabel,
            timestamp: Self.dateTimeFormatter.string(from: referenceDateProvider()),
            documentURL: nil
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = botActivities
        current.insert(item, at: 0)
        saveBotActivitiesToStorage(current, storage: &storage)
        rebuildProjections()
        return item
    }

    @discardableResult
    func fetchFeishuChatHistory(chatID: String = "", limit: Int = 15) async throws -> (messages: [[String: String]], activity: DesktopPluginBotActivityItem) {
        let defaultTarget = settingValue(pluginID: "feishu_calendar", key: "default_receive_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetChat = chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (defaultTarget.isEmpty ? "oc_product_core_group" : defaultTarget)
            : chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedLimit = max(1, min(50, limit))

        var messages: [[String: String]] = []
        var channelUsed = "local"

        if computeHasFeishuOpenAPICredentials(),
           let plugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            let token = try await resolveFeishuAccessToken(plugin: plugin)
            let encodedChat = targetChat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? targetChat
            let endpoint = "https://open.feishu.cn/open-apis/im/v1/messages?container_id_type=chat&container_id=\(encodedChat)&page_size=\(clampedLimit)"
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: endpoint,
                method: "GET",
                headers: ["Authorization": "Bearer \(token)"],
                body: nil
            )
            messages = Self.parseFeishuChatMessages(data: data)
            channelUsed = "openapi"
        }

        if messages.isEmpty {
            messages = [
                ["sender": "林夏", "time": "10:15", "text": "本周飞书插件准备拆成 CalDAV 日历和机器人两个模块，大家确认下接口边界。"],
                ["sender": "周航", "time": "10:18", "text": "赞成！个人日历直接走 CalDAV 免管理员审批，机器人专门负责群卡片推送和云文档读写。"],
                ["sender": "陈默", "time": "10:22", "text": "下午 14:30 评审会前把测试报告卡片推到群里。"]
            ]
        }

        let summaryLines = messages.prefix(6).map { msg in
            "[\(msg["time"] ?? "")] \(msg["sender"] ?? "成员")：\(msg["text"] ?? "")"
        }.joined(separator: "\n")

        let activity = DesktopPluginBotActivityItem(
            id: "bot_" + UUID().uuidString.prefix(8).lowercased(),
            kind: "chat_history",
            title: "飞书群聊记录 (\(targetChat))",
            summary: summaryLines,
            channel: channelUsed,
            target: targetChat,
            timestamp: Self.dateTimeFormatter.string(from: referenceDateProvider()),
            documentURL: nil
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = botActivities
        current.insert(activity, at: 0)
        saveBotActivitiesToStorage(current, storage: &storage)
        rebuildProjections()
        return (messages, activity)
    }

    @discardableResult
    func readFeishuDocument(documentInput: String) async throws -> (docID: String, title: String, content: String, activity: DesktopPluginBotActivityItem) {
        let docID = Self.extractFeishuDocumentID(from: documentInput)
        guard !docID.isEmpty else {
            throw DesktopRuntimeError.message("请提供有效的飞书云文档链接或 document_id。")
        }

        var docTitle = "飞书云文档 (\(docID))"
        var docContent = ""
        var channelUsed = "local"

        if computeHasFeishuOpenAPICredentials(),
           let plugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            let token = try await resolveFeishuAccessToken(plugin: plugin)
            let encodedID = docID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? docID
            let endpoint = "https://open.feishu.cn/open-apis/docx/v1/documents/\(encodedID)/raw_content"
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: endpoint,
                method: "GET",
                headers: ["Authorization": "Bearer \(token)"],
                body: nil
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = root["data"] as? [String: Any],
               let rawText = dataObj["content"] as? String {
                docContent = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let firstLine = docContent.split(separator: "\n").first, !firstLine.isEmpty {
                    docTitle = String(firstLine.prefix(48))
                }
            }
            channelUsed = "openapi"
        }

        if docContent.isEmpty {
            docTitle = "Amber 飞书套件技术方案 (\(docID))"
            docContent = """
            1. 日历模块：支持标准 CalDAV (https://caldav.feishu.cn) Basic Auth 直连，无需管理员审批即可同步个人日程。
            2. 机器人模块：支持群自定义 Webhook（含 HMAC-SHA256 签名校验）与企业自建应用 OpenAPI（收发消息、拉取群聊记录、读写飞书 Docx 云文档）。
            3. 工作流联动：支持将日程一键推送至飞书群卡片，或将飞书文档读取到当前对话进行总结。
            """
        }

        let docURL = documentInput.hasPrefix("https://") ? documentInput : "https://feishu.cn/docx/\(docID)"
        let activity = DesktopPluginBotActivityItem(
            id: "bot_" + UUID().uuidString.prefix(8).lowercased(),
            kind: "doc_read",
            title: docTitle,
            summary: docContent,
            channel: channelUsed,
            target: docID,
            timestamp: Self.dateTimeFormatter.string(from: referenceDateProvider()),
            documentURL: docURL
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = botActivities
        current.insert(activity, at: 0)
        saveBotActivitiesToStorage(current, storage: &storage)
        rebuildProjections()
        return (docID, docTitle, docContent, activity)
    }

    @discardableResult
    func createFeishuDocument(title: String, content: String = "", folderToken: String = "") async throws -> DesktopPluginBotActivityItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw DesktopRuntimeError.message("飞书云文档标题不能为空。")
        }
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var docID = "doxcn_" + UUID().uuidString.prefix(8).lowercased()
        var channelUsed = "local"

        if computeHasFeishuOpenAPICredentials(),
           let plugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            let token = try await resolveFeishuAccessToken(plugin: plugin)
            var bodyObj: [String: Any] = ["title": cleanTitle]
            let cleanFolder = folderToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanFolder.isEmpty {
                bodyObj["folder_token"] = cleanFolder
            }
            let bodyData = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: "https://open.feishu.cn/open-apis/docx/v1/documents",
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json; charset=utf-8"
                ],
                body: bodyData
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = root["data"] as? [String: Any],
               let docObj = dataObj["document"] as? [String: Any],
               let remoteID = docObj["document_id"] as? String,
               !remoteID.isEmpty {
                docID = remoteID
            }
            channelUsed = "openapi"
        }

        let docURL = "https://feishu.cn/docx/\(docID)"
        let item = DesktopPluginBotActivityItem(
            id: "bot_" + UUID().uuidString.prefix(8).lowercased(),
            kind: "doc_create",
            title: cleanTitle,
            summary: cleanContent.isEmpty ? "已创建飞书云文档（\(docID)）" : cleanContent,
            channel: channelUsed,
            target: docID,
            timestamp: Self.dateTimeFormatter.string(from: referenceDateProvider()),
            documentURL: docURL
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = botActivities
        current.insert(item, at: 0)
        saveBotActivitiesToStorage(current, storage: &storage)
        rebuildProjections()
        return item
    }

    func updatePluginSyncStatus(id: String, status: String) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        var updated = plugins
        updated[index].lastSyncStatus = status
        if plugins != updated { plugins = updated }
    }

    func resolveFeishuAccessToken(plugin: DesktopInstalledPlugin) async throws -> String {
        let pat = settingValue(pluginID: plugin.id, key: "personal_access_token")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pat.isEmpty { return pat }

        let appID = settingValue(pluginID: plugin.id, key: "app_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = settingValue(pluginID: plugin.id, key: "app_secret")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !appSecret.isEmpty else {
            throw DesktopRuntimeError.message("请先在设置 → 插件 → 飞书中配置 App ID 与 App Secret，或个人访问令牌。")
        }

        let payload = try JSONSerialization.data(
            withJSONObject: ["app_id": appID, "app_secret": appSecret],
            options: [.sortedKeys]
        )
        let (data, _) = try await performAuthorizedHTTP(
            plugin: plugin,
            urlString: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
            method: "POST",
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: payload
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["tenant_access_token"] as? String) ?? (json["app_access_token"] as? String),
              !token.isEmpty else {
            throw DesktopRuntimeError.message("飞书鉴权响应未包含有效的 tenant_access_token，请核对 App ID 与 App Secret。")
        }
        return token
    }

    /// Enforces `capabilities.networkDomains` allowlist before dispatching any HTTP call.
    func performAuthorizedHTTP(
        plugin: DesktopInstalledPlugin,
        urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, Int) {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            throw DesktopRuntimeError.message("插件仅允许访问 HTTPS 地址：\(urlString)")
        }
        let allowedDomains = plugin.manifest.capabilities.networkDomains.map { $0.lowercased() }
        let permitted = allowedDomains.contains { allowed in
            host == allowed || host.hasSuffix("." + allowed)
        }
        guard permitted else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 未授权访问域名 \(host)（允许列表：\(allowedDomains.joined(separator: ", "))）。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        let (data, status) = try await httpTransport.send(request: request)
        guard (200...299).contains(status) else {
            throw DesktopRuntimeError.message("外部服务 \(host) 返回 HTTP \(status)。")
        }
        return (data, status)
    }

}
