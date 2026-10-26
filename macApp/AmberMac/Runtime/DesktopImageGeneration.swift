import Foundation
import Observation

@MainActor @Observable final class DesktopImageGeneration {
    private(set) var isRunning = false
    private(set) var ownerID: UUID?
    private(set) var artifacts: [DesktopGeneratedImageArtifact] = []
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let settings: DesktopSettings
    @ObservationIgnored private let files: DesktopWorkspaceFiles
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let history: IOSImageGenerationHistoryStore
    @ObservationIgnored private let stagingDirectory: URL
    @ObservationIgnored private let transport: any IOSImageGenerationHTTPTransport
    @ObservationIgnored private var task: Task<[DesktopGeneratedImageArtifact], Error>?

    init(settings: DesktopSettings, files: DesktopWorkspaceFiles, enabled: Bool = false,
         history: IOSImageGenerationHistoryStore? = nil, stagingDirectory: URL? = nil,
         transport: any IOSImageGenerationHTTPTransport = IOSURLSessionImageGenerationHTTPTransport()) {
        self.settings = settings
        self.files = files
        #if AMBER_MAC_PREVIEW
        self.enabled = false
        #else
        self.enabled = enabled
        #endif
        self.history = history ?? IOSImageGenerationHistoryStore(key: "app.amber.macos.imageGeneration.staging.v1")
        self.stagingDirectory = stagingDirectory ?? URL.applicationSupportDirectory
            .appendingPathComponent("Amber/image-staging", isDirectory: true)
        self.transport = transport
        if let record = self.history.records.first(where: { Self.owner(of: $0) != nil }),
           let owner = Self.owner(of: record) {
            ownerID = owner
            statusMessage = "有 \(pendingSaveCount(for: owner)) 张已生成的图片待保存。"
        }
    }

    var isAvailable: Bool { enabled }
    var configuredModelName: String? {
        settings.configuredAuxiliaryModel(for: .imageGeneration)?.selectedModel?.displayName
    }

    func pendingSaveCount(for ownerID: UUID) -> Int {
        history.records.filter { Self.owner(of: $0) == ownerID }.reduce(0) { $0 + $1.files.count }
    }

    func hasPendingSave(for ownerID: UUID) -> Bool { pendingSaveCount(for: ownerID) > 0 }

    @discardableResult
    func generate(ownerID: UUID, prompt: String, aspectRatio: IOSImageAspectRatio = .square,
                  count: Int = 1, style: String = "") async throws -> [DesktopGeneratedImageArtifact] {
        try Task.checkCancellation()
        guard !isRunning else { throw DesktopRuntimeError.message("图片正在生成，请等待完成或先取消。") }
        guard !hasPendingSave(for: ownerID) else {
            throw validationFailure("此会话还有已生成的图片待保存，请先重试保存，不必重新生成。")
        }
        errorMessage = nil
        statusMessage = nil
        guard enabled else { throw validationFailure("界面预览不调用真实生图服务，请使用正式版本。") }
        guard let configuration = settings.configuredAuxiliaryModel(for: .imageGeneration),
              let model = configuration.selectedModel else {
            throw validationFailure("请先在设置的辅助任务中选择生图模型。")
        }
        guard configuration.kind == .openAI || configuration.kind == .responses else {
            throw validationFailure("生图支持 OpenAI 兼容服务或 Codex 登录，请选择相应服务商的生图模型。")
        }
        guard configuration.authMode == .apiKey || configuration.authMode == .codexOAuth else {
            throw validationFailure("当前登录方式不支持图片生成。")
        }
        let apiKey = configuration.authMode == .apiKey ? try settings.apiKey(for: configuration.id) : ""
        let request = IOSImageGenerationRequest(prompt: prompt, model: model.modelID, aspectRatio: aspectRatio,
            count: count, style: style, source: "macos:" + ownerID.uuidString)
        artifacts = []
        let repository = IOSImageGenerationRepository(historyStore: history, outputDirectory: stagingDirectory)
        return try await perform(ownerID: ownerID, status: "正在生成图片…") { [self] in
            let record: IOSImageGenerationRecord
            if configuration.authMode == .codexOAuth {
                record = try await repository.generateViaCodex(request: request,
                    providerId: configuration.id.uuidString.lowercased(), transport: transport)
            } else {
                record = try await repository.generate(request: request, apiKey: apiKey,
                    baseURL: configuration.baseURL, transport: transport)
            }
            return try await savePending([record], ownerID: ownerID)
        }
    }

    @discardableResult
    func retrySaving(ownerID: UUID) async throws -> [DesktopGeneratedImageArtifact] {
        try Task.checkCancellation()
        guard !isRunning else { throw DesktopRuntimeError.message("图片正在处理，请等待完成或先取消。") }
        let records = history.records.filter { Self.owner(of: $0) == ownerID && !$0.files.isEmpty }
        guard !records.isEmpty else { throw DesktopRuntimeError.message("此会话没有待保存的图片。") }
        return try await perform(ownerID: ownerID, status: "正在保存已生成的图片…") { [self] in
            try await savePending(records, ownerID: ownerID)
        }
    }

    private func savePending(_ records: [IOSImageGenerationRecord], ownerID: UUID) async throws -> [DesktopGeneratedImageArtifact] {
        for record in records {
            var remaining = record
            for image in record.files {
                try Task.checkCancellation()
                let artifact = try await files.importGeneratedImage(conversationID: ownerID,
                    from: URL(fileURLWithPath: image.path))
                artifacts.append(artifact)
                remaining.files.removeAll { $0.id == image.id }
                remaining.count = remaining.files.count
                if remaining.files.isEmpty { history.delete(id: record.id, removeFiles: false) }
                else { history.insert(remaining) }
                // Retire only the image whose original-owner copy has been written.
                try? FileManager.default.removeItem(atPath: image.path)
            }
        }
        try Task.checkCancellation()
        return artifacts
    }

    private static func owner(of record: IOSImageGenerationRecord) -> UUID? {
        guard record.source.hasPrefix("macos:") else { return nil }
        return UUID(uuidString: String(record.source.dropFirst("macos:".count)))
    }

    private func perform(ownerID: UUID, status: String,
                         operation: @escaping @MainActor () async throws -> [DesktopGeneratedImageArtifact]) async throws -> [DesktopGeneratedImageArtifact] {
        if self.ownerID != ownerID { artifacts = [] }
        self.ownerID = ownerID
        errorMessage = nil
        statusMessage = status
        isRunning = true
        let operation = Task { try await operation() }
        task = operation
        defer {
            task = nil
            isRunning = false
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            statusMessage = "已保存 \(result.count) 张图片到原会话文件。"
            return result
        } catch {
            let pending = pendingSaveCount(for: ownerID)
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                statusMessage = artifacts.isEmpty ? "已取消图片生成。" : "已取消，已保存 \(artifacts.count) 张图片到原会话文件。"
            } else {
                errorMessage = Self.message(for: error)
                statusMessage = artifacts.isEmpty ? nil : "已保存 \(artifacts.count) 张图片到原会话文件。"
            }
            if pending > 0 {
                statusMessage = "已保存 \(artifacts.count) 张，另有 \(pending) 张已生成的图片待保存。"
            }
            throw error
        }
    }

    func cancel() { task?.cancel() }

    func shutdown() async {
        let operation = task
        operation?.cancel()
        _ = try? await operation?.value
    }

    private func validationFailure(_ message: String) -> DesktopRuntimeError {
        errorMessage = message
        return .message(message)
    }

    private static func message(for error: Error) -> String {
        if let imageError = error as? IOSImageGenerationError {
            switch imageError {
            case .httpStatus(let status, _): return "图片生成失败：HTTP \(status)。"
            case .noImages: return "服务没有返回可保存的图片，请检查模型及提示词。"
            default: return imageError.localizedDescription
            }
        }
        if error is IOSCodexOAuthError { return "Codex 生图失败，请检查登录状态与生图模型后重试。" }
        if error is URLError { return "生图网络请求失败，请检查连接后重试。" }
        return "图片生成或保存失败，请检查工作区文件后重试。"
    }
}
