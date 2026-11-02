import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@preconcurrency import Shared

// MARK: - Amber Personal Agent Persona Model & Store (Muse-Style Generate / Upload / Multi-Frame Animation)

enum AmberPersonaPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Amber's signature original mascot: Warm Amber Kitsune / Spirit Fox with expressive ears & eyes.
    case amberFox = "amber_fox"
    /// Luminous faceted amber gem spirit with warm inner core.
    case amberCrystal = "amber_crystal"
    /// User-uploaded or AI-generated Muse-style custom portrait / multi-frame short animation.
    case customPortrait = "custom_portrait"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .amberFox: "琥珀灵狐"
        case .amberCrystal: "琥珀星晶"
        case .customPortrait: "自定义形象"
        }
    }

    var subtitle: String {
        switch self {
        case .amberFox: "Amber 原生灵狐形象 · 随待命/思考/提醒切换神态"
        case .amberCrystal: "温润琥珀几何晶核 · 极简克制"
        case .customPortrait: "上传静态形象图或生成 3–4 帧微表情短动画"
        }
    }
}

enum AmberPersonaPendingPreviewKind: String, Equatable, Sendable {
    case staticImage
    case multiFrameAnimation
}

struct AmberPersonaAnimationManifest: Codable, Equatable, Sendable {
    var frameFileNames: [String]
    var frameIntervalMs: Int
    var updatedAtMs: Int64
}

struct AmberPersonaReferenceItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var label: String
    var fileName: String
    var createdAtMs: Int64
}

@MainActor
@Observable
final class AmberPersonaStore {
    static let shared = AmberPersonaStore()

    var preset: AmberPersonaPreset {
        didSet {
            defaults.set(preset.rawValue, forKey: Keys.preset)
            if oldValue != preset {
                lastGenerationError = nil
            }
        }
    }

    var personaStylePrompt: String {
        didSet { defaults.set(personaStylePrompt, forKey: Keys.stylePrompt) }
    }

    var autoBindReferenceInImageGen: Bool {
        didSet { defaults.set(autoBindReferenceInImageGen, forKey: Keys.autoBindRef) }
    }

    private(set) var customAvatarImage: UIImage?
    private(set) var customAnimationFrames: [UIImage] = []
    private(set) var isMultiFrameAnimationActive = false {
        didSet { defaults.set(isMultiFrameAnimationActive, forKey: Keys.multiFrameActive) }
    }
    private(set) var animationFrameIntervalMs: Int = 550
    private(set) var pendingPreviewKind: AmberPersonaPendingPreviewKind?
    private(set) var pendingPreviewImage: UIImage?
    private(set) var pendingPreviewAnimationFrames: [UIImage] = []
    private(set) var referenceItems: [AmberPersonaReferenceItem] = []
    private(set) var isGeneratingAvatar = false
    private(set) var generationProgressText: String?
    private(set) var lastGenerationError: String?

    @ObservationIgnored var staticGeneratorOverrideForTesting: ((_ prompt: String, _ sourceImageDataURL: String?) async throws -> UIImage)?
    @ObservationIgnored var frameGeneratorOverrideForTesting: ((_ prompt: String, _ sourceImageDataURL: String?, _ frameCount: Int) async throws -> [UIImage])?
    @ObservationIgnored private var activeGenerationTask: Task<Void, Never>?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let baseDirectory: URL

    private enum Keys {
        static let preset = "app.amber.ios.persona.preset"
        static let stylePrompt = "app.amber.ios.persona.stylePrompt"
        static let autoBindRef = "app.amber.ios.persona.autoBindRef"
        static let references = "app.amber.ios.persona.references"
        static let multiFrameActive = "app.amber.ios.persona.multiFrameActive"
    }

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.defaults = userDefaults
        self.fileManager = fileManager
        let resolvedDir = baseDirectory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("amber-persona", isDirectory: true)
        self.baseDirectory = resolvedDir
        self.preset = AmberPersonaPreset(rawValue: userDefaults.string(forKey: Keys.preset) ?? "") ?? .amberFox
        self.personaStylePrompt = userDefaults.string(forKey: Keys.stylePrompt)
            ?? "温暖治愈的个人 AI 伙伴 Amber，琥珀色眼眸与暖米色围巾，柔和纸感插画风格，干净头像特写"
        if userDefaults.object(forKey: Keys.autoBindRef) == nil {
            self.autoBindReferenceInImageGen = true
        } else {
            self.autoBindReferenceInImageGen = userDefaults.bool(forKey: Keys.autoBindRef)
        }
        self.isMultiFrameAnimationActive = userDefaults.bool(forKey: Keys.multiFrameActive)
        if let data = userDefaults.data(forKey: Keys.references),
           let decoded = try? JSONDecoder().decode([AmberPersonaReferenceItem].self, from: data) {
            self.referenceItems = decoded
        }
        reloadAvatarFromDisk()
    }

    convenience init(defaults: UserDefaults, storageDirectory: URL) {
        self.init(userDefaults: defaults, fileManager: .default, baseDirectory: storageDirectory)
    }

    var selectedPreset: AmberPersonaPreset {
        get { preset }
        set { preset = newValue }
    }

    var references: [AmberPersonaReferenceItem] {
        referenceItems
    }

    var hasPendingPreview: Bool {
        pendingPreviewKind != nil
    }

    var hasActiveMultiFrameAnimation: Bool {
        preset == .customPortrait && isMultiFrameAnimationActive && customAnimationFrames.count > 1
    }

    var canResetToDefault: Bool {
        preset != .amberFox || customAvatarImage != nil || !customAnimationFrames.isEmpty || hasPendingPreview
    }

    @discardableResult
    func addReferenceImage(from data: Data, label: String? = nil) -> AmberPersonaReferenceItem? {
        guard let image = UIImage(data: data) else { return nil }
        return addReferenceImage(image, label: label)
    }

    func clearError() {
        lastGenerationError = nil
    }

    /// Stages an uploaded static image in preview state so the user can inspect and confirm before replacing the active avatar.
    @discardableResult
    func stageUploadedAvatarForPreview(_ image: UIImage) -> Bool {
        let downscaled = Self.downscale(image, maxDimension: 512)
        guard downscaled.size.width > 0, downscaled.size.height > 0 else { return false }
        pendingPreviewImage = downscaled
        pendingPreviewAnimationFrames = []
        pendingPreviewKind = .staticImage
        lastGenerationError = nil
        return true
    }

    @discardableResult
    func stageUploadedAvatarDataForPreview(_ data: Data) -> Bool {
        guard let image = UIImage(data: data) else {
            lastGenerationError = "无法解析所选图片文件，请选择 PNG / JPEG / HEIC 格式的图片。"
            return false
        }
        return stageUploadedAvatarForPreview(image)
    }

    /// Stages a generated multi-frame animation sequence in preview state for user confirmation.
    @discardableResult
    func stageAnimationFramesForPreview(_ frames: [UIImage]) -> Bool {
        let normalized = frames.map { Self.downscale($0, maxDimension: 512) }
        guard normalized.count >= 2 else { return false }
        pendingPreviewAnimationFrames = normalized
        pendingPreviewImage = normalized.first
        pendingPreviewKind = .multiFrameAnimation
        lastGenerationError = nil
        return true
    }

    /// Confirms the staged preview (either static image or multi-frame animation) and persists it as the active avatar.
    @discardableResult
    func confirmPendingPreview() -> Bool {
        guard let kind = pendingPreviewKind else { return false }
        switch kind {
        case .staticImage:
            guard let image = pendingPreviewImage else { return false }
            saveCustomAvatar(image)
            discardPendingPreview()
            return true
        case .multiFrameAnimation:
            guard pendingPreviewAnimationFrames.count >= 2 else { return false }
            saveCustomAnimationFrames(pendingPreviewAnimationFrames)
            discardPendingPreview()
            return true
        }
    }

    /// Cancels the staged preview without touching the currently active avatar or persisted files.
    func discardPendingPreview() {
        pendingPreviewKind = nil
        pendingPreviewImage = nil
        pendingPreviewAnimationFrames = []
    }

    /// Resets the persona back to the default preset (`amberFox`) and clears custom static/animated portrait state.
    func resetToDefault(preset defaultPreset: AmberPersonaPreset = .amberFox) {
        cancelAvatarGeneration()
        discardPendingPreview()
        lastGenerationError = nil
        removeSavedAnimationFiles()
        try? fileManager.removeItem(at: baseDirectory.appendingPathComponent("avatar.png"))
        customAvatarImage = nil
        customAnimationFrames = []
        isMultiFrameAnimationActive = false
        preset = defaultPreset
    }

    /// Immediately persists a static custom avatar (and disables any previous multi-frame animation so the two states remain distinct).
    func saveCustomAvatar(_ image: UIImage) {
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let downscaled = Self.downscale(image, maxDimension: 512)
        guard let data = downscaled.pngData() else { return }
        let url = baseDirectory.appendingPathComponent("avatar.png")
        try? data.write(to: url, options: .atomic)
        removeSavedAnimationFiles()
        customAnimationFrames = []
        isMultiFrameAnimationActive = false
        customAvatarImage = downscaled
        preset = .customPortrait
    }

    /// Immediately persists a discrete multi-frame animation sequence (`anim_frame_0.png`...) and activates multi-frame mode.
    func saveCustomAnimationFrames(_ frames: [UIImage], frameIntervalMs: Int = 550) {
        let normalized = frames.map { Self.downscale($0, maxDimension: 512) }
        guard normalized.count >= 2 else { return }
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        removeSavedAnimationFiles()

        var savedFileNames: [String] = []
        var savedImages: [UIImage] = []
        for (index, frame) in normalized.enumerated() {
            let fileName = "anim_frame_\(index).png"
            let url = baseDirectory.appendingPathComponent(fileName)
            guard let data = frame.pngData() else { continue }
            do {
                try data.write(to: url, options: .atomic)
                savedFileNames.append(fileName)
                savedImages.append(frame)
            } catch {
                continue
            }
        }
        guard savedImages.count >= 2 else { return }

        if let firstData = savedImages[0].pngData() {
            try? firstData.write(to: baseDirectory.appendingPathComponent("avatar.png"), options: .atomic)
        }
        let manifest = AmberPersonaAnimationManifest(
            frameFileNames: savedFileNames,
            frameIntervalMs: max(300, frameIntervalMs),
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        if let manifestData = try? JSONEncoder().encode(manifest) {
            try? manifestData.write(
                to: baseDirectory.appendingPathComponent("animation_manifest.json"),
                options: .atomic
            )
        }
        customAvatarImage = savedImages[0]
        customAnimationFrames = savedImages
        animationFrameIntervalMs = manifest.frameIntervalMs
        isMultiFrameAnimationActive = true
        preset = .customPortrait
    }

    @discardableResult
    func addReferenceImage(_ image: UIImage, label: String? = nil) -> AmberPersonaReferenceItem? {
        guard referenceItems.count < 4 else { return nil }
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let fileName = "ref_\(id).png"
        let downscaled = Self.downscale(image, maxDimension: 768)
        guard let data = downscaled.pngData() else { return nil }
        let url = baseDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            let defaultLabel = label ?? "参考图 \(referenceItems.count + 1)"
            let item = AmberPersonaReferenceItem(
                id: id,
                label: defaultLabel,
                fileName: fileName,
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
            referenceItems.append(item)
            persistReferences()
            return item
        } catch {
            return nil
        }
    }

    func removeReference(id: String) {
        guard let item = referenceItems.first(where: { $0.id == id }) else { return }
        let url = baseDirectory.appendingPathComponent(item.fileName)
        try? fileManager.removeItem(at: url)
        referenceItems.removeAll { $0.id == id }
        persistReferences()
    }

    func loadReferenceImage(for item: AmberPersonaReferenceItem) -> UIImage? {
        let url = baseDirectory.appendingPathComponent(item.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Returns a `data:image/jpeg;base64,...` URL for the primary reference image (or custom avatar fallback)
    /// so `ChatImageGenerationReference` can automatically pad it into `generate_image`.
    func primaryReferenceDataURL() -> String? {
        if let first = referenceItems.first {
            let url = baseDirectory.appendingPathComponent(first.fileName)
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data),
               let jpeg = image.jpegData(compressionQuality: 0.88),
               !jpeg.isEmpty {
                return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            }
        }
        if let customAvatarImage,
           let jpeg = customAvatarImage.jpegData(compressionQuality: 0.88),
           !jpeg.isEmpty {
            return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        }
        return nil
    }

    /// Returns the best source image data URL for generating an avatar or multi-frame animation
    /// (prefers staged preview image, then active custom avatar, then primary reference image).
    func sourceImageDataURLForGeneration() -> String? {
        if let pendingPreviewImage,
           let jpeg = pendingPreviewImage.jpegData(compressionQuality: 0.88),
           !jpeg.isEmpty {
            return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        }
        if let customAvatarImage,
           let jpeg = customAvatarImage.jpegData(compressionQuality: 0.88),
           !jpeg.isEmpty {
            return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        }
        return primaryReferenceDataURL()
    }

    func hasConfiguredImageGenerationProvider(sharedSettings: IOSSharedSettingsStore) -> Bool {
        if staticGeneratorOverrideForTesting != nil || frameGeneratorOverrideForTesting != nil {
            return true
        }
        return resolveImageGenerationCredentials(sharedSettings: sharedSettings) != nil
    }

    func cancelAvatarGeneration() {
        activeGenerationTask?.cancel()
        activeGenerationTask = nil
        isGeneratingAvatar = false
        generationProgressText = nil
    }

    @discardableResult
    func startGenerateAnimationFramesTask(
        sharedSettings: IOSSharedSettingsStore,
        frameCount: Int = 3
    ) -> Task<Void, Never> {
        activeGenerationTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateAnimationFramesWithAI(sharedSettings: sharedSettings, frameCount: frameCount)
        }
        activeGenerationTask = task
        return task
    }

    func generateAvatarWithAI(sharedSettings: IOSSharedSettingsStore) async {
        let prompt = personaStylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            lastGenerationError = "请先输入 Amber 的形象描述词"
            return
        }
        isGeneratingAvatar = true
        generationProgressText = "正在生成静态形象预览…"
        lastGenerationError = nil
        defer {
            isGeneratingAvatar = false
            generationProgressText = nil
        }

        let fullPrompt = """
        Personal AI agent avatar portrait for Amber: \(prompt). Centered circular-friendly bust composition, expressive eyes, warm editorial illustration quality, clean background.
        """
        let sourceURL = autoBindReferenceInImageGen ? sourceImageDataURLForGeneration() : nil

        if let override = staticGeneratorOverrideForTesting {
            do {
                let image = try await override(fullPrompt, sourceURL)
                guard !Task.isCancelled else { return }
                _ = stageUploadedAvatarForPreview(image)
            } catch is CancellationError {
                return
            } catch {
                lastGenerationError = error.localizedDescription
            }
            return
        }

        guard let credentials = resolveImageGenerationCredentials(sharedSettings: sharedSettings) else {
            lastGenerationError = "请先在「设置 → 默认模型 → 辅助任务」中配置生图模型，或直接从相册/文件换图。"
            return
        }

        do {
            let record = try await IOSImageGenerationRepository.shared.generate(
                request: IOSImageGenerationRequest(
                    prompt: fullPrompt,
                    model: credentials.modelId,
                    aspectRatio: .square,
                    count: 1,
                    style: "illustration",
                    source: "persona_studio",
                    sourceImageURL: sourceURL
                ),
                apiKey: credentials.apiKey,
                baseURL: credentials.baseURL
            )
            guard !Task.isCancelled else { return }
            if let firstPath = record.files.first?.path,
               let data = try? Data(contentsOf: URL(fileURLWithPath: firstPath)),
               let image = UIImage(data: data) {
                _ = stageUploadedAvatarForPreview(image)
                return
            }
            lastGenerationError = "生图未返回有效图像，原有形象已保留。"
        } catch is CancellationError {
            return
        } catch {
            lastGenerationError = error.localizedDescription
        }
    }

    /// Generates a 3–4 frame subtle expression sequence from the current/uploaded image and prompt, staging it in preview.
    func generateAnimationFramesWithAI(
        sharedSettings: IOSSharedSettingsStore,
        frameCount: Int = 3
    ) async {
        let clampedCount = min(max(frameCount, 3), 4)
        let prompt = personaStylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            lastGenerationError = "请先输入 Amber 的形象描述词"
            return
        }

        isGeneratingAvatar = true
        generationProgressText = "正在生成 \(clampedCount) 帧微动画（1/\(clampedCount)）…"
        lastGenerationError = nil
        defer {
            isGeneratingAvatar = false
            generationProgressText = nil
        }

        let sourceURL = sourceImageDataURLForGeneration()
        let frameDirectives = [
            "Frame 1: calm attentive gaze, neutral warm expression, centered circular avatar portrait, identical character identity and lighting.",
            "Frame 2: soft gentle blink with warm micro-smile, centered circular avatar portrait, identical character identity and lighting.",
            "Frame 3: subtle curious head tilt with bright attentive eyes, centered circular avatar portrait, identical character identity and lighting.",
            "Frame 4: relaxed warm expression returning to neutral posture, centered circular avatar portrait, identical character identity and lighting."
        ]

        if let override = frameGeneratorOverrideForTesting {
            do {
                let generated = try await override(prompt, sourceURL, clampedCount)
                try Task.checkCancellation()
                guard generated.count >= 2 else {
                    lastGenerationError = "微动画至少需要 2 帧有效图像，原有形象已保留。"
                    return
                }
                _ = stageAnimationFramesForPreview(Array(generated.prefix(clampedCount)))
            } catch is CancellationError {
                return
            } catch {
                lastGenerationError = error.localizedDescription
            }
            return
        }

        guard let credentials = resolveImageGenerationCredentials(sharedSettings: sharedSettings) else {
            lastGenerationError = "请先在「设置 → 默认模型 → 辅助任务」中配置生图模型，或直接从相册/文件换图。"
            return
        }

        var generatedFrames: [UIImage] = []
        var anchorSourceURL = sourceURL

        do {
            for index in 0..<clampedCount {
                try Task.checkCancellation()
                generationProgressText = "正在生成 \(clampedCount) 帧微动画（\(index + 1)/\(clampedCount)）…"
                let directive = frameDirectives[min(index, frameDirectives.count - 1)]
                let framePrompt = """
                Personal AI agent multi-frame avatar animation for Amber (\(index + 1)/\(clampedCount)): \(prompt). \(directive) Keep exact same character design, framing, and background across frames.
                """
                let record = try await IOSImageGenerationRepository.shared.generate(
                    request: IOSImageGenerationRequest(
                        prompt: framePrompt,
                        model: credentials.modelId,
                        aspectRatio: .square,
                        count: 1,
                        style: "illustration",
                        source: "persona_studio_animation",
                        sourceImageURL: anchorSourceURL
                    ),
                    apiKey: credentials.apiKey,
                    baseURL: credentials.baseURL
                )
                try Task.checkCancellation()
                guard let firstPath = record.files.first?.path,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: firstPath)),
                      let image = UIImage(data: data) else {
                    lastGenerationError = "第 \(index + 1) 帧生成未返回有效图像，原有形象已保留。"
                    return
                }
                let downscaled = Self.downscale(image, maxDimension: 512)
                generatedFrames.append(downscaled)
                if anchorSourceURL == nil,
                   let jpeg = downscaled.jpegData(compressionQuality: 0.88),
                   !jpeg.isEmpty {
                    anchorSourceURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
                }
            }
            _ = stageAnimationFramesForPreview(generatedFrames)
        } catch is CancellationError {
            return
        } catch {
            lastGenerationError = error.localizedDescription
        }
    }

    private func resolveImageGenerationCredentials(
        sharedSettings: IOSSharedSettingsStore
    ) -> (modelId: String, apiKey: String, baseURL: String)? {
        let snapshot = sharedSettings.snapshot
        guard let model = snapshot.findModelById(uuid: snapshot.imageGenerationModelId),
              let provider = ChatProviderConfiguration.provider(for: model, providers: snapshot.providers),
              provider.enabled,
              let apiKey = (provider as? ProviderSetting.OpenAI)?.apiKey ?? (provider as? ProviderSetting.Google)?.apiKey,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let baseURL = (provider as? ProviderSetting.OpenAI)?.baseUrl ?? "https://api.openai.com/v1"
        return (model.modelId, apiKey, baseURL)
    }

    private func reloadAvatarFromDisk() {
        let url = baseDirectory.appendingPathComponent("avatar.png")
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            customAvatarImage = image
        }
        let manifestURL = baseDirectory.appendingPathComponent("animation_manifest.json")
        if let manifestData = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(AmberPersonaAnimationManifest.self, from: manifestData) {
            var loadedFrames: [UIImage] = []
            for fileName in manifest.frameFileNames {
                let frameURL = baseDirectory.appendingPathComponent(fileName)
                if let frameData = try? Data(contentsOf: frameURL),
                   let frameImage = UIImage(data: frameData) {
                    loadedFrames.append(frameImage)
                }
            }
            if loadedFrames.count >= 2 {
                customAnimationFrames = loadedFrames
                animationFrameIntervalMs = max(300, manifest.frameIntervalMs)
                if customAvatarImage == nil {
                    customAvatarImage = loadedFrames.first
                }
            } else {
                isMultiFrameAnimationActive = false
            }
        } else {
            isMultiFrameAnimationActive = false
        }
    }

    private func removeSavedAnimationFiles() {
        let manifestURL = baseDirectory.appendingPathComponent("animation_manifest.json")
        if let manifestData = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(AmberPersonaAnimationManifest.self, from: manifestData) {
            for fileName in manifest.frameFileNames {
                try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(fileName))
            }
        }
        for index in 0..<8 {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent("anim_frame_\(index).png"))
        }
        try? fileManager.removeItem(at: manifestURL)
    }

    private func persistReferences() {
        if let data = try? JSONEncoder().encode(referenceItems) {
            defaults.set(data, forKey: Keys.references)
        }
    }

    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let ratio = min(maxDimension / max(size.width, size.height), 1.0)
        if ratio >= 1.0 { return image }
        let targetSize = CGSize(width: round(size.width * ratio), height: round(size.height * ratio))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

// MARK: - Amber Personal Agent Medallion View (Supports Amber Fox, Amber Crystal, Static Portrait & Discrete Multi-Frame Animation)

enum AmberAgentPersonaMood: Equatable, Sendable {
    case idle
    case working
    case alert
}

struct AmberAgentPersonaMedallionView: View {
    let mood: AmberAgentPersonaMood
    var diameter: CGFloat = ChatTopBarLayout.avatarDiameter
    var presetOverride: AmberPersonaPreset? = nil
    var accentOverride: Color? = nil
    var storeOverride: AmberPersonaStore? = nil
    var showStagedPreview: Bool = false
    var reduceMotionOverride: Bool? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var store: AmberPersonaStore { storeOverride ?? AmberPersonaStore.shared }

    private var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private var activePreset: AmberPersonaPreset {
        if showStagedPreview, store.hasPendingPreview {
            return .customPortrait
        }
        return presetOverride ?? store.preset
    }

    private var activeAnimationFrames: [UIImage] {
        if showStagedPreview, store.pendingPreviewKind == .multiFrameAnimation, store.pendingPreviewAnimationFrames.count > 1 {
            return store.pendingPreviewAnimationFrames
        }
        if showStagedPreview, store.pendingPreviewKind == .staticImage {
            return []
        }
        if activePreset == .customPortrait, store.isMultiFrameAnimationActive, store.customAnimationFrames.count > 1 {
            return store.customAnimationFrames
        }
        return []
    }

    private var activeStaticImage: UIImage? {
        if showStagedPreview, store.pendingPreviewKind == .staticImage, let preview = store.pendingPreviewImage {
            return preview
        }
        if showStagedPreview, store.pendingPreviewKind == .multiFrameAnimation, let first = store.pendingPreviewAnimationFrames.first {
            return first
        }
        return store.customAvatarImage
    }

    private var accentColor: Color {
        if let accentOverride { return accentOverride }
        return mood == .alert ? AmberTheme.accentRed : AmberTheme.accent
    }

    /// Deterministic frame selector for discrete multi-frame animation.
    /// Strictly returns frame `0` when `reduceMotion` is enabled or fewer than 2 frames exist.
    static func activeFrameIndex(
        at date: Date,
        frameCount: Int,
        frameIntervalMs: Int = 550,
        reduceMotion: Bool
    ) -> Int {
        guard frameCount > 1, !reduceMotion else { return 0 }
        let cycle: [Int]
        if frameCount == 2 {
            cycle = [0, 1]
        } else {
            let forward = Array(0..<frameCount)
            let backward = Array((1..<(frameCount - 1)).reversed())
            cycle = forward + backward
        }
        let intervalSeconds = Double(max(300, frameIntervalMs)) / 1000.0
        let step = Int(floor(max(0, date.timeIntervalSinceReferenceDate) / intervalSeconds))
        return cycle[step % cycle.count]
    }

    var body: some View {
        ZStack {
            personaBackdropGlass

            switch activePreset {
            case .customPortrait:
                let frames = activeAnimationFrames
                if frames.count > 1 {
                    if effectiveReduceMotion {
                        portraitImageCircle(frames[0])
                    } else {
                        let interval = Double(max(300, store.animationFrameIntervalMs)) / 1000.0
                        TimelineView(.periodic(from: .now, by: interval)) { context in
                            let index = Self.activeFrameIndex(
                                at: context.date,
                                frameCount: frames.count,
                                frameIntervalMs: store.animationFrameIntervalMs,
                                reduceMotion: false
                            )
                            portraitImageCircle(frames[index])
                        }
                    }
                } else if let uiImage = activeStaticImage {
                    portraitImageCircle(uiImage)
                } else {
                    amberFoxCanvas
                }
            case .amberCrystal:
                amberCrystalCanvas
            case .amberFox:
                amberFoxCanvas
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func portraitImageCircle(_ uiImage: UIImage) -> some View {
        Image(uiImage: uiImage)
            .resizable()
            .scaledToFill()
            .frame(width: max(1, diameter - 2), height: max(1, diameter - 2))
            .clipShape(Circle())
    }

    @ViewBuilder
    private var personaBackdropGlass: some View {
        let baseCircle = Circle()
            .fill(AmberTheme.glass.opacity(0.18))
            .overlay {
                RadialGradient(
                    colors: [
                        accentColor.opacity(mood == .working ? 0.16 : 0.09),
                        Color.clear,
                    ],
                    center: .init(x: 0.5, y: 0.45),
                    startRadius: 2,
                    endRadius: diameter * 0.46
                )
                .clipShape(Circle())
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        mood == .alert ? AmberTheme.accentRed.opacity(0.45) : AmberTheme.border.opacity(0.32),
                        lineWidth: 0.75
                    )
            }
        if #available(iOS 26.0, *) {
            baseCircle.glassEffect(.regular, in: Circle())
        } else {
            baseCircle
                .background(Circle().fill(.ultraThinMaterial))
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
        }
    }

    private var amberFoxCanvas: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w * 0.5
            let cy = h * 0.51

            let earLift: CGFloat = mood == .alert ? -2.0 : (mood == .working ? 0.5 : 0)
            var leftEar = Path()
            leftEar.move(to: CGPoint(x: cx - w * 0.23, y: cy - h * 0.04))
            leftEar.addQuadCurve(
                to: CGPoint(x: cx - w * 0.25, y: cy - h * 0.30 + earLift),
                control: CGPoint(x: cx - w * 0.29, y: cy - h * 0.18)
            )
            leftEar.addQuadCurve(
                to: CGPoint(x: cx - w * 0.06, y: cy - h * 0.14),
                control: CGPoint(x: cx - w * 0.14, y: cy - h * 0.26)
            )
            leftEar.closeSubpath()
            context.fill(leftEar, with: .color(accentColor))

            var rightEar = Path()
            rightEar.move(to: CGPoint(x: cx + w * 0.23, y: cy - h * 0.04))
            rightEar.addQuadCurve(
                to: CGPoint(x: cx + w * 0.25, y: cy - h * 0.30 + earLift),
                control: CGPoint(x: cx + w * 0.29, y: cy - h * 0.18)
            )
            rightEar.addQuadCurve(
                to: CGPoint(x: cx + w * 0.06, y: cy - h * 0.14),
                control: CGPoint(x: cx + w * 0.14, y: cy - h * 0.26)
            )
            rightEar.closeSubpath()
            context.fill(rightEar, with: .color(accentColor))

            var innerLeftEar = Path()
            innerLeftEar.move(to: CGPoint(x: cx - w * 0.19, y: cy - h * 0.09))
            innerLeftEar.addLine(to: CGPoint(x: cx - w * 0.21, y: cy - h * 0.24 + earLift))
            innerLeftEar.addLine(to: CGPoint(x: cx - w * 0.10, y: cy - h * 0.14))
            innerLeftEar.closeSubpath()
            context.fill(innerLeftEar, with: .color(AmberTheme.background.opacity(0.92)))

            var innerRightEar = Path()
            innerRightEar.move(to: CGPoint(x: cx + w * 0.19, y: cy - h * 0.09))
            innerRightEar.addLine(to: CGPoint(x: cx + w * 0.21, y: cy - h * 0.24 + earLift))
            innerRightEar.addLine(to: CGPoint(x: cx + w * 0.10, y: cy - h * 0.14))
            innerRightEar.closeSubpath()
            context.fill(innerRightEar, with: .color(AmberTheme.background.opacity(0.92)))

            let headW = w * 0.48
            let headH = h * 0.38
            let headRect = CGRect(x: cx - headW * 0.5, y: cy - headH * 0.48, width: headW, height: headH)
            context.fill(
                Path(roundedRect: headRect, cornerRadius: headH * 0.46, style: .continuous),
                with: .color(accentColor)
            )

            let cheekW = w * 0.39
            let cheekH = h * 0.20
            let cheekRect = CGRect(x: cx - cheekW * 0.5, y: cy - cheekH * 0.10, width: cheekW, height: cheekH)
            context.fill(
                Path(roundedRect: cheekRect, cornerRadius: cheekH * 0.48, style: .continuous),
                with: .color(AmberTheme.background)
            )

            let eyeY = cy - h * 0.04
            let eyeOffset = w * 0.095
            let eyeR = max(1.8, w * (mood == .alert ? 0.042 : 0.036))

            for sign in [-1.0, 1.0] {
                let ex = cx + CGFloat(sign) * eyeOffset
                let rect = CGRect(x: ex - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2)
                context.fill(Path(ellipseIn: rect), with: .color(AmberTheme.foreground))
                let specR = max(0.7, eyeR * 0.36)
                context.fill(
                    Path(ellipseIn: CGRect(x: ex - eyeR * 0.35, y: eyeY - eyeR * 0.45, width: specR * 2, height: specR * 2)),
                    with: .color(.white.opacity(0.92))
                )
            }

            let noseR = max(1.4, w * 0.023)
            context.fill(
                Path(ellipseIn: CGRect(x: cx - noseR, y: cy + h * 0.03 - noseR, width: noseR * 2, height: noseR * 2)),
                with: .color(AmberTheme.foreground)
            )
        }
        .scaleEffect(1.16)
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    private var amberCrystalCanvas: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w * 0.5
            let cy = h * 0.47
            let r = w * 0.25

            var gem = Path()
            gem.move(to: CGPoint(x: cx, y: cy - r * 1.15))
            gem.addLine(to: CGPoint(x: cx + r * 0.95, y: cy - r * 0.2))
            gem.addLine(to: CGPoint(x: cx + r * 0.65, y: cy + r * 0.95))
            gem.addLine(to: CGPoint(x: cx - r * 0.65, y: cy + r * 0.95))
            gem.addLine(to: CGPoint(x: cx - r * 0.95, y: cy - r * 0.2))
            gem.closeSubpath()
            context.fill(gem, with: .color(accentColor))

            for sign in [-1.0, 1.0] {
                let ex = cx + CGFloat(sign) * w * 0.075
                let ey = cy - h * 0.02
                let er = max(1.7, w * 0.032)
                context.fill(
                    Path(ellipseIn: CGRect(x: ex - er, y: ey - er, width: er * 2, height: er * 2)),
                    with: .color(.white)
                )
            }
        }
        .scaleEffect(1.16)
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

// MARK: - Muse-Style Persona Studio Sheet (Preview / Confirm / Static Upload / Multi-Frame Animation)

struct AmberPersonaStudioSheet: View {
    let sharedSettings: IOSSharedSettingsStore
    @Bindable var store = AmberPersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var isImportingAvatarFile = false
    @State private var referencePickerItems: [PhotosPickerItem] = []
    @State private var showingPromptEditor = false

    private var hasImageGenConfigured: Bool {
        store.hasConfiguredImageGenerationProvider(sharedSettings: sharedSettings)
    }

    private var activeStatusSummary: String {
        if let kind = store.pendingPreviewKind {
            switch kind {
            case .staticImage:
                return "预览中：新静态形象（确认后生效）"
            case .multiFrameAnimation:
                return "预览中：\(store.pendingPreviewAnimationFrames.count) 帧微动画（确认后生效）"
            }
        }
        switch store.preset {
        case .amberFox:
            return "当前：琥珀灵狐（默认神态联动）"
        case .amberCrystal:
            return "当前：琥珀星晶"
        case .customPortrait:
            if store.hasActiveMultiFrameAnimation {
                return "当前：自定义 \(store.customAnimationFrames.count) 帧微动画循环"
            } else if store.customAvatarImage != nil {
                return "当前：自定义静态形象"
            } else {
                return "当前：自定义形象（未上传，回退默认灵狐）"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heroAndPresetCard
                    referenceImagesSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle(IOSAppLocalization.string("形象设定", defaultValue: "形象设定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.canResetToDefault {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(IOSAppLocalization.string("恢复默认", defaultValue: "恢复默认")) {
                            store.resetToDefault()
                        }
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground2)
                        .accessibilityIdentifier("chat.persona.resetDefaultButton")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .accessibilityIdentifier("chat.persona.doneButton")
                }
            }
            .onChange(of: avatarPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        _ = store.stageUploadedAvatarDataForPreview(data)
                    }
                    avatarPickerItem = nil
                }
            }
            .fileImporter(
                isPresented: $isImportingAvatarFile,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessed { url.stopAccessingSecurityScopedResource() }
                    }
                    if let data = try? Data(contentsOf: url) {
                        _ = store.stageUploadedAvatarDataForPreview(data)
                    } else {
                        store.stageUploadedAvatarDataForPreview(Data())
                    }
                case .failure(let error):
                    store.clearError()
                    _ = error
                }
            }
            .onChange(of: referencePickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            _ = store.addReferenceImage(image)
                        }
                    }
                    referencePickerItems = []
                }
            }
        }
    }

    private var heroAndPresetCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                AmberAgentPersonaMedallionView(
                    mood: .idle,
                    diameter: 112,
                    storeOverride: store,
                    showStagedPreview: true
                )
                .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)

                Text(activeStatusSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(store.hasPendingPreview ? AmberTheme.accent : AmberTheme.foreground2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4.5)
                    .background(
                        (store.hasPendingPreview ? AmberTheme.accent.opacity(0.12) : AmberTheme.surface),
                        in: Capsule(style: .continuous)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(
                                store.hasPendingPreview ? AmberTheme.accent.opacity(0.35) : AmberTheme.borderSoft,
                                lineWidth: 0.7
                            )
                    }
                    .accessibilityIdentifier("chat.persona.statusSummary")

                if store.hasPendingPreview {
                    pendingPreviewConfirmationCard
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
            .background(
                AmberTheme.background.opacity(0.65),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
            }

            Picker("形象风格", selection: $store.preset) {
                ForEach(AmberPersonaPreset.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            // Primary Row: Equal-width Photo Library & File Import actions
            HStack(spacing: 10) {
                PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                    Label("相册选图", systemImage: "photo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(AmberTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.persona.uploadButton")

                Button {
                    isImportingAvatarFile = true
                } label: {
                    Label("文件导入", systemImage: "folder")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(AmberTheme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AmberTheme.border, lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.persona.importFileButton")
            }

            // Secondary Row: Equal-width AI Multi-frame & Single Portrait actions
            if store.isGeneratingAvatar {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.generationProgressText ?? "正在生成形象…")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        Text("可关闭面板继续聊天，完成后回来确认应用")
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    Spacer(minLength: 4)
                    Button("取消") {
                        store.cancelAvatarGeneration()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AmberTheme.accentRed.opacity(0.10), in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.persona.cancelGenerationButton")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AmberTheme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        _ = store.startGenerateAnimationFramesTask(sharedSettings: sharedSettings, frameCount: 3)
                    } label: {
                        Label("生成 3 帧微动画", systemImage: "sparkles.tv")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(AmberTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(AmberTheme.accent.opacity(0.28), lineWidth: 0.8)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.persona.generateAnimationButton")

                    Button {
                        Task {
                            await store.generateAvatarWithAI(sharedSettings: sharedSettings)
                        }
                    } label: {
                        Label("AI 生成单张", systemImage: "wand.and.stars")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(AmberTheme.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.persona.generateButton")
                }
            }

            // Single unified footer bar: deduplicated model notice/error on the left, prompt toggle on the right
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let error = store.lastGenerationError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.accentRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("chat.persona.errorText")
                } else if !hasImageGenConfigured {
                    Text("未配置辅助生图模型时，可直接从相册或文件换图")
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("chat.persona.unconfiguredHint")
                } else {
                    Text("AI 生图将结合下方描述词与参考图")
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        showingPromptEditor.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(showingPromptEditor ? "收起描述词" : "生成描述词")
                        Image(systemName: showingPromptEditor ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground2)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)

            if showingPromptEditor {
                TextField("描述外貌与画风…", text: $store.personaStylePrompt, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(2...3)
                    .padding(10)
                    .background(AmberTheme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                    }
            }
        }
        .padding(16)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private var pendingPreviewConfirmationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.pendingPreviewKind == .multiFrameAnimation, store.pendingPreviewAnimationFrames.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(store.pendingPreviewAnimationFrames.enumerated()), id: \.offset) { index, frame in
                        VStack(spacing: 3) {
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(AmberTheme.borderSoft, lineWidth: 0.6)
                                }
                            Text("第\(index + 1)帧")
                                .font(.system(size: 10))
                                .foregroundStyle(AmberTheme.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                Button {
                    store.discardPendingPreview()
                } label: {
                    Text("取消预览")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(AmberTheme.surface, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(AmberTheme.border, lineWidth: 0.7)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.persona.discardPreviewButton")

                Button {
                    _ = store.confirmPendingPreview()
                } label: {
                    Text(store.pendingPreviewKind == .multiFrameAnimation ? "确认应用动画" : "确认使用形象")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(AmberTheme.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.persona.confirmPreviewButton")
            }
        }
        .padding(10)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.40), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.persona.previewConfirmationCard")
    }

    private var referenceImagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("形象参考图")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                Spacer()
                Text("\(store.referenceItems.count)/4")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AmberTheme.muted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.referenceItems) { item in
                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 4) {
                                if let uiImage = store.loadReferenceImage(for: item) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 68, height: 68)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(AmberTheme.surface2)
                                        .frame(width: 68, height: 68)
                                }
                                Text(item.label)
                                    .font(.caption2)
                                    .foregroundStyle(AmberTheme.foreground2)
                                    .lineLimit(1)
                            }

                            Button {
                                store.removeReference(id: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white, Color.black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }

                    if store.referenceItems.count < 4 {
                        PhotosPicker(
                            selection: $referencePickerItems,
                            maxSelectionCount: max(1, 4 - store.referenceItems.count),
                            matching: .images
                        ) {
                            VStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(AmberTheme.muted)
                                Text("添加")
                                    .font(.caption2)
                                    .foregroundStyle(AmberTheme.muted)
                            }
                            .frame(width: 68, height: 68)
                            .background(
                                AmberTheme.background.opacity(0.65),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AmberTheme.border, style: StrokeStyle(lineWidth: 0.9, dash: [4, 3]))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.persona.addReferenceButton")
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()

            Toggle(isOn: $store.autoBindReferenceInImageGen) {
                Text("生图时自动附带参考图")
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
            }
            .tint(AmberTheme.accent)
        }
        .padding(16)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }
}
