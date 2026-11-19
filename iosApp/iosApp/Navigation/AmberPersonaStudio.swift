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
        case .customPortrait: "上传静态形象图，或生成待机/忙碌/等待/异常四段动作"
        }
    }
}

enum AmberPersonaPendingPreviewKind: String, Equatable, Sendable {
    case staticImage
    case multiFrameAnimation
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
    /// Per-state frame clips; legacy single-sequence data lands in every state via the manifest.
    private(set) var customAnimationClips: [AmberAgentPersonaMood: [UIImage]] = [:]
    private(set) var isMultiFrameAnimationActive = false {
        didSet { defaults.set(isMultiFrameAnimationActive, forKey: Keys.multiFrameActive) }
    }
    private(set) var animationFrameIntervalMs: Int = 550
    private(set) var pendingPreviewKind: AmberPersonaPendingPreviewKind?
    private(set) var pendingPreviewImage: UIImage?
    private(set) var pendingPreviewAnimationFrames: [UIImage] = []
    private(set) var pendingPreviewClips: [AmberAgentPersonaMood: [UIImage]] = [:]
    private(set) var pendingSpriteSheetLayout: AmberPersonaSpriteSheetLayout?
    private(set) var referenceItems: [AmberPersonaReferenceItem] = []
    private(set) var isGeneratingAvatar = false
    private(set) var generationProgressText: String?
    private(set) var lastGenerationError: String?

    @ObservationIgnored var staticGeneratorOverrideForTesting: ((_ prompt: String, _ sourceImageDataURL: String?) async throws -> UIImage)?
    @ObservationIgnored var spriteSheetGeneratorOverrideForTesting: ((_ prompt: String, _ sourceImageDataURL: String?) async throws -> UIImage)?
    @ObservationIgnored private var activeGenerationTask: Task<Void, Never>?
    @ObservationIgnored private var referenceImageCache: [String: UIImage] = [:]

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
        preset == .customPortrait && isMultiFrameAnimationActive && !customAnimationClips.isEmpty
    }

    var canResetToDefault: Bool {
        preset != .amberFox || customAvatarImage != nil || !customAnimationClips.isEmpty || hasPendingPreview
    }

    /// Frames for one state of the active (or staged) personality.
    func frames(for mood: AmberAgentPersonaMood) -> [UIImage] {
        guard let clip = customAnimationClips[mood], clip.count > 1 else { return [] }
        return clip
    }

    /// Frames for one state of the staged preview; an empty clip falls back to the idle clip.
    func pendingFrames(for mood: AmberAgentPersonaMood) -> [UIImage] {
        guard pendingPreviewKind == .multiFrameAnimation else { return [] }
        if let clip = pendingPreviewClips[mood], clip.count > 1 { return clip }
        return pendingPreviewClips[.idle] ?? []
    }

    /// Number of states that carry their own animation (1 for legacy single-sequence data).
    var animatedClipCount: Int {
        AmberAgentPersonaMood.allCases.filter { (customAnimationClips[$0]?.count ?? 0) > 1 }.count
    }

    var pendingAnimatedClipCount: Int {
        AmberAgentPersonaMood.allCases.filter { (pendingPreviewClips[$0]?.count ?? 0) > 1 }.count
    }

    var totalFrameCount: Int {
        AmberAgentPersonaMood.allCases.reduce(0) { $0 + (customAnimationClips[$1]?.count ?? 0) }
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
    /// A single sequence is persisted for every state (legacy shape).
    @discardableResult
    func stageAnimationFramesForPreview(_ frames: [UIImage]) -> Bool {
        let normalized = frames.map { Self.downscale($0, maxDimension: 512) }
        guard normalized.count >= 2 else { return false }
        var uniform: [AmberAgentPersonaMood: [UIImage]] = [:]
        for mood in AmberAgentPersonaMood.allCases { uniform[mood] = normalized }
        return stageStateClipsForPreview(uniform)
    }

    /// Stages four per-state animation clips in preview state for user confirmation.
    /// Missing or single-frame states inherit the idle clip so every state still animates.
    @discardableResult
    func stageStateClipsForPreview(_ clips: [AmberAgentPersonaMood: [UIImage]]) -> Bool {
        let idle = (clips[.idle] ?? []).map { Self.downscale($0, maxDimension: 512) }
        let fallback = idle.count >= 2
            ? idle
            : clips.values.first(where: { $0.count >= 2 })?.map { Self.downscale($0, maxDimension: 512) }
        guard let fallback, fallback.count >= 2 else { return false }

        var normalized: [AmberAgentPersonaMood: [UIImage]] = [:]
        for mood in AmberAgentPersonaMood.allCases {
            let clip = (clips[mood] ?? []).map { Self.downscale($0, maxDimension: 512) }
            normalized[mood] = clip.count >= 2 ? clip : fallback
        }
        pendingPreviewClips = normalized
        pendingPreviewAnimationFrames = normalized[.idle] ?? fallback
        pendingPreviewImage = pendingPreviewAnimationFrames.first
        pendingPreviewKind = .multiFrameAnimation
        lastGenerationError = nil
        return true
    }

    /// Recognises a sprite sheet dropped in through "文件导入"; returns `false` for ordinary portraits.
    @discardableResult
    func stageImportedSpriteSheet(_ image: UIImage) -> Bool {
        let layout: AmberPersonaSpriteSheetLayout
        if let detected = AmberPersonaSpriteSheetSlicer.detectLayout(for: image, requireContentEvidence: true) {
            layout = detected
        } else if let trimmed = Self.trimTransparentGutter(image),
                  let detected = AmberPersonaSpriteSheetSlicer.detectLayout(for: trimmed, requireContentEvidence: false),
                  AmberPersonaSpriteSheetSlicer.isUsable(AmberPersonaSpriteSheetSlicer.slices(from: trimmed, layout: detected)) {
            // Photos export sometimes pads the sheet with a transparent gutter; retry on the trimmed canvas.
            let clips = AmberPersonaSpriteSheetSlicer.slices(from: trimmed, layout: detected)
            guard stageStateClipsForPreview(clips) else { return false }
            pendingSpriteSheetLayout = detected
            return true
        } else {
            return false
        }
        let clips = AmberPersonaSpriteSheetSlicer.slices(from: image, layout: layout)
        guard AmberPersonaSpriteSheetSlicer.isUsable(clips), stageStateClipsForPreview(clips) else { return false }
        pendingSpriteSheetLayout = layout
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
            saveStateClips(pendingPreviewClips)
            discardPendingPreview()
            return true
        }
    }

    /// Cancels the staged preview without touching the currently active avatar or persisted files.
    func discardPendingPreview() {
        pendingPreviewKind = nil
        pendingPreviewImage = nil
        pendingPreviewAnimationFrames = []
        pendingPreviewClips = [:]
        pendingSpriteSheetLayout = nil
    }

    /// Resets the persona back to the default preset (`amberFox`) and clears custom static/animated portrait state.
    func resetToDefault(preset defaultPreset: AmberPersonaPreset = .amberFox) {
        cancelAvatarGeneration()
        discardPendingPreview()
        lastGenerationError = nil
        removeSavedAnimationFiles()
        try? fileManager.removeItem(at: baseDirectory.appendingPathComponent("avatar.png"))
        customAvatarImage = nil
        customAnimationClips = [:]
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
        customAnimationClips = [:]
        isMultiFrameAnimationActive = false
        customAvatarImage = downscaled
        preset = .customPortrait
    }

    /// Immediately persists per-state clips (`anim_<state>_<index>.png`) and activates multi-frame mode.
    func saveStateClips(_ clips: [AmberAgentPersonaMood: [UIImage]], frameIntervalMs: Int = 550) {
        let idle = (clips[.idle] ?? []).map { Self.downscale($0, maxDimension: 512) }
        let fallback = idle.count >= 2
            ? idle
            : clips.values.first(where: { $0.count >= 2 })?.map { Self.downscale($0, maxDimension: 512) }
        guard let fallback, fallback.count >= 2 else { return }

        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        removeSavedAnimationFiles()

        var savedClips: [String: [String]] = [:]
        var savedImages: [AmberAgentPersonaMood: [UIImage]] = [:]
        for mood in AmberAgentPersonaMood.allCases {
            let frames = (clips[mood] ?? []).map { Self.downscale($0, maxDimension: 512) }
            let clip = frames.count >= 2 ? frames : fallback
            var fileNames: [String] = []
            var images: [UIImage] = []
            for (index, frame) in clip.enumerated() {
                let fileName = "anim_\(mood.clipKey)_\(index).png"
                guard let data = frame.pngData() else { continue }
                do {
                    try data.write(to: baseDirectory.appendingPathComponent(fileName), options: .atomic)
                    fileNames.append(fileName)
                    images.append(frame)
                } catch {
                    continue
                }
            }
            guard images.count >= 2 else { continue }
            savedClips[mood.clipKey] = fileNames
            savedImages[mood] = images
        }
        guard let idleClip = savedImages[AmberAgentPersonaMood.idle],
              let idleNames = savedClips[AmberAgentPersonaMood.idle.clipKey],
              idleNames.count >= 2 else {
            return
        }
        if let firstData = idleClip[0].pngData() {
            try? firstData.write(to: baseDirectory.appendingPathComponent("avatar.png"), options: .atomic)
        }
        let manifest = AmberPersonaAnimationManifest(
            clips: savedClips,
            frameIntervalMs: max(300, frameIntervalMs),
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        if let manifestData = try? JSONEncoder().encode(manifest) {
            try? manifestData.write(
                to: baseDirectory.appendingPathComponent("animation_manifest.json"),
                options: .atomic
            )
        }
        customAvatarImage = idleClip[0]
        customAnimationClips = savedImages
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
            referenceImageCache[fileName] = downscaled
            referenceItems.append(item)
            persistReferences()
            return item
        } catch {
            return nil
        }
    }

    func removeReference(id: String) {
        guard let item = referenceItems.first(where: { $0.id == id }) else { return }
        referenceImageCache.removeValue(forKey: item.fileName)
        let url = baseDirectory.appendingPathComponent(item.fileName)
        try? fileManager.removeItem(at: url)
        referenceItems.removeAll { $0.id == id }
        persistReferences()
    }

    func loadReferenceImage(for item: AmberPersonaReferenceItem) -> UIImage? {
        if let cached = referenceImageCache[item.fileName] {
            return cached
        }
        let url = baseDirectory.appendingPathComponent(item.fileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = UIImage(data: data) else { return nil }
        referenceImageCache[item.fileName] = decoded
        return decoded
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
        if staticGeneratorOverrideForTesting != nil || spriteSheetGeneratorOverrideForTesting != nil {
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
    func startGenerateAnimationFramesTask(sharedSettings: IOSSharedSettingsStore) -> Task<Void, Never> {
        activeGenerationTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateAnimationFramesWithAI(sharedSettings: sharedSettings)
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

    /// One image request → 4×4 sprite sheet → four 4-frame state clips, staged in preview.
    func generateAnimationFramesWithAI(sharedSettings: IOSSharedSettingsStore) async {
        let prompt = personaStylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            lastGenerationError = "请先输入 Amber 的形象描述词"
            return
        }

        isGeneratingAvatar = true
        generationProgressText = "正在生成四段动作精灵图…"
        lastGenerationError = nil
        defer {
            isGeneratingAvatar = false
            generationProgressText = nil
        }

        let sourceURL = sourceImageDataURLForGeneration()
        let sheetPrompt = AmberPersonaSpriteSheetPrompt.make(stylePrompt: prompt)

        if let override = spriteSheetGeneratorOverrideForTesting {
            do {
                let sheet = try await override(sheetPrompt, sourceURL)
                try Task.checkCancellation()
                applyGeneratedSpriteSheet(sheet)
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
                    prompt: sheetPrompt,
                    model: credentials.modelId,
                    aspectRatio: .square,
                    count: 1,
                    style: "illustration",
                    source: "persona_studio_sprite_sheet",
                    sourceImageURL: sourceURL
                ),
                apiKey: credentials.apiKey,
                baseURL: credentials.baseURL
            )
            try Task.checkCancellation()
            guard let firstPath = record.files.first?.path,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: firstPath)),
                  let sheet = UIImage(data: data) else {
                lastGenerationError = "生图未返回有效的精灵图，原有形象已保留。"
                return
            }
            applyGeneratedSpriteSheet(sheet)
        } catch is CancellationError {
            return
        } catch {
            lastGenerationError = error.localizedDescription
        }
    }

    /// Slices our own generated sheet. The request pins the geometry, so no content evidence is required;
    /// a sheet that lands on the wrong grid keeps the previous avatar and reports it honestly.
    private func applyGeneratedSpriteSheet(_ sheet: UIImage) {
        guard let layout = AmberPersonaSpriteSheetSlicer.detectLayout(for: sheet, requireContentEvidence: false) else {
            lastGenerationError = "生成图未能按 4×4 网格切分，原有形象已保留，可重试或直接导入精灵图。"
            return
        }
        let clips = AmberPersonaSpriteSheetSlicer.slices(from: sheet, layout: layout)
        guard AmberPersonaSpriteSheetSlicer.isUsable(clips), stageStateClipsForPreview(clips) else {
            lastGenerationError = "生成图未切出可用动作帧，原有形象已保留，可重试或直接导入精灵图。"
            return
        }
        pendingSpriteSheetLayout = layout
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
            var loadedClips: [AmberAgentPersonaMood: [UIImage]] = [:]
            for mood in AmberAgentPersonaMood.allCases {
                var frames: [UIImage] = []
                for fileName in manifest.clip(for: mood) {
                    let frameURL = baseDirectory.appendingPathComponent(fileName)
                    if let frameData = try? Data(contentsOf: frameURL),
                       let frameImage = UIImage(data: frameData) {
                        frames.append(frameImage)
                    }
                }
                if frames.count >= 2 { loadedClips[mood] = frames }
            }
            if let idleClip = loadedClips[.idle] ?? loadedClips.values.first {
                for mood in AmberAgentPersonaMood.allCases where loadedClips[mood] == nil {
                    loadedClips[mood] = idleClip
                }
                customAnimationClips = loadedClips
                animationFrameIntervalMs = max(300, manifest.frameIntervalMs)
                if customAvatarImage == nil {
                    customAvatarImage = idleClip.first
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
            for fileName in manifest.allFrameFileNames {
                try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(fileName))
            }
        }
        // Legacy single-sequence files from builds that predate per-state clips.
        for index in 0..<8 {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent("anim_frame_\(index).png"))
        }
        for mood in AmberAgentPersonaMood.allCases {
            for index in 0..<8 {
                try? fileManager.removeItem(at: baseDirectory.appendingPathComponent("anim_\(mood.clipKey)_\(index).png"))
            }
        }
        try? fileManager.removeItem(at: manifestURL)
    }

    private func persistReferences() {
        if let data = try? JSONEncoder().encode(referenceItems) {
            defaults.set(data, forKey: Keys.references)
        }
    }

    /// Crops fully transparent gutters that photo exports add around a sprite sheet.
    static func trimTransparentGutter(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 96
        guard let pixels = rasterPixels(cgImage, side: side) else { return nil }

        func columnHasContent(_ x: Int) -> Bool {
            for y in 0..<side where pixels[(y * side + x) * 4 + 3] >= 8 { return true }
            return false
        }
        func rowHasContent(_ y: Int) -> Bool {
            for x in 0..<side where pixels[(y * side + x) * 4 + 3] >= 8 { return true }
            return false
        }

        let columns = (0..<side).filter(columnHasContent)
        let rows = (0..<side).filter(rowHasContent)
        guard let minX = columns.first, let maxX = columns.last,
              let minY = rows.first, let maxY = rows.last else { return nil }
        guard minX > 0 || minY > 0 || maxX < side - 1 || maxY < side - 1 else { return nil }

        let scaleX = CGFloat(cgImage.width) / CGFloat(side)
        let scaleY = CGFloat(cgImage.height) / CGFloat(side)
        let rect = CGRect(
            x: CGFloat(minX) * scaleX,
            y: CGFloat(minY) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY
        ).integral
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func rasterPixels(_ cgImage: CGImage, side: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = bytes.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        }) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return bytes
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

// MARK: - Muse-Style Persona Studio Sheet (Preview / Confirm / Static Upload / Multi-Frame Animation)

/// 形象编辑内容。外层「形象人设」面板以嵌入方式复用同一份内容（`showsAvatar: false`），
/// 由外层唯一头像承载预览，不再 present 第二层 sheet；独立入口继续用 `AmberPersonaStudioSheet`。
struct AmberPersonaStudioContent: View {
    let sharedSettings: IOSSharedSettingsStore
    @Binding var previewMood: AmberAgentPersonaMood
    /// 独立 sheet 自带头像；嵌入外层面板时不重复绘制头像。
    var showsAvatar: Bool = true
    /// 嵌入态把「恢复默认」放进工具区，不与面板标题争视觉层级。
    var showsInlineReset: Bool = false
    @Bindable var store = AmberPersonaStore.shared

    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var isImportingAvatarFile = false
    @State private var referencePickerItems: [PhotosPickerItem] = []
    @State private var showingPromptEditor = false

    init(
        sharedSettings: IOSSharedSettingsStore,
        previewMood: Binding<AmberAgentPersonaMood>,
        showsAvatar: Bool = true,
        showsInlineReset: Bool = false,
        store: AmberPersonaStore = AmberPersonaStore.shared
    ) {
        self.sharedSettings = sharedSettings
        self._previewMood = previewMood
        self.showsAvatar = showsAvatar
        self.showsInlineReset = showsInlineReset
        self._store = Bindable(wrappedValue: store)
    }

    /// File imports that are 4×4 / Codex-Pets 8×9 sprite sheets become four state clips;
    /// any other image stays an ordinary static portrait.
    private func stageImportedImageData(_ data: Data) {
        if let image = UIImage(data: data), store.stageImportedSpriteSheet(image) {
            previewMood = .idle
            return
        }
        _ = store.stageUploadedAvatarDataForPreview(data)
    }

    private var hasImageGenConfigured: Bool {
        store.hasConfiguredImageGenerationProvider(sharedSettings: sharedSettings)
    }

    private var activeStatusSummary: String {
        if let kind = store.pendingPreviewKind {
            switch kind {
            case .staticImage:
                return "预览中：新静态形象（确认后生效）"
            case .multiFrameAnimation:
                return "预览中：四段动作动画（确认后生效）"
            }
        }
        switch store.preset {
        case .amberFox:
            return "当前：琥珀灵狐（默认神态联动）"
        case .amberCrystal:
            return "当前：琥珀星晶"
        case .customPortrait:
            if store.hasActiveMultiFrameAnimation {
                return store.animatedClipCount > 1
                    ? "当前：自定义四段动作动画循环"
                    : "当前：自定义 \(store.totalFrameCount) 帧动画循环"
            } else if store.customAvatarImage != nil {
                return "当前：自定义静态形象"
            } else {
                return "当前：自定义形象（未上传，回退默认灵狐）"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroAndPresetCard
            referenceImagesSection
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
                        stageImportedImageData(data)
                    } else {
                        _ = store.stageUploadedAvatarDataForPreview(Data())
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

    private var heroAndPresetCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                if showsAvatar {
                    AmberAgentPersonaMedallionView(
                        mood: store.pendingPreviewKind == .multiFrameAnimation ? previewMood : .idle,
                        diameter: 112,
                        storeOverride: store,
                        showStagedPreview: true
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
                }

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
                        _ = store.startGenerateAnimationFramesTask(sharedSettings: sharedSettings)
                    } label: {
                        Label("生成多帧动画", systemImage: "sparkles.tv")
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

            // 嵌入态：恢复默认降为主操作下方的一行弱控件，不与面板标题争层级。
            if showsInlineReset, store.canResetToDefault {
                Button {
                    store.resetToDefault()
                } label: {
                    Text(IOSAppLocalization.string("恢复默认", defaultValue: "恢复默认"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(AmberTheme.background.opacity(0.55), in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous).stroke(AmberTheme.borderSoft, lineWidth: 0.7)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.persona.resetDefaultButton")
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
            if store.pendingPreviewKind == .multiFrameAnimation, store.pendingAnimatedClipCount >= 1 {
                // Lightweight state switcher: preview one of the four clips before applying.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(AmberAgentPersonaMood.allCases) { mood in
                            let isSelected = previewMood == mood
                            Button {
                                previewMood = mood
                            } label: {
                                Text(mood.displayTitle)
                                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? AmberTheme.accentInk : AmberTheme.foreground2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        isSelected ? AmberTheme.accent : AmberTheme.background.opacity(0.7),
                                        in: Capsule(style: .continuous)
                                    )
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .stroke(
                                                isSelected ? Color.clear : AmberTheme.borderSoft,
                                                lineWidth: 0.7
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chat.persona.previewMood.\(mood.clipKey)")
                        }
                    }
                }

                HStack(spacing: 8) {
                    ForEach(Array(store.pendingFrames(for: previewMood).enumerated()), id: \.offset) { index, frame in
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

/// 独立「形象设定」面板：单层 sheet 入口（顶部栏直连、双栏抽屉），自带头像与唯一完成出口。
struct AmberPersonaStudioSheet: View {
    let sharedSettings: IOSSharedSettingsStore
    /// 保留可注入的 store，供快照/定点测试验证暂存预览。
    var store: AmberPersonaStore = AmberPersonaStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var previewMood: AmberAgentPersonaMood = .idle

    var body: some View {
        NavigationStack {
            ScrollView {
                AmberPersonaStudioContent(
                    sharedSettings: sharedSettings,
                    previewMood: $previewMood,
                    store: store
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .amberSmoothSheetScrollDismiss()
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
        }
    }
}
