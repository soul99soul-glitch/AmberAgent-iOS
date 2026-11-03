import Foundation

// MARK: - Cloud Native Task Contract (/v2/agents & /v2/work-items)

struct MacGatewayCloudAgent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var memoryPolicy: String?
    var tags: [String]?
    var revision: Int?

    static let defaultMain = MacGatewayCloudAgent(id: "main", name: "Amber")

    var displayLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id }
        return trimmed == id ? id : "\(trimmed) (\(id))"
    }
}

enum MacGatewayCloudWorkState: String, Codable, Equatable, CaseIterable, Sendable {
    case queued = "QUEUED"
    case starting = "STARTING"
    case working = "WORKING"
    case waiting = "WAITING"
    case idle = "IDLE"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .queued, .starting, .working, .waiting, .idle:
            false
        }
    }

    var displayTitle: String {
        switch self {
        case .queued:
            IOSAppLocalization.string("排队中", defaultValue: "排队中")
        case .starting:
            IOSAppLocalization.string("启动中", defaultValue: "启动中")
        case .working:
            IOSAppLocalization.string("执行中", defaultValue: "执行中")
        case .waiting:
            IOSAppLocalization.string("等待中", defaultValue: "等待中")
        case .idle:
            IOSAppLocalization.string("空闲", defaultValue: "空闲")
        case .completed:
            IOSAppLocalization.string("已完成", defaultValue: "已完成")
        case .failed:
            IOSAppLocalization.string("执行失败", defaultValue: "执行失败")
        case .cancelled:
            IOSAppLocalization.string("已取消", defaultValue: "已取消")
        }
    }

    var iconName: String {
        switch self {
        case .queued, .starting, .waiting, .idle:
            "clock"
        case .working:
            "bolt.horizontal.circle"
        case .completed:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .cancelled:
            "xmark.circle"
        }
    }
}

struct MacGatewayCloudWorkItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var agentId: String
    var title: String
    var state: MacGatewayCloudWorkState
    var progress: String?
    var updatedAtMs: Int64

    var updatedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1_000.0)
    }
}

/// Request body for `POST /v2/work-items`. Unknown JSON fields are rejected with HTTP 400 by the cloud daemon,
/// so only the four contract fields (`requestId`, `text`, `agentId`, `title`) are encoded.
struct MacGatewayCloudTaskRequest: Codable, Equatable, Sendable {
    var requestId: String
    var text: String
    var agentId: String
    var title: String

    init(
        requestId: String = UUID().uuidString.lowercased(),
        text: String,
        agentId: String = "main",
        title: String = "云端任务"
    ) {
        self.requestId = requestId
        self.text = text
        self.agentId = agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : agentId
        self.title = Self.normalizedTitle(title, fallbackFromText: text)
    }

    static func normalizedTitle(_ rawTitle: String, fallbackFromText text: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.utf16.prefix(200)) ?? "云端任务"
        }
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if !firstLine.isEmpty {
            return String(firstLine.utf16.prefix(48)) ?? "云端任务"
        }
        return "云端任务"
    }

    var validationError: String? {
        guard Self.isValidRequestId(requestId) else {
            return IOSAppLocalization.string("请求 ID 格式无效", defaultValue: "请求 ID 格式无效")
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return IOSAppLocalization.string("请输入要交给云端执行的任务内容", defaultValue: "请输入要交给云端执行的任务内容")
        }
        guard text.utf16.count <= 24_000 else {
            return IOSAppLocalization.string("任务内容不能超过 24000 个字符", defaultValue: "任务内容不能超过 24000 个字符")
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, title.utf16.count <= 200 else {
            return IOSAppLocalization.string("任务标题需在 1 到 200 个字符之间", defaultValue: "任务标题需在 1 到 200 个字符之间")
        }
        return nil
    }

    static func isValidRequestId(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf16.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x5F, 0x3A, 0x2D:
                true
            default:
                false
            }
        }
    }
}

struct MacGatewayCloudTaskReceipt: Codable, Equatable, Sendable {
    var workItem: MacGatewayCloudWorkItem
    var replayed: Bool
}

struct MacGatewayCloudWorkDetail: Codable, Equatable, Sendable {
    var workItem: MacGatewayCloudWorkItem
    var brief: String
    var failure: String?
    var sessionArchived: Bool
    var resultMarkdown: String?
}

enum MacGatewayCloudActivityPhase: String, Codable, Equatable, Sendable {
    case started = "STARTED"
    case progress = "PROGRESS"
    case done = "DONE"
    case failed = "FAILED"

    var isTerminal: Bool {
        switch self {
        case .done, .failed:
            true
        case .started, .progress:
            false
        }
    }
}

/// Sanitized outward activity entry returned by `GET /v2/agents/{id}/activity`.
struct MacGatewayCloudActivityStatus: Codable, Equatable, Identifiable, Sendable {
    var id: String { taskId }
    var taskId: String
    var label: String
    var phase: MacGatewayCloudActivityPhase
    var updatedAtMs: Int64

    var updatedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1_000.0)
    }
}

/// Snapshot returned by `GET /v2/agents/{id}/activity` (up to 100 active-first items).
struct MacGatewayCloudAgentActivity: Codable, Equatable, Sendable {
    var agentId: String
    var activities: [MacGatewayCloudActivityStatus]
    var workItems: [MacGatewayCloudWorkItem]
}

/// Read-only main timeline entry returned by `GET /v2/timeline`.
struct MacGatewayCloudTimelineEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: String
    var agentId: String?
    var text: String
}

struct MacGatewayCloudTimelinePage: Codable, Equatable, Sendable {
    var items: [MacGatewayCloudTimelineEntry]
    var nextCursor: String?
}

/// Persisted per paired `deviceId` so `requestId` and the exact request payload survive timeouts and restarts,
/// and `workItemId` resumes polling after relaunch.
struct MacGatewayCloudTaskRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { request.requestId }
    var requestId: String { request.requestId }
    var gatewayId: String
    var deviceId: String
    var request: MacGatewayCloudTaskRequest
    var workItemId: String?
    var workItem: MacGatewayCloudWorkItem?
    var detail: MacGatewayCloudWorkDetail?
    var replayed: Bool = false
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    var effectiveWorkItem: MacGatewayCloudWorkItem? {
        detail?.workItem ?? workItem
    }

    var state: MacGatewayCloudWorkState? {
        effectiveWorkItem?.state
    }

    var displayTitle: String {
        effectiveWorkItem?.title ?? request.title
    }

    var agentId: String {
        effectiveWorkItem?.agentId ?? request.agentId
    }

    var briefText: String {
        detail?.brief ?? request.text
    }

    var isTerminal: Bool {
        state?.isTerminal == true
    }

    var canCancel: Bool {
        guard let state, workItemId != nil else { return false }
        return !state.isTerminal
    }

    var needsSubmissionRetry: Bool {
        workItemId == nil
    }

    var summaryLine: String {
        if let lastError, !lastError.isEmpty, workItemId == nil {
            return IOSAppLocalization.string("提交未完成", defaultValue: "提交未完成") + " · " + lastError
        }
        let statusPart = state?.displayTitle ?? IOSAppLocalization.string("正在提交…", defaultValue: "正在提交…")
        if let failure = detail?.failure, !failure.isEmpty {
            return "\(statusPart) · \(failure)"
        }
        if let progress = effectiveWorkItem?.progress, !progress.isEmpty, !isTerminal {
            return "\(statusPart) · \(progress)"
        }
        if let result = detail?.resultMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            let preview = result
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("# Settlement Report") } ?? result
            return "\(statusPart) · \(preview)"
        }
        return statusPart
    }
}

// MARK: - Client Endpoints

extension MacGatewayClient {
    private static let workItemPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]")
        return allowed
    }()

    private static func encodeWorkItemId(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: workItemPathAllowed) ?? id
    }

    func agents() async throws -> [MacGatewayCloudAgent] {
        struct Response: Decodable { var agents: [MacGatewayCloudAgent] }
        let response: Response = try decode(await send("GET", "/v2/agents"))
        return response.agents
    }

    func submitTask(_ request: MacGatewayCloudTaskRequest) async throws -> MacGatewayCloudTaskReceipt {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = try encoder.encode(request)
        guard let jsonString = String(data: bodyData, encoding: .utf8),
              jsonString.utf16.count <= 100_000 else {
            throw MacGatewayError.server(
                IOSAppLocalization.string("任务请求体超过 100000 字符上限", defaultValue: "任务请求体超过 100000 字符上限")
            )
        }
        return try decode(await sendData("POST", "/v2/work-items", bodyData: bodyData, slow: true))
    }

    func workItem(id: String) async throws -> MacGatewayCloudWorkDetail {
        let encoded = Self.encodeWorkItemId(id)
        return try decode(await send("GET", "/v2/work-items/\(encoded)"))
    }

    func cancelTask(id: String) async throws -> MacGatewayCloudWorkDetail {
        let encoded = Self.encodeWorkItemId(id)
        return try decode(await send("POST", "/v2/work-items/\(encoded)/cancel", slow: true))
    }

    func agentActivity(agentId: String) async throws -> MacGatewayCloudAgentActivity {
        let encoded = Self.encodeWorkItemId(agentId)
        return try decode(await send("GET", "/v2/agents/\(encoded)/activity"))
    }

    func timeline(limit: Int = 50, before: String? = nil) async throws -> MacGatewayCloudTimelinePage {
        let clampedLimit = min(max(limit, 1), 100)
        var path = "/v2/timeline?limit=\(clampedLimit)"
        if let before, !before.isEmpty,
           let encodedCursor = before.addingPercentEncoding(withAllowedCharacters: Self.workItemPathAllowed) {
            path += "&before=\(encodedCursor)"
        }
        return try decode(await send("GET", path))
    }
}

// MARK: - Store Operations & Persistence

extension MacGatewayStore {
    static let cloudTasksKey = "macGateway.cloudTasks.v1"

    var effectiveCloudAgents: [MacGatewayCloudAgent] {
        if cloudAgents.isEmpty {
            return [.defaultMain]
        }
        if cloudAgents.contains(where: { $0.id == "main" }) {
            return cloudAgents
        }
        return [.defaultMain] + cloudAgents
    }

    func agentDisplayName(for agentId: String) -> String {
        if let match = effectiveCloudAgents.first(where: { $0.id == agentId }) {
            let trimmed = match.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return agentId
    }

    var hasActiveCloudTasks: Bool {
        cloudTasks.contains { $0.workItemId != nil && !$0.isTerminal }
    }

    func loadPersistedCloudTasks() {
        guard let connection else {
            cloudTasks = []
            return
        }
        guard let data = defaults.data(forKey: Self.cloudTasksKey),
              let decoded = try? JSONDecoder().decode([MacGatewayCloudTaskRecord].self, from: data) else {
            cloudTasks = []
            return
        }
        // Re-pairing produces a new deviceId; old deviceId records cannot be deduplicated or reused.
        let filtered = decoded.filter {
            $0.deviceId == connection.deviceId && $0.gatewayId == connection.gatewayId
        }
        if filtered.count != decoded.count {
            persistCloudTasks(filtered)
        }
        cloudTasks = filtered
    }

    func persistCloudTasks(_ records: [MacGatewayCloudTaskRecord]? = nil) {
        let list = records ?? cloudTasks
        if list.isEmpty {
            defaults.removeObject(forKey: Self.cloudTasksKey)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.cloudTasksKey)
        }
    }

    func refreshCloudAgents() async {
        guard let client else { return }
        requestGeneration.cloudAgents += 1
        let generation = requestGeneration.cloudAgents
        do {
            let list = try await client.agents()
            guard self.client === client, generation == requestGeneration.cloudAgents else { return }
            if cloudAgents != list {
                cloudAgents = list
            }
            await refreshCloudAgentActivity(agentId: list.first?.id ?? "main")
        } catch is CancellationError {
        } catch {
            guard self.client === client, generation == requestGeneration.cloudAgents else { return }
            _ = forgetIfRevoked(error)
        }
    }

    func refreshCloudAgentActivity(agentId: String = "main") async {
        guard let client else { return }
        do {
            let snapshot = try await client.agentActivity(agentId: agentId)
            guard self.client === client else { return }
            if cloudAgentActivities[agentId] != snapshot {
                cloudAgentActivities[agentId] = snapshot
            }
        } catch is CancellationError {
        } catch {
            guard self.client === client else { return }
            _ = forgetIfRevoked(error)
        }
    }

    /// Persists `requestId` + full request BEFORE sending, then submits to `POST /v2/work-items` and saves `workItem.id`.
    @discardableResult
    func submitCloudTask(_ request: MacGatewayCloudTaskRequest) async -> Result<MacGatewayCloudTaskRecord, Error> {
        guard let connection, let client else {
            let error = MacGatewayError.server(localized("未与云端或 Mac 配对"))
            return .failure(error)
        }
        if let validationMessage = request.validationError {
            let error = MacGatewayError.server(validationMessage)
            return .failure(error)
        }
        let now = Date()
        let recordIndex = cloudTasks.firstIndex(where: { $0.requestId == request.requestId })
        var record: MacGatewayCloudTaskRecord
        if let recordIndex {
            record = cloudTasks[recordIndex]
            // Preserve the originally persisted request if already saved for this requestId.
            record.lastError = nil
            record.updatedAt = now
            cloudTasks[recordIndex] = record
        } else {
            record = MacGatewayCloudTaskRecord(
                gatewayId: connection.gatewayId,
                deviceId: connection.deviceId,
                request: request,
                workItemId: nil,
                workItem: nil,
                detail: nil,
                replayed: false,
                lastError: nil,
                createdAt: now,
                updatedAt: now
            )
            cloudTasks.insert(record, at: 0)
        }
        persistCloudTasks()

        busyCloudTaskIds.insert(record.requestId)
        defer { busyCloudTaskIds.remove(record.requestId) }

        do {
            let receipt = try await client.submitTask(record.request)
            guard self.client === client else {
                return .failure(CancellationError())
            }
            if let index = cloudTasks.firstIndex(where: { $0.requestId == record.requestId }) {
                cloudTasks[index].workItemId = receipt.workItem.id
                cloudTasks[index].workItem = receipt.workItem
                cloudTasks[index].replayed = receipt.replayed
                cloudTasks[index].lastError = nil
                cloudTasks[index].updatedAt = receipt.workItem.updatedAtDate
                record = cloudTasks[index]
                persistCloudTasks()
            }
            await refreshCloudTask(workItemId: receipt.workItem.id)
            if let updated = cloudTasks.first(where: { $0.requestId == record.requestId }) {
                record = updated
            }
            startCloudTaskPollingIfNeeded()
            return .success(record)
        } catch {
            if forgetIfRevoked(error) {
                return .failure(MacGatewayError.unauthorized)
            }
            if let index = cloudTasks.firstIndex(where: { $0.requestId == record.requestId }) {
                cloudTasks[index].lastError = error.localizedDescription
                cloudTasks[index].updatedAt = Date()
                persistCloudTasks()
            }
            return .failure(error)
        }
    }

    /// Re-sends a previously persisted request using its exact `requestId` and payload.
    @discardableResult
    func retryCloudTask(requestId: String) async -> Result<MacGatewayCloudTaskRecord, Error> {
        guard let record = cloudTasks.first(where: { $0.requestId == requestId }) else {
            return .failure(MacGatewayError.server(localized("找不到待重试的云端任务")))
        }
        if let workItemId = record.workItemId {
            await refreshCloudTask(workItemId: workItemId)
            if let updated = cloudTasks.first(where: { $0.requestId == requestId }) {
                return .success(updated)
            }
        }
        return await submitCloudTask(record.request)
    }

    func refreshCloudTask(workItemId: String) async {
        guard let client else { return }
        do {
            let detail = try await client.workItem(id: workItemId)
            guard self.client === client else { return }
            if let index = cloudTasks.firstIndex(where: { $0.workItemId == workItemId }) {
                let existing = cloudTasks[index]
                let updatedDate = detail.workItem.updatedAtDate
                guard existing.workItem != detail.workItem
                    || existing.detail != detail
                    || existing.lastError != nil
                    || existing.updatedAt != updatedDate else {
                    return
                }
                cloudTasks[index].workItem = detail.workItem
                cloudTasks[index].detail = detail
                cloudTasks[index].lastError = nil
                cloudTasks[index].updatedAt = updatedDate
                persistCloudTasks()
            }
        } catch is CancellationError {
        } catch {
            guard self.client === client else { return }
            if forgetIfRevoked(error) { return }
            if let index = cloudTasks.firstIndex(where: { $0.workItemId == workItemId }) {
                let errorMessage = error.localizedDescription
                guard cloudTasks[index].lastError != errorMessage else { return }
                cloudTasks[index].lastError = errorMessage
                persistCloudTasks()
            }
        }
    }

    func refreshActiveCloudTasks() async {
        let targets = cloudTasks.compactMap { record -> String? in
            guard let workItemId = record.workItemId else { return nil }
            if !record.isTerminal || record.detail == nil {
                return workItemId
            }
            return nil
        }
        for workItemId in targets {
            if Task.isCancelled { return }
            await refreshCloudTask(workItemId: workItemId)
        }
    }

    func cancelCloudTask(workItemId: String) async {
        guard let client else { return }
        let requestId = cloudTasks.first(where: { $0.workItemId == workItemId })?.requestId ?? workItemId
        guard busyCloudTaskIds.insert(requestId).inserted else { return }
        defer { busyCloudTaskIds.remove(requestId) }
        do {
            let detail = try await client.cancelTask(id: workItemId)
            guard self.client === client else { return }
            if let index = cloudTasks.firstIndex(where: { $0.workItemId == workItemId }) {
                cloudTasks[index].workItem = detail.workItem
                cloudTasks[index].detail = detail
                cloudTasks[index].lastError = nil
                cloudTasks[index].updatedAt = detail.workItem.updatedAtDate
                persistCloudTasks()
            }
        } catch is CancellationError {
        } catch {
            guard self.client === client else { return }
            if !forgetIfRevoked(error) {
                if let index = cloudTasks.firstIndex(where: { $0.workItemId == workItemId }) {
                    cloudTasks[index].lastError = error.localizedDescription
                    persistCloudTasks()
                }
                notice = Notice(text: error.localizedDescription, isError: true)
            }
        }
    }

    /// Polls `GET /v2/work-items/{id}` roughly once per second while any accepted cloud task is non-terminal.
    func startCloudTaskPollingIfNeeded() {
        guard cloudPollTask == nil, hasActiveCloudTasks, client != nil else { return }
        cloudPollTask = Task { @MainActor [weak self] in
            defer { self?.cloudPollTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.client != nil, self.hasActiveCloudTasks else { break }
                await self.refreshActiveCloudTasks()
                if !self.hasActiveCloudTasks { break }
            }
        }
    }

    func stopCloudTaskPolling() {
        cloudPollTask?.cancel()
        cloudPollTask = nil
    }
}
