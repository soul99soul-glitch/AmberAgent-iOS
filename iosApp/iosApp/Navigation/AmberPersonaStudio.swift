import PhotosUI
import SwiftUI
import UIKit
@preconcurrency import Shared

// MARK: - Amber Personal Agent Persona Model & Store (Muse-Style Generate / Upload / Reference Images)

enum AmberPersonaPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Amber's signature original mascot: Warm Amber Kitsune / Spirit Fox with expressive ears & eyes.
    case amberFox = "amber_fox"
    /// Luminous faceted amber gem spirit with warm inner core.
    case amberCrystal = "amber_crystal"
    /// User-uploaded or AI-generated Muse-style custom portrait.
    case customPortrait = "custom_portrait"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .amberFox: "琥珀灵狐"
        case .amberCrystal: "琥珀星晶"
        case .customPortrait: "自定义 / AI 肖像"
        }
    }

    var subtitle: String {
        switch self {
        case .amberFox: "Amber 原生灵狐形象 · 随待命/思考/提醒切换神态"
        case .amberCrystal: "温润琥珀几何晶核 · 极简克制"
        case .customPortrait: "像 Muse 一样上传或 AI 生成专属个人 Agent 形象"
        }
    }
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
        didSet { defaults.set(preset.rawValue, forKey: Keys.preset) }
    }

    var personaStylePrompt: String {
        didSet { defaults.set(personaStylePrompt, forKey: Keys.stylePrompt) }
    }

    var autoBindReferenceInImageGen: Bool {
        didSet { defaults.set(autoBindReferenceInImageGen, forKey: Keys.autoBindRef) }
    }

    private(set) var customAvatarImage: UIImage?
    private(set) var referenceItems: [AmberPersonaReferenceItem] = []
    private(set) var isGeneratingAvatar = false
    private(set) var lastGenerationError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let baseDirectory: URL

    private enum Keys {
        static let preset = "app.amber.ios.persona.preset"
        static let stylePrompt = "app.amber.ios.persona.stylePrompt"
        static let autoBindRef = "app.amber.ios.persona.autoBindRef"
        static let references = "app.amber.ios.persona.references"
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

    @discardableResult
    func addReferenceImage(from data: Data, label: String? = nil) -> AmberPersonaReferenceItem? {
        guard let image = UIImage(data: data) else { return nil }
        return addReferenceImage(image, label: label)
    }

    func clearError() {
        lastGenerationError = nil
    }

    func saveCustomAvatar(_ image: UIImage) {
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let downscaled = Self.downscale(image, maxDimension: 512)
        guard let data = downscaled.pngData() else { return }
        let url = baseDirectory.appendingPathComponent("avatar.png")
        try? data.write(to: url, options: .atomic)
        customAvatarImage = downscaled
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

    func generateAvatarWithAI(sharedSettings: IOSSharedSettingsStore) async {
        let prompt = personaStylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            lastGenerationError = "请先输入 Amber 的形象描述词"
            return
        }
        isGeneratingAvatar = true
        lastGenerationError = nil
        defer { isGeneratingAvatar = false }

        let fullPrompt = """
        Personal AI agent avatar portrait for Amber: \(prompt). Centered circular-friendly bust composition, expressive eyes, warm editorial illustration quality, clean background.
        """
        let request = IOSImageGenerationRequest(
            prompt: fullPrompt,
            model: "gpt-image-1",
            aspectRatio: .square,
            count: 1,
            style: "illustration",
            source: "persona_studio",
            sourceImageURL: autoBindReferenceInImageGen ? primaryReferenceDataURL() : nil
        )

        let snapshot = sharedSettings.snapshot
        if let model = snapshot.findModelById(uuid: snapshot.imageGenerationModelId),
           let provider = ChatProviderConfiguration.provider(for: model, providers: snapshot.providers),
           provider.enabled,
           let apiKey = (provider as? ProviderSetting.OpenAI)?.apiKey ?? (provider as? ProviderSetting.Google)?.apiKey,
           !apiKey.isEmpty {
            let baseURL = (provider as? ProviderSetting.OpenAI)?.baseUrl ?? "https://api.openai.com/v1"
            do {
                let record = try await IOSImageGenerationRepository.shared.generate(
                    request: IOSImageGenerationRequest(
                        prompt: fullPrompt,
                        model: model.modelId,
                        aspectRatio: .square,
                        count: 1,
                        style: "illustration",
                        source: "persona_studio"
                    ),
                    apiKey: apiKey,
                    baseURL: baseURL
                )
                if let firstPath = record.files.first?.path,
                   let data = try? Data(contentsOf: URL(fileURLWithPath: firstPath)),
                   let image = UIImage(data: data) {
                    saveCustomAvatar(image)
                    return
                }
            } catch {
                lastGenerationError = error.localizedDescription
                return
            }
        } else {
            lastGenerationError = "请先在「设置 → 默认模型 → 辅助任务」中配置生图模型，或直接从相册上传形象与参考图。"
        }
    }

    private func reloadAvatarFromDisk() {
        let url = baseDirectory.appendingPathComponent("avatar.png")
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            customAvatarImage = image
        }
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

// MARK: - Amber Personal Agent Medallion View (Supports Amber Fox, Amber Crystal & Custom/Muse Portrait)

enum AmberAgentPersonaMood: Equatable, Sendable {
    case idle
    case working
    case alert
}

struct AmberAgentPersonaMedallionView: View {
    let mood: AmberAgentPersonaMood
    var diameter: CGFloat = 54
    var presetOverride: AmberPersonaPreset? = nil
    var accentOverride: Color? = nil

    private var store: AmberPersonaStore { AmberPersonaStore.shared }

    private var activePreset: AmberPersonaPreset {
        presetOverride ?? store.preset
    }

    private var accentColor: Color {
        if let accentOverride { return accentOverride }
        return mood == .alert ? AmberTheme.accentRed : AmberTheme.accent
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AmberTheme.elevatedPanel)
                .overlay {
                    RadialGradient(
                        colors: [
                            accentColor.opacity(mood == .working ? 0.18 : 0.10),
                            Color.clear,
                        ],
                        center: .init(x: 0.5, y: 0.45),
                        startRadius: 2,
                        endRadius: diameter * 0.48
                    )
                    .clipShape(Circle())
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            mood == .alert ? AmberTheme.accentRed.opacity(0.55) : AmberTheme.border,
                            lineWidth: mood == .working ? 1.1 : 0.85
                        )
                }
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)

            switch activePreset {
            case .customPortrait:
                if let uiImage = store.customAvatarImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: diameter - 5, height: diameter - 5)
                        .clipShape(Circle())
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

    private var amberFoxCanvas: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w * 0.5
            let cy = h * 0.49

            // 1. Left & Right Kitsune Ears (Warm Amber Terracotta + Inner Cream)
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

            // Inner ear triangles (Warm Paper / Cream)
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

            // 2. Fox Head Silhouette (Warm Amber Top + Soft Cream Cheeks)
            let headW = w * 0.48
            let headH = h * 0.38
            let headRect = CGRect(x: cx - headW * 0.5, y: cy - headH * 0.48, width: headW, height: headH)
            context.fill(
                Path(roundedRect: headRect, cornerRadius: headH * 0.46, style: .continuous),
                with: .color(accentColor)
            )

            let cheekW = w * 0.38
            let cheekH = h * 0.20
            let cheekRect = CGRect(x: cx - cheekW * 0.5, y: cy - cheekH * 0.10, width: cheekW, height: cheekH)
            context.fill(
                Path(roundedRect: cheekRect, cornerRadius: cheekH * 0.48, style: .continuous),
                with: .color(AmberTheme.background)
            )

            // 3. Expressive Eyes (No decorative reading glasses or floating 4-point spark)
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

            // Tiny nose dot
            let noseR = max(1.2, w * 0.024)
            context.fill(
                Path(ellipseIn: CGRect(x: cx - noseR, y: cy + h * 0.03 - noseR, width: noseR * 2, height: noseR * 2)),
                with: .color(AmberTheme.foreground)
            )
        }
        .frame(width: diameter, height: diameter)
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
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Muse-Style Persona Studio Sheet (Generate / Upload / Reference Images)

struct AmberPersonaStudioSheet: View {
    let sharedSettings: IOSSharedSettingsStore
    @Bindable var store = AmberPersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var referencePickerItems: [PhotosPickerItem] = []
    @State private var showingPromptEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heroAndPresetCard
                    referenceImagesSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle(IOSAppLocalization.string("形象设定", defaultValue: "形象设定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                }
            }
            .onChange(of: avatarPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        store.saveCustomAvatar(image)
                    }
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
        VStack(spacing: 18) {
            AmberAgentPersonaMedallionView(mood: .idle, diameter: 88)
                .padding(.top, 6)

            Picker("形象风格", selection: $store.preset) {
                ForEach(AmberPersonaPreset.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await store.generateAvatarWithAI(sharedSettings: sharedSettings)
                    }
                } label: {
                    Text(store.isGeneratingAvatar ? "正在生成…" : "AI 生成形象")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AmberTheme.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.isGeneratingAvatar)
                .accessibilityIdentifier("chat.persona.generateButton")

                PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                    Text("从相册上传")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AmberTheme.background, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(AmberTheme.border, lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.persona.uploadButton")
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    showingPromptEditor.toggle()
                }
            } label: {
                Text(showingPromptEditor ? "收起生成描述词" : "调整生成描述词")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            .buttonStyle(.plain)

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

            if let error = store.lastGenerationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
            }
        }
        .padding(18)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private var referenceImagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("形象参考图")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
                Spacer()
                Text("\(store.referenceItems.count)/4")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AmberTheme.muted)
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.referenceItems) { item in
                            ZStack(alignment: .topTrailing) {
                                VStack(spacing: 5) {
                                    if let uiImage = store.loadReferenceImage(for: item) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 78, height: 78)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    } else {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AmberTheme.surface2)
                                            .frame(width: 78, height: 78)
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
                                        .font(.system(size: 16))
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
                                VStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .regular))
                                        .foregroundStyle(AmberTheme.muted)
                                    Text("添加")
                                        .font(.caption2)
                                        .foregroundStyle(AmberTheme.muted)
                                }
                                .frame(width: 78, height: 78)
                                .background(
                                    AmberTheme.background,
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
}
