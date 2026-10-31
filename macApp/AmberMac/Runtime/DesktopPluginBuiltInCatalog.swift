import CryptoKit
import Foundation

extension DesktopPluginStore {
    // MARK: Built-in Feishu Suite (Calendar CalDAV + Bot Webhook/OpenAPI) Helpers

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    func computeTodayFreeSlots(today: String) -> [DesktopPluginFreeSlot] {
        let startHour = max(0, min(23, Int(settingValue(pluginID: "feishu_calendar", key: "workday_start_hour")) ?? 9))
        let endHour = max(startHour + 1, min(24, Int(settingValue(pluginID: "feishu_calendar", key: "workday_end_hour")) ?? 18))
        let dayEvents = calendarEvents.filter { $0.datePrefix == today }
        let busyRanges: [(Int, Int)] = dayEvents.compactMap { ev in
            guard ev.startTime.count >= 16, ev.endTime.count >= 16 else { return nil }
            let sParts = String(ev.startTime.dropFirst(11).prefix(5)).split(separator: ":")
            let eParts = String(ev.endTime.dropFirst(11).prefix(5)).split(separator: ":")
            guard sParts.count == 2, eParts.count == 2,
                  let sh = Int(sParts[0]), let sm = Int(sParts[1]),
                  let eh = Int(eParts[0]), let em = Int(eParts[1]) else { return nil }
            let s = sh * 60 + sm
            let e = eh * 60 + em
            return e > s ? (s, e) : nil
        }.sorted { $0.0 < $1.0 }

        var slots: [DesktopPluginFreeSlot] = []
        var cursor = startHour * 60
        let dayEnd = endHour * 60
        for (bStart, bEnd) in busyRanges {
            if bStart - cursor >= 30 {
                slots.append(DesktopPluginFreeSlot(
                    start: String(format: "%02d:%02d", cursor / 60, cursor % 60),
                    end: String(format: "%02d:%02d", bStart / 60, bStart % 60),
                    minutes: bStart - cursor
                ))
            }
            if bEnd > cursor { cursor = bEnd }
        }
        if dayEnd - cursor >= 30 {
            slots.append(DesktopPluginFreeSlot(
                start: String(format: "%02d:%02d", cursor / 60, cursor % 60),
                end: String(format: "%02d:%02d", dayEnd / 60, dayEnd % 60),
                minutes: dayEnd - cursor
            ))
        }
        return slots
    }

    static func normalizeDateTimeString(_ raw: String, fallbackDate: Date) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "T", with: " ")
        if trimmed.count >= 16 {
            return String(trimmed.prefix(16))
        }
        if trimmed.count == 5, trimmed.contains(":") {
            return "\(dateFormatter.string(from: fallbackDate)) \(trimmed)"
        }
        return trimmed
    }

    static func parseTimestamp(_ raw: String, fallback: Date) -> Int {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "T", with: " ")
        if let date = dateTimeFormatter.date(from: String(normalized.prefix(16))) {
            return Int(date.timeIntervalSince1970)
        }
        return Int(fallback.timeIntervalSince1970)
    }

    /// Builds an RFC 5545 iCalendar payload for CalDAV `PUT` event creation.
    static func buildICalendarEvent(
        uid: String,
        summary: String,
        startTime: String,
        endTime: String,
        location: String,
        notes: String
    ) -> String {
        func toICSDateTime(_ str: String) -> String {
            let digits = str.filter(\.isNumber)
            if digits.count >= 12 {
                return "\(digits.prefix(8))T\(digits.dropFirst(8).prefix(4))00"
            }
            return "20261030T090000"
        }
        let dtStart = toICSDateTime(startTime)
        let dtEnd = toICSDateTime(endTime)
        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Amber//Feishu CalDAV Client//CN",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTART:\(dtStart)",
            "DTEND:\(dtEnd)",
            "SUMMARY:\(summary)",
            "LOCATION:\(location)",
            "DESCRIPTION:\(notes)",
            "END:VEVENT",
            "END:VCALENDAR"
        ].joined(separator: "\r\n")
    }

    /// Parses CalDAV `REPORT` XML (`<c:calendar-data>`) or raw `.ics` `BEGIN:VEVENT ... END:VEVENT` blocks.
    static func parseCalDAVEICSData(data: Data, fallbackDate: Date) -> [DesktopPluginEventItem] {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("BEGIN:VEVENT") else {
            return []
        }
        let blocks = text.components(separatedBy: "BEGIN:VEVENT").dropFirst()
        var events: [DesktopPluginEventItem] = []

        for rawBlock in blocks {
            guard let endRange = rawBlock.range(of: "END:VEVENT") else { continue }
            let block = String(rawBlock[..<endRange.lowerBound])
                .replacingOccurrences(of: "\r\n ", with: "")
                .replacingOccurrences(of: "\n ", with: "")
            let lines = block.components(separatedBy: .newlines)

            var uid = ""
            var summary = ""
            var dtStart = ""
            var dtEnd = ""
            var location = "飞书日历 (CalDAV)"
            var notes = ""

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let propPart = String(trimmed[..<colon]).uppercased()
                let valuePart = String(trimmed[trimmed.index(after: colon)...])
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\,", with: ",")
                let key = propPart.split(separator: ";").first.map(String.init) ?? propPart
                switch key {
                case "UID": uid = valuePart
                case "SUMMARY": summary = valuePart
                case "DTSTART": dtStart = parseICSTimestamp(valuePart, fallbackDate: fallbackDate)
                case "DTEND": dtEnd = parseICSTimestamp(valuePart, fallbackDate: fallbackDate)
                case "LOCATION": if !valuePart.isEmpty { location = valuePart }
                case "DESCRIPTION": notes = valuePart
                default: break
                }
            }
            guard !summary.isEmpty else { continue }
            let finalID = uid.isEmpty ? "caldav_" + UUID().uuidString.prefix(8).lowercased() : uid
            let startStr = dtStart.isEmpty ? "\(dateFormatter.string(from: fallbackDate)) 09:00" : dtStart
            let endStr = dtEnd.isEmpty ? "\(dateFormatter.string(from: fallbackDate)) 10:00" : dtEnd
            events.append(DesktopPluginEventItem(
                id: finalID,
                summary: summary,
                startTime: startStr,
                endTime: endStr,
                location: location,
                attendees: [],
                notes: notes,
                source: "feishu"
            ))
        }
        return events
    }

    static func parseICSTimestamp(_ raw: String, fallbackDate: Date) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = Array(clean.filter(\.isNumber))
        guard digits.count >= 8 else {
            return "\(dateFormatter.string(from: fallbackDate)) 09:00"
        }
        let yyyy = String(digits[0..<4])
        let mm = String(digits[4..<6])
        let dd = String(digits[6..<8])
        if digits.count >= 12 {
            let hh = String(digits[8..<10])
            let min = String(digits[10..<12])
            if clean.hasSuffix("Z") {
                var comps = DateComponents()
                comps.calendar = Calendar(identifier: .gregorian)
                comps.timeZone = TimeZone(secondsFromGMT: 0)
                comps.year = Int(yyyy)
                comps.month = Int(mm)
                comps.day = Int(dd)
                comps.hour = Int(hh)
                comps.minute = Int(min)
                if let utcDate = comps.date {
                    return dateTimeFormatter.string(from: utcDate)
                }
            }
            return "\(yyyy)-\(mm)-\(dd) \(hh):\(min)"
        }
        return "\(yyyy)-\(mm)-\(dd) 09:00"
    }

    static func parseFeishuEventsResponse(data: Data, fallbackDate: Date) -> [DesktopPluginEventItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let items = dataObj["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item -> DesktopPluginEventItem? in
            let id = (item["event_id"] as? String) ?? UUID().uuidString
            let summary = (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "飞书日程"
            guard !summary.isEmpty else { return nil }
            let description = (item["description"] as? String) ?? ""
            let startTS = ((item["start_time"] as? [String: Any])?["timestamp"] as? String).flatMap(Double.init)
            let endTS = ((item["end_time"] as? [String: Any])?["timestamp"] as? String).flatMap(Double.init)
            let startStr = startTS.map { dateTimeFormatter.string(from: Date(timeIntervalSince1970: $0)) }
                ?? "\(dateFormatter.string(from: fallbackDate)) 09:00"
            let endStr = endTS.map { dateTimeFormatter.string(from: Date(timeIntervalSince1970: $0)) }
                ?? "\(dateFormatter.string(from: fallbackDate)) 10:00"
            let location = ((item["location"] as? [String: Any])?["name"] as? String) ?? "飞书日历"
            return DesktopPluginEventItem(
                id: id,
                summary: summary,
                startTime: startStr,
                endTime: endStr,
                location: location,
                attendees: [],
                notes: description,
                source: "feishu"
            )
        }
    }

    /// Computes Feishu custom bot webhook HMAC-SHA256 signature (`timestamp + "\n" + secret` as key, empty msg).
    static func computeFeishuWebhookSign(timestamp: String, secret: String) -> String {
        let stringToSign = "\(timestamp)\n\(secret)"
        let key = SymmetricKey(data: Data(stringToSign.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(), using: key)
        return Data(mac).base64EncodedString()
    }

    static func inferFeishuReceiveIDType(_ receiveID: String) -> String {
        if receiveID.hasPrefix("oc_") { return "chat_id" }
        if receiveID.hasPrefix("ou_") { return "open_id" }
        if receiveID.hasPrefix("on_") { return "union_id" }
        if receiveID.contains("@") { return "email" }
        return "chat_id"
    }

    static func buildFeishuInteractiveCard(title: String, markdown: String) -> [String: Any] {
        [
            "config": ["wide_screen_mode": true],
            "header": [
                "template": "wathet",
                "title": ["tag": "plain_text", "content": title]
            ],
            "elements": [
                [
                    "tag": "markdown",
                    "content": markdown
                ]
            ]
        ]
    }

    static func parseFeishuChatMessages(data: Data) -> [[String: String]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let items = dataObj["items"] as? [[String: Any]] else {
            return []
        }
        let timeOnlyFormatter = DateFormatter()
        timeOnlyFormatter.calendar = Calendar(identifier: .gregorian)
        timeOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeOnlyFormatter.dateFormat = "HH:mm"

        return items.compactMap { item -> [String: String]? in
            let sender = ((item["sender"] as? [String: Any])?["id"] as? String) ?? "飞书成员"
            let createTimeMs = (item["create_time"] as? String).flatMap(Double.init)
            let timeStr = createTimeMs.map { timeOnlyFormatter.string(from: Date(timeIntervalSince1970: $0 / 1000.0)) } ?? "近期"
            let rawContent = ((item["body"] as? [String: Any])?["content"] as? String) ?? ""
            var text = rawContent
            if let contentData = rawContent.data(using: .utf8),
               let contentObj = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
               let parsedText = contentObj["text"] as? String {
                text = parsedText
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["sender": sender, "time": timeStr, "text": text]
        }
    }

    static func extractFeishuDocumentID(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), url.host != nil {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let idx = parts.firstIndex(where: { $0 == "docx" || $0 == "docs" || $0 == "wiki" }),
               idx + 1 < parts.count {
                return parts[idx + 1]
            }
            return parts.last ?? ""
        }
        return trimmed
    }

    static func defaultSeededEvents(now: Date) -> [DesktopPluginEventItem] {
        let today = dateFormatter.string(from: now)
        let tomorrow = dateFormatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400))
        return [
            DesktopPluginEventItem(
                id: "evt_feishu_01",
                summary: "产品周会 & 重点排期对齐",
                startTime: "\(today) 10:00",
                endTime: "\(today) 10:45",
                location: "飞书视频会议",
                attendees: ["林夏", "周航"],
                notes: "同步本周研发进度、确认核心功能验收标准。",
                source: "feishu"
            ),
            DesktopPluginEventItem(
                id: "evt_feishu_02",
                summary: "Amber 插件系统与 UI 评审",
                startTime: "\(today) 14:30",
                endTime: "\(today) 15:30",
                location: "3 号会议室",
                attendees: ["陈默", "苏晴"],
                notes: "评审 Obsidian 风格侧栏、右侧今日日程卡片与飞书工具闭环。",
                source: "feishu"
            ),
            DesktopPluginEventItem(
                id: "evt_feishu_03",
                summary: "桌面端体验走查与细节打磨",
                startTime: "\(tomorrow) 11:00",
                endTime: "\(tomorrow) 12:00",
                location: "飞书线上会议",
                attendees: ["设计组"],
                notes: "检查亮暗色对比度、边距对齐与命令面板快捷键。",
                source: "feishu"
            )
        ]
    }

    static func defaultSeededBotActivities(now: Date) -> [DesktopPluginBotActivityItem] {
        let today = dateFormatter.string(from: now)
        return [
            DesktopPluginBotActivityItem(
                id: "bot_seed_01",
                kind: "card",
                title: "今日飞书会议提醒卡片",
                summary: "已汇总今日 2 场重点会议（10:00 产品周会、14:30 插件系统与 UI 评审）并生成群通知卡片。",
                channel: "webhook",
                target: "产品研发核心群",
                timestamp: "\(today) 09:15",
                documentURL: nil
            ),
            DesktopPluginBotActivityItem(
                id: "bot_seed_02",
                kind: "doc_read",
                title: "Amber 飞书套件架构设计文档",
                summary: "日历模块采用 CalDAV 免审批直连同步个人日程；机器人模块支持群 Webhook 卡片推送、群聊历史纪要提取与飞书云文档读写。",
                channel: "openapi",
                target: "doxcn_amber_feishu_v2",
                timestamp: "\(today) 09:20",
                documentURL: "https://feishu.cn/docx/doxcn_amber_feishu_v2"
            )
        ]
    }

    static func makeBuiltInFeishuPlugin(enabled: Bool) -> DesktopInstalledPlugin {
        let manifest = DesktopPluginManifest(
            schema: DesktopPluginManifest.schemaV2,
            id: "feishu_calendar",
            name: "飞书",
            version: "2.0.0",
            description: "分为「飞书日历（CalDAV）」与「飞书机器人（Webhook / OpenAPI）」两大模块：支持个人 CalDAV 免审批同步日程，以及通过飞书机器人推送消息卡片、拉取群聊纪要、读写飞书云文档。",
            icon: "paperplane.circle",
            capabilities: DesktopPluginCapabilities(
                networkDomains: ["caldav.feishu.cn", "caldav.larksuite.com", "open.feishu.cn", "open.larksuite.com"],
                workspaceReadPrefixes: [],
                workspaceWritePrefixes: []
            ),
            settingsSchema: [
                // Group 1: Calendar (CalDAV)
                DesktopPluginSettingField(
                    key: "caldav_server",
                    title: "CalDAV 服务器地址",
                    kind: .string,
                    placeholder: "https://caldav.feishu.cn",
                    defaultValue: "https://caldav.feishu.cn",
                    help: "飞书客户端 → 设置 → 日历 → CalDAV 同步中的服务器地址。",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "caldav_username",
                    title: "CalDAV 用户名",
                    kind: .string,
                    placeholder: "u_xxxxxx",
                    defaultValue: "",
                    help: "在飞书设置中一键生成的个人 CalDAV 用户名，无需企业管理员审批。",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "caldav_password",
                    title: "CalDAV 密码",
                    kind: .secret,
                    placeholder: "安全保存在系统钥匙串中",
                    defaultValue: "",
                    help: "飞书 CalDAV 专用密码，用于同步与新建个人飞书日程。",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "workday_start_hour",
                    title: "工作时段开始（小时）",
                    kind: .integer,
                    placeholder: "9",
                    defaultValue: "9",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "workday_end_hour",
                    title: "工作时段结束（小时）",
                    kind: .integer,
                    placeholder: "18",
                    defaultValue: "18",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "default_calendar_id",
                    title: "备选日历 ID (OpenAPI)",
                    kind: .string,
                    placeholder: "primary",
                    defaultValue: "primary",
                    help: "未配置 CalDAV 时，若已配置机器人 App ID/Secret，可作为备选同步该日历 ID。",
                    group: "calendar"
                ),
                // Group 2: Feishu Bot (Webhook & OpenAPI)
                DesktopPluginSettingField(
                    key: "bot_webhook_url",
                    title: "群自定义机器人 Webhook",
                    kind: .string,
                    placeholder: "https://open.feishu.cn/open-apis/bot/v2/hook/...",
                    defaultValue: "",
                    help: "飞书群设置 → 群机器人 → 添加自定义机器人获取的 Webhook 地址，可一键向群内发通知卡片。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "bot_webhook_secret",
                    title: "Webhook 签名密钥 (可选)",
                    kind: .secret,
                    placeholder: "安全保存在系统钥匙串中",
                    defaultValue: "",
                    help: "若群自定义机器人启用了签名校验，填入密钥后将自动附带 HMAC-SHA256 签名。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "app_id",
                    title: "飞书应用机器人 App ID",
                    kind: .string,
                    placeholder: "cli_a1b2c3d4e5f6...",
                    defaultValue: "",
                    help: "飞书开放平台自建应用机器人的 App ID，支持收发消息、拉取群聊历史与读写云文档。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "app_secret",
                    title: "飞书应用机器人 App Secret",
                    kind: .secret,
                    placeholder: "安全保存在系统钥匙串中",
                    defaultValue: "",
                    help: "自建应用机器人的 App Secret，用于自动换取 tenant_access_token。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "default_receive_id",
                    title: "默认群聊 / 接收人 ID",
                    kind: .string,
                    placeholder: "oc_xxx (群 chat_id) 或 ou_xxx (open_id)",
                    defaultValue: "",
                    help: "应用机器人默认发送消息或拉取聊天记录的目标会话 ID。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "personal_access_token",
                    title: "个人访问令牌 (可选)",
                    kind: .secret,
                    placeholder: "u-...",
                    defaultValue: "",
                    help: "可选的 User Access Token，填入后可优先以个人授权调用飞书 OpenAPI。",
                    group: "bot"
                )
            ],
            tools: [
                DesktopPluginToolManifest(
                    name: "list_events",
                    description: "查询飞书日历中的日程列表（可按日期 yyyy-MM-dd 或关键词筛选）。",
                    effect: .networkRead,
                    entry: "listEvents",
                    parametersJSON: #"{"type":"object","properties":{"date":{"type":"string","description":"可选日期 yyyy-MM-dd，不填则返回全部近期日程"},"query":{"type":"string","description":"可选关键词过滤"}},"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "freebusy",
                    description: "查询指定日期（yyyy-MM-dd）的忙闲状态与可约会议的空闲时间段建议。",
                    effect: .networkRead,
                    entry: "freebusy",
                    parametersJSON: #"{"type":"object","properties":{"date":{"type":"string","description":"日期 yyyy-MM-dd"},"duration_minutes":{"type":"integer","description":"期望会议时长（分钟），默认 45"}},"required":["date"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "create_event",
                    description: "在飞书日历创建新的日程或会议邀约（通过 CalDAV 或开放平台同步，需要用户批准）。",
                    effect: .sideEffect,
                    entry: "createEvent",
                    parametersJSON: """
                    {"type":"object","properties":{\
                    "summary":{"type":"string","description":"会议或日程标题"},\
                    "start_time":{"type":"string","description":"开始时间 yyyy-MM-dd HH:mm"},\
                    "end_time":{"type":"string","description":"结束时间 yyyy-MM-dd HH:mm"},\
                    "location":{"type":"string","description":"会议地点或飞书会议链接"},\
                    "attendees":{"type":"array","items":{"type":"string"},"description":"参会人姓名列表"},\
                    "notes":{"type":"string","description":"会议议程或备注"},\
                    "idempotency_key":{"type":"string","description":"可选幂等键；同一键重复调用不会重复创建"}},\
                    "required":["summary","start_time","end_time"],"additionalProperties":false}
                    """
                ),
                DesktopPluginToolManifest(
                    name: "bot_send_message",
                    description: "通过飞书机器人（群 Webhook 或应用机器人）发送文本通知或富文本交互卡片到飞书群/个人。",
                    effect: .sideEffect,
                    entry: "botSendMessage",
                    parametersJSON: """
                    {"type":"object","properties":{\
                    "title":{"type":"string","description":"消息卡片标题"},\
                    "content":{"type":"string","description":"消息正文（支持 Markdown）"},\
                    "msg_type":{"type":"string","enum":["interactive","text"],"description":"默认 interactive"},\
                    "receive_id":{"type":"string","description":"chat_id (oc_xxx) 或 open_id (ou_xxx)，不填走 Webhook 或默认接收 ID"},\
                    "idempotency_key":{"type":"string","description":"可选幂等键；同一键重复调用不会重复发送"}},\
                    "required":["content"],"additionalProperties":false}
                    """
                ),
                DesktopPluginToolManifest(
                    name: "bot_fetch_chat_history",
                    description: "通过飞书机器人拉取指定飞书群聊（chat_id）的近期聊天记录，用于总结纪要或提取待办。",
                    effect: .networkRead,
                    entry: "botFetchChatHistory",
                    parametersJSON: #"{"type":"object","properties":{"chat_id":{"type":"string","description":"飞书群聊 chat_id (oc_xxx)，不填则使用默认群聊 ID"},"limit":{"type":"integer","description":"拉取条数，默认 15"}},"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "bot_read_doc",
                    description: "通过飞书机器人读取飞书云文档（Docx）的正文内容，支持传入飞书文档链接或 document_id。",
                    effect: .networkRead,
                    entry: "botReadDoc",
                    parametersJSON: #"{"type":"object","properties":{"document":{"type":"string","description":"飞书云文档链接（https://.../docx/...）或 document_id"}},"required":["document"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "bot_create_doc",
                    description: "通过飞书机器人在飞书云端创建一篇新的云文档（Docx），返回文档链接。",
                    effect: .sideEffect,
                    entry: "botCreateDoc",
                    parametersJSON: #"{"type":"object","properties":{"title":{"type":"string","description":"云文档标题"},"content":{"type":"string","description":"文档内容摘要或正文"},"folder_token":{"type":"string","description":"可选目标文件夹 Token"},"idempotency_key":{"type":"string","description":"可选幂等键；同一键重复调用不会重复创建"}},"required":["title"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "meeting_closeout",
                    description: "会后收口：把纪要建成飞书云文档再发群回执；同一个幂等键重复执行不会重复发。",
                    effect: .sideEffect,
                    entry: "meetingCloseout",
                    parametersJSON: """
                    {"type":"object","properties":{\
                    "title":{"type":"string","description":"会议标题，也用作云文档标题"},\
                    "minutes":{"type":"string","description":"已确认的纪要正文"},\
                    "receive_id":{"type":"string","description":"可选群 chat_id；默认用设置里的接收 ID"},\
                    "receipt":{"type":"string","description":"可选回执正文；默认是纪要已归档与链接"},\
                    "send_receipt":{"type":"boolean","description":"false 时只建文档不发回执"},\
                    "idempotency_key":{"type":"string","description":"可选幂等键；默认按日期与标题生成"}},\
                    "required":["title","minutes"],"additionalProperties":false}
                    """
                )
            ],
            ui: DesktopPluginUIManifest(
                inspectorCards: [
                    DesktopPluginInspectorCardManifest(
                        id: "today_agenda",
                        title: "今日飞书日程",
                        symbol: "calendar.badge.clock",
                        entry: "renderTodayInspector"
                    )
                ],
                workspaceViews: [
                    DesktopPluginWorkspaceViewManifest(
                        id: "calendar_board",
                        title: "飞书日历",
                        symbol: "calendar",
                        subtitle: "通过 CalDAV 直连同步个人飞书日历，查看排期忙闲或将会议一键推送至飞书群。"
                    ),
                    DesktopPluginWorkspaceViewManifest(
                        id: "bot_studio",
                        title: "飞书机器人",
                        symbol: "paperplane.circle",
                        subtitle: "通过飞书群 Webhook 或自建应用机器人发送消息卡片、拉取群聊纪要、读写飞书云文档。"
                    )
                ],
                commands: [
                    DesktopPluginCommandManifest(
                        id: "feishu_today",
                        title: "梳理今日飞书日程与会前准备",
                        slash: "/feishu-today",
                        symbol: "calendar",
                        promptTemplate: "请调用飞书日历工具读取我今天的日程安排，按时间顺序梳理每场会议需要准备的重点与待办事项。"
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_freebusy",
                        title: "查询今日空闲时段",
                        slash: "/feishu-freebusy",
                        symbol: "clock.badge.checkmark",
                        promptTemplate: "请调用飞书日历工具查询我今天和明天的空闲时段，推荐适合安排 45 分钟评审会的时间窗口。"
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_meet",
                        title: "在飞书日历预约会议",
                        slash: "/feishu-meet",
                        symbol: "calendar.badge.plus",
                        promptTemplate: "请帮我在飞书日历安排一场会议，先检查冲突再创建日程："
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_notify",
                        title: "通过飞书机器人发送群通知卡片",
                        slash: "/feishu-notify",
                        symbol: "paperplane",
                        promptTemplate: "请将当前对话的核心结论整理成结构化要点，并调用飞书机器人工具（bot_send_message）发送一张飞书消息卡片到群里。"
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_chat",
                        title: "拉取飞书群聊记录并生成纪要",
                        slash: "/feishu-chat",
                        symbol: "bubble.left.and.bubble.right",
                        promptTemplate: "请调用飞书机器人工具（bot_fetch_chat_history）拉取近期群聊记录，帮我提炼讨论结论、争议点与待办事项。"
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_doc",
                        title: "读取或创建飞书云文档",
                        slash: "/feishu-doc",
                        symbol: "doc.text",
                        promptTemplate: "请调用飞书机器人云文档工具帮我读取或创建飞书文档："
                    )
                ]
            )
        )

        let script = """
        function _loadEvents() {
            const raw = amber.storage.get("events");
            if (!raw) return [];
            try { return JSON.parse(raw); } catch (e) { return []; }
        }

        function listEvents(input) {
            const events = _loadEvents();
            const targetDate = (input && input.date) ? String(input.date).trim() : "";
            const query = (input && input.query) ? String(input.query).trim().toLowerCase() : "";
            const filtered = events.filter(function(ev) {
                if (targetDate && String(ev.startTime || "").indexOf(targetDate) !== 0) return false;
                if (query) {
                    const haystack = [ev.summary, ev.location, ev.notes, (ev.attendees || []).join(" ")].join(" ").toLowerCase();
                    if (haystack.indexOf(query) === -1) return false;
                }
                return true;
            });
            return {
                ok: true,
                plugin: "feishu_calendar",
                mode: amber.settings.get("mode") || "local",
                calendar_id: amber.settings.get("default_calendar_id") || "primary",
                date: targetDate || "all",
                count: filtered.length,
                events: filtered
            };
        }

        function freebusy(input) {
            const date = (input && input.date) ? String(input.date).trim() : amber.settings.get("today");
            const duration = (input && input.duration_minutes) ? Number(input.duration_minutes) : 45;
            const startHour = Number(amber.settings.get("workday_start_hour") || "9");
            const endHour = Number(amber.settings.get("workday_end_hour") || "18");
            const dayEvents = _loadEvents().filter(function(ev) {
                return String(ev.startTime || "").indexOf(date) === 0;
            });

            function toMinutes(timeStr) {
                const part = String(timeStr).slice(11, 16);
                const pieces = part.split(":");
                if (pieces.length !== 2) return 0;
                return Number(pieces[0]) * 60 + Number(pieces[1]);
            }
            function toHHMM(mins) {
                const h = String(Math.floor(mins / 60)).padStart(2, "0");
                const m = String(mins % 60).padStart(2, "0");
                return h + ":" + m;
            }

            const busy = dayEvents.map(function(ev) {
                return { start: toMinutes(ev.startTime), end: toMinutes(ev.endTime), summary: ev.summary };
            }).sort(function(a, b) { return a.start - b.start; });

            const freeSlots = [];
            let cursor = startHour * 60;
            const dayEnd = endHour * 60;
            for (let i = 0; i < busy.length; i++) {
                if (busy[i].start - cursor >= duration) {
                    freeSlots.push({
                        start_time: date + " " + toHHMM(cursor),
                        end_time: date + " " + toHHMM(busy[i].start),
                        available_minutes: busy[i].start - cursor
                    });
                }
                if (busy[i].end > cursor) cursor = busy[i].end;
            }
            if (dayEnd - cursor >= duration) {
                freeSlots.push({
                    start_time: date + " " + toHHMM(cursor),
                    end_time: date + " " + toHHMM(dayEnd),
                    available_minutes: dayEnd - cursor
                });
            }

            return {
                ok: true,
                plugin: "feishu_calendar",
                date: date,
                busy_count: busy.length,
                busy_events: dayEvents.map(function(e) { return { summary: e.summary, start_time: e.startTime, end_time: e.endTime }; }),
                free_slots: freeSlots
            };
        }

        function createEvent(input) {
            const events = _loadEvents();
            const created = {
                id: "evt_" + Math.random().toString(36).slice(2, 10),
                summary: String(input.summary || "新日程"),
                startTime: String(input.start_time || ""),
                endTime: String(input.end_time || ""),
                location: String(input.location || "飞书会议"),
                attendees: Array.isArray(input.attendees) ? input.attendees : [],
                notes: String(input.notes || ""),
                source: amber.settings.get("mode") || "local"
            };
            events.push(created);
            amber.storage.set("events", events);
            return { ok: true, plugin: "feishu_calendar", event: created, total_events: events.length };
        }
        """

        return DesktopInstalledPlugin(
            manifest: manifest,
            scriptSource: script,
            enabled: enabled,
            isBuiltIn: true,
            lastSyncStatus: nil
        )
    }

    nonisolated static func encodeJSONObject(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
