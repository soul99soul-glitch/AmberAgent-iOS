import SwiftUI
import UIKit
import Foundation
@preconcurrency import Shared

/// Codable 快照,用于把上一轮议会的 transcript 存盘,退出后再进默认载回。颜色用 hex
/// 保留(席位/主持的色彩在重载后仍准确);backgroundColor/foregroundColor/borderColor 由
/// kind+status 派生,无需存。
struct CouncilPersistedMessage: Codable, Equatable {
    let id: String
    let kind: String
    let author: String
    let body: String
    let systemImage: String
    let tintHex: String
    let subtitle: String?
    let status: String

    init(
        id: String,
        kind: String,
        author: String,
        body: String,
        systemImage: String,
        tintHex: String,
        subtitle: String?,
        status: String
    ) {
        self.id = id
        self.kind = kind
        self.author = author
        self.body = body
        self.systemImage = systemImage
        self.tintHex = tintHex
        self.subtitle = subtitle
        self.status = status
    }

    init(_ message: CouncilChatMessage) {
        self.id = message.id.uuidString
        self.kind = message.kind.rawKey
        self.author = message.author
        self.body = message.body
        self.systemImage = message.systemImage
        self.tintHex = message.tint.councilHexString
        self.subtitle = message.subtitle
        self.status = message.status.rawKey
    }

    func restored() -> CouncilChatMessage {
        CouncilChatMessage(
            id: UUID(uuidString: id) ?? UUID(),
            kind: CouncilMessageKind(rawKey: kind),
            author: author,
            body: body,
            systemImage: systemImage,
            tint: Color(councilHexString: tintHex),
            subtitle: subtitle,
            status: CouncilMessageStatus(rawKey: status)
        )
    }
}

/// UserDefaults 持久化当前房间快照。旧版只保存消息数组，读取时原样迁移。
enum CouncilTranscriptStore {
    private static let key = "app.amber.ios.councilTranscript.v1"

    static func save(_ room: CouncilPersistedRoom, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(room) {
            defaults.set(data, forKey: key)
        }
    }

    static func load(defaults: UserDefaults) -> CouncilPersistedRoom? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        if let room = try? decoder.decode(CouncilPersistedRoom.self, from: data) {
            return room
        }
        guard let messages = try? decoder.decode([CouncilPersistedMessage].self, from: data) else {
            return nil
        }
        return CouncilPersistedRoom(
            taskId: "",
            objective: "",
            modeRaw: CouncilDiscussionMode.freeChat.rawValue,
            statusRaw: "",
            failedSpeakerIds: [],
            participants: [],
            messages: messages,
            updatedAtMs: 0
        )
    }

    static func clear(defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - 历史议会归档(按 taskId 一场一文件,支持「最近讨论」重开成只读对话)

/// 单个席位/主持在重开时还原所需的展示信息。颜色用 hex 保留;派生色由 kind 重新计算。
struct CouncilPersistedParticipant: Codable, Equatable {
    let id: String
    let handle: String
    let displayName: String
    let roleDescription: String
    let shortLens: String
    let systemImage: String
    let tintHex: String
    let isHost: Bool
    let modelHint: String
    let modelId: String?
    let providerId: String?

    init(_ participant: CouncilParticipant) {
        self.id = participant.id
        self.handle = participant.handle
        self.displayName = participant.displayName
        self.roleDescription = participant.roleDescription
        self.shortLens = participant.shortLens
        self.systemImage = participant.systemImage
        self.tintHex = participant.tint.councilHexString
        self.isHost = participant.isHost
        self.modelHint = participant.modelHint
        self.modelId = participant.modelId
        self.providerId = participant.providerId
    }

    func restored() -> CouncilParticipant {
        CouncilParticipant(
            id: id,
            handle: handle,
            displayName: displayName,
            roleDescription: roleDescription,
            shortLens: shortLens,
            systemImage: systemImage,
            tint: Color(councilHexString: tintHex),
            isHost: isHost,
            modelHint: modelHint,
            modelId: modelId,
            providerId: providerId
        )
    }
}

/// 一场议会的完整快照:消息流 + 席位名册 + 失败席位 + 议题/模式/状态。
/// 与单房间 `CouncilTranscriptStore`(只存当前 transcript)不同,这里按 taskId 归档每一场,
/// 用于从「最近讨论」重开任意历史议会,渲染成只读对话(深读式重开)。
struct CouncilPersistedRoom: Codable, Equatable {
    let taskId: String
    let objective: String
    var finalTopic: String? = nil
    let modeRaw: String
    let statusRaw: String
    let failedSpeakerIds: [String]
    let participants: [CouncilPersistedParticipant]
    let messages: [CouncilPersistedMessage]
    let updatedAtMs: Double
}

/// 文件持久化:每场议会一份 `Documents/council/<taskId>.json`。镜像 `IOSBoardPersistence`
/// 的「一 id 一文件」范式,避免把大段 transcript 塞进 UserDefaults(80 条上限),也让每场
/// 历史互不覆盖。
@MainActor
final class CouncilRoomArchiveStore {
    static let shared = CouncilRoomArchiveStore()

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager: FileManager

    /// 测试缝:累计成功写入次数(同步 + 延迟)。
    private(set) var completedWriteCount = 0
    private(set) var lastErrorDescription: String?

    /// 延迟写入的最新快照与串行泵:saveDeferred 只保留最新快照(latest-wins),
    /// 后台泵写完上一份再写最新一份,encode+write 不占主线程。
    private var pendingRoom: CouncilPersistedRoom?
    private var pendingGeneration: UInt64 = 0
    private var writePump: Task<Void, Never>?
    /// 同步 save 时 bump;延迟写入落盘前校验它,期间发生过同步写就说明这份
    /// 延迟快照已过时(终态同步写才是最新事实),跳过落盘避免旧快照覆盖新状态。
    private let syncWriteGeneration = CouncilArchiveWriteGeneration()

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = baseDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent("council", isDirectory: true)
    }

    @discardableResult
    func save(_ room: CouncilPersistedRoom) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(room)
            try syncWriteGeneration.performSynchronousWrite {
                try data.write(to: fileURL(for: room.taskId), options: .atomic)
            }
            completedWriteCount += 1
            lastErrorDescription = nil
            return true
        } catch {
            lastErrorDescription = error.localizedDescription
            return false
        }
    }

    /// 延迟写入:中段检查点经 ViewModel 节流合并后调用;encode+write 在后台线程,
    /// 同一时刻只保留最新快照。终态检查点继续用同步 save() 保证 load-after-save 顺序。
    func saveDeferred(_ room: CouncilPersistedRoom) {
        pendingRoom = room
        pendingGeneration = syncWriteGeneration.value
        guard writePump == nil else { return }
        let gate = syncWriteGeneration
        writePump = Task { [weak self] in
            while let next = self?.takePendingWrite() {
                let outcome = await Self.writeRoom(
                    next.room,
                    to: next.url,
                    gate: gate,
                    takenGeneration: next.generation
                )
                if outcome.written {
                    self?.noteDeferredWriteCompleted()
                } else if let errorDescription = outcome.errorDescription {
                    self?.noteDeferredWriteFailed(errorDescription)
                }
            }
            self?.clearWritePump()
        }
    }

    /// 等待写入泵排空(在途那份与 pending 的最新一份)。「写后立即 load」的检查点
    /// (openArchive 的 reload)在 load 之前先调用,保证看到最新快照。
    func flushDeferred() async {
        while let pump = writePump {
            await pump.value
        }
    }

    private func takePendingWrite() -> (room: CouncilPersistedRoom, url: URL, generation: UInt64)? {
        guard let room = pendingRoom else { return nil }
        pendingRoom = nil
        return (room, fileURL(for: room.taskId), pendingGeneration)
    }

    private func noteDeferredWriteCompleted() {
        completedWriteCount += 1
        lastErrorDescription = nil
    }

    private func noteDeferredWriteFailed(_ errorDescription: String) {
        lastErrorDescription = errorDescription
    }

    private func clearWritePump() {
        writePump = nil
    }

    private nonisolated static func writeRoom(
        _ room: CouncilPersistedRoom,
        to url: URL,
        gate: CouncilArchiveWriteGeneration,
        takenGeneration: UInt64
    ) async -> CouncilArchiveWriteOutcome {
        do {
            let data = try JSONEncoder().encode(room)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let written = try gate.performDeferredWrite(ifCurrent: takenGeneration) {
                try data.write(to: url, options: .atomic)
            }
            return CouncilArchiveWriteOutcome(written: written, errorDescription: nil)
        } catch {
            return CouncilArchiveWriteOutcome(written: false, errorDescription: error.localizedDescription)
        }
    }

    func load(taskId: String) -> CouncilPersistedRoom? {
        let url = fileURL(for: taskId)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let room = try? decoder.decode(CouncilPersistedRoom.self, from: data),
              room.taskId == taskId else {
            return nil
        }
        return room
    }

    func exists(taskId: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: taskId).path)
    }

    func delete(taskId: String) {
        try? fileManager.removeItem(at: fileURL(for: taskId))
    }

    func markInterrupted(taskIds: [String]) {
        for taskId in taskIds {
            guard let room = load(taskId: taskId) else { continue }
            let messages = room.messages.map { message -> CouncilPersistedMessage in
                guard message.status == "speaking" else { return message }
                // W3 council 轻对齐(docs/IOS_AGENT_HARDENING_PLAN_2026-07-29.md
                // §W3):机制不变,仍标 failed;只在 subtitle 本来就空时补一句可见
                // 的"发言未完成"文案,复用既有 subtitle 渲染面(metaLine),不新增
                // UI。不这样区分的话,用户看到的和"模型报错"完全一样。
                let subtitle = (message.subtitle?.isEmpty ?? true) ? "发言未完成（应用中断）" : message.subtitle
                return CouncilPersistedMessage(
                    id: message.id,
                    kind: message.kind,
                    author: message.author,
                    body: message.body,
                    systemImage: message.systemImage,
                    tintHex: message.tintHex,
                    subtitle: subtitle,
                    status: "failed"
                )
            }
            save(CouncilPersistedRoom(
                taskId: room.taskId,
                objective: room.objective,
                finalTopic: room.finalTopic,
                modeRaw: room.modeRaw,
                statusRaw: IOSAdvancedTaskStatus.interrupted.title,
                failedSpeakerIds: room.failedSpeakerIds,
                participants: room.participants,
                messages: messages,
                updatedAtMs: Date().timeIntervalSince1970 * 1000
            ))
        }
    }

    private func fileURL(for taskId: String) -> URL {
        let safe = taskId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json", isDirectory: false)
    }
}

private struct CouncilArchiveWriteOutcome: Sendable {
    let written: Bool
    let errorDescription: String?
}

/// 同步写入代数闸:延迟提交的「代数检查 + atomic replace」和终态的「代数 bump +
/// atomic replace」共享同一临界区。无论谁先进入,终态同步提交都不会被旧延迟快照覆盖。
/// `@unchecked Sendable` + NSLock:它要跨 MainActor 与后台写入任务共享,自身用锁串行化。
final class CouncilArchiveWriteGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func performSynchronousWrite(_ write: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        try write()
    }

    func performDeferredWrite(
        ifCurrent expectedGeneration: UInt64,
        _ write: () throws -> Void
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        try write()
        return true
    }

    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}


private extension Color {
    /// `#RRGGBB`。SwiftUI Color → UIColor 取分量;转换失败回退中性灰。
    var councilHexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#999999" }
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    init(councilHexString: String) {
        let hex = councilHexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

