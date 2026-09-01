import Contacts
import ContactsUI
import Foundation
import Observation
import PhotosUI
import Shared
import SwiftUI
import UniformTypeIdentifiers

#if canImport(JournalingSuggestions)
@preconcurrency import JournalingSuggestions
#endif

enum IOSPersonalContextPickerKind: String, Sendable {
    case contacts
    case photos
    case journaling
}

struct IOSPersonalContextRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let toolName: String
    let kind: IOSPersonalContextPickerKind
    let maxSelectionCount: Int
}

struct IOSSelectedContact: Equatable, Sendable {
    let displayName: String
    let phoneNumbers: [String]
    let emailAddresses: [String]
}

struct IOSPersonalContextFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let mimeType: String
    let byteCount: Int
}

struct IOSSelectedJournalingSuggestion: Equatable, Sendable {
    let title: String
    let startDate: Date?
    let endDate: Date?
    let details: [String]
    let files: [IOSPersonalContextFile]
}

struct IOSPersonalContextPreviewItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let systemImage: String
}

struct IOSPersonalContextPreview: Identifiable, Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case contacts([IOSSelectedContact])
        case photos([IOSPersonalContextFile])
        case journaling(IOSSelectedJournalingSuggestion)
    }

    let id: UUID
    let request: IOSPersonalContextRequest
    let notice: String?
    let items: [IOSPersonalContextPreviewItem]
    let payload: Payload
}

struct IOSPersonalContextToolResult: Sendable {
    let imageURLs: [String]
    let json: String

    @MainActor
    var messageParts: [UIMessagePart] {
        imageURLs.map { UIMessagePart.Image(url: $0, metadata: nil) }
            + [UIMessagePart.Text(text: json, metadata: nil)]
    }
}

struct IOSPersonalContextFileStore {
    static let maxFileBytes = 20 * 1_024 * 1_024
    static let maxTotalBytes = 40 * 1_024 * 1_024
    static let maxAge: TimeInterval = 24 * 60 * 60

    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AmberPersonalContext", isDirectory: true)
    }

    func store(
        data: Data,
        requestID: UUID,
        index: Int,
        contentType: UTType,
        currentTotalBytes: Int
    ) throws -> IOSPersonalContextFile {
        guard !data.isEmpty,
              data.count <= Self.maxFileBytes,
              currentTotalBytes + data.count <= Self.maxTotalBytes else {
            throw IOSPersonalContextPickerError.mediaTooLarge
        }
        let directory = rootURL.appendingPathComponent(requestID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = contentType.preferredFilenameExtension ?? "bin"
        let url = directory.appendingPathComponent("selection-\(index).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return IOSPersonalContextFile(
            id: UUID(),
            url: url,
            mimeType: contentType.preferredMIMEType ?? "application/octet-stream",
            byteCount: data.count
        )
    }

    func isFresh(_ file: IOSPersonalContextFile, now: Date = Date()) -> Bool {
        guard fileManager.fileExists(atPath: file.url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: file.url.path),
              let modifiedAt = attributes[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modifiedAt) <= Self.maxAge
    }

    func remove(_ files: [IOSPersonalContextFile]) {
        let directories = Set(files.map { $0.url.deletingLastPathComponent() })
        directories.forEach { try? fileManager.removeItem(at: $0) }
    }

    func purgeExpiredDirectories(now: Date = Date()) {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories {
            guard let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) > Self.maxAge else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }
}

enum IOSPersonalContextPickerError: LocalizedError, Equatable, Sendable {
    case invalidArguments
    case busy
    case cancelled
    case emptySelection
    case unavailableEntitlement
    case mediaTooLarge
    case loadFailed
    case staleTemporaryFile

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "选取工具参数无效。"
        case .busy: "已有一个个人资料选取操作正在进行。"
        case .cancelled: "已取消选取，未向 Amber 提供任何个人资料。"
        case .emptySelection: "没有选择任何内容，未向 Amber 提供个人资料。"
        case .unavailableEntitlement: "当前签名未启用日记建议能力。"
        case .mediaTooLarge: "所选图片超过单张 20 MB 或合计 40 MB 的上限。"
        case .loadFailed: "无法读取所选内容。"
        case .staleTemporaryFile: "所选图片的临时副本已失效，请重新选择。"
        }
    }
}

private enum IOSPersonalContextImageEncoder {
    static func jpegData(from sourceData: Data) async throws -> Data {
        guard !sourceData.isEmpty, sourceData.count <= IOSPersonalContextFileStore.maxFileBytes else {
            throw IOSPersonalContextPickerError.mediaTooLarge
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: sourceData),
                  let data = ChatImageEncoder.sendJPEGData(image) else {
                throw IOSPersonalContextPickerError.loadFailed
            }
            return data
        }.value
    }

    static func jpegData(contentsOf url: URL) async throws -> Data {
        let sourceData = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        return try await jpegData(from: sourceData)
    }
}

@MainActor
@Observable
final class IOSPersonalContextPickerCoordinator {
    static let shared = IOSPersonalContextPickerCoordinator()

    private(set) var activeRequest: IOSPersonalContextRequest?
    private(set) var preview: IOSPersonalContextPreview?
    private(set) var isLoading = false

    @ObservationIgnored private var continuation: CheckedContinuation<IOSPersonalContextToolResult, Never>?
    @ObservationIgnored private let fileStore: IOSPersonalContextFileStore
    @ObservationIgnored private let journalingEntitlementAvailable: () -> Bool

    init(
        fileStore: IOSPersonalContextFileStore = IOSPersonalContextFileStore(),
        journalingEntitlementAvailable: @escaping () -> Bool = {
            #if canImport(JournalingSuggestions)
            let key = Bundle.main.bundleIdentifier?.contains(".experimental-gpl") == true
                ? "AmberAgentExperimentalConfiguredEntitlements"
                : "AmberAgentConfiguredEntitlements"
            let configured = Bundle.main.object(forInfoDictionaryKey: key) as? [String] ?? []
            return configured.contains("com.apple.developer.journal.allow")
            #else
            return false
            #endif
        }
    ) {
        self.fileStore = fileStore
        self.journalingEntitlementAvailable = journalingEntitlementAvailable
        fileStore.purgeExpiredDirectories()
    }

    func request(toolName: String, input: String) async -> [UIMessagePart] {
        await requestResult(toolName: toolName, input: input).messageParts
    }

    func requestResult(toolName: String, input: String) async -> IOSPersonalContextToolResult {
        guard continuation == nil, activeRequest == nil else {
            return failureResult(toolName: toolName, error: .busy)
        }
        guard let request = Self.parseRequest(toolName: toolName, input: input) else {
            return failureResult(toolName: toolName, error: .invalidArguments)
        }
        if request.kind == .journaling, !journalingEntitlementAvailable() {
            return failureResult(toolName: toolName, error: .unavailableEntitlement)
        }
        activeRequest = request
        let requestID = request.id

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    activeRequest = nil
                    continuation.resume(returning: failureResult(toolName: toolName, error: .cancelled))
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActiveRequest(ifMatching: requestID)
            }
        }
        return result
    }

    func receiveContacts(_ contacts: [IOSSelectedContact]) {
        guard let request = activeRequest, request.kind == .contacts else { return }
        let selected = Array(contacts.prefix(request.maxSelectionCount))
        guard !selected.isEmpty else {
            finish(error: .emptySelection)
            return
        }
        preview = IOSPersonalContextPreview(
            id: request.id,
            request: request,
            notice: contacts.count > request.maxSelectionCount
                ? "你选择了 \(contacts.count) 位联系人；按本次请求上限，仅下列前 \(request.maxSelectionCount) 位会提供给 Amber。"
                : nil,
            items: selected.map { contact in
                let details = contact.phoneNumbers + contact.emailAddresses
                return IOSPersonalContextPreviewItem(
                    id: UUID(),
                    title: contact.displayName,
                    subtitle: details.isEmpty ? "仅姓名" : details.joined(separator: "\n"),
                    imageURL: nil,
                    systemImage: "person.crop.circle"
                )
            },
            payload: .contacts(selected)
        )
    }

    func receivePhotos(_ items: [PhotosPickerItem]) async {
        guard let request = activeRequest, request.kind == .photos else { return }
        let selected = Array(items.prefix(request.maxSelectionCount))
        guard !selected.isEmpty else {
            finish(error: .emptySelection)
            return
        }
        isLoading = true
        var files: [IOSPersonalContextFile] = []
        do {
            for (index, item) in selected.enumerated() {
                guard item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }),
                      let sourceData = try await item.loadTransferable(type: Data.self) else {
                    throw IOSPersonalContextPickerError.loadFailed
                }
                let data = try await IOSPersonalContextImageEncoder.jpegData(from: sourceData)
                let file = try fileStore.store(
                    data: data,
                    requestID: request.id,
                    index: index,
                    contentType: .jpeg,
                    currentTotalBytes: files.reduce(0) { $0 + $1.byteCount }
                )
                files.append(file)
            }
            guard activeRequest?.id == request.id else {
                fileStore.remove(files)
                return
            }
            preview = Self.photoPreview(request: request, files: files)
        } catch let error as IOSPersonalContextPickerError {
            fileStore.remove(files)
            guard activeRequest?.id == request.id else { return }
            finish(error: error)
        } catch {
            fileStore.remove(files)
            guard activeRequest?.id == request.id else { return }
            finish(error: .loadFailed)
        }
        if activeRequest?.id == request.id {
            isLoading = false
        }
    }

    #if canImport(JournalingSuggestions)
    func receiveJournalingSuggestion(_ suggestion: JournalingSuggestion) async {
        guard let request = activeRequest, request.kind == .journaling else { return }
        isLoading = true
        do {
            let selected = try await IOSJournalingSuggestionMapper.map(
                suggestion,
                requestID: request.id,
                fileStore: fileStore
            )
            guard activeRequest?.id == request.id else {
                fileStore.remove(selected.files)
                return
            }
            preview = Self.journalingPreview(request: request, suggestion: selected)
        } catch let error as IOSPersonalContextPickerError {
            guard activeRequest?.id == request.id else { return }
            finish(error: error)
        } catch {
            guard activeRequest?.id == request.id else { return }
            finish(error: .loadFailed)
        }
        if activeRequest?.id == request.id {
            isLoading = false
        }
    }
    #endif

    func receivePhotoFilesForTesting(_ files: [IOSPersonalContextFile]) {
        guard let request = activeRequest, request.kind == .photos else { return }
        guard !files.isEmpty else {
            finish(error: .emptySelection)
            return
        }
        preview = Self.photoPreview(request: request, files: files)
    }

    func receiveJournalingSuggestionForTesting(_ suggestion: IOSSelectedJournalingSuggestion) {
        guard let request = activeRequest, request.kind == .journaling else { return }
        preview = Self.journalingPreview(request: request, suggestion: suggestion)
    }

    func confirmHandoff() {
        guard let preview else { return }
        let files = Self.files(in: preview.payload)
        guard files.allSatisfy({ fileStore.isFresh($0) }) else {
            fileStore.remove(files)
            finish(error: .staleTemporaryFile)
            return
        }
        isLoading = true
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.result(for: preview)
                }.value
                guard self?.activeRequest?.id == preview.request.id else { return }
                self?.fileStore.remove(files)
                self?.finish(result: result)
            } catch {
                guard self?.activeRequest?.id == preview.request.id else { return }
                self?.fileStore.remove(files)
                self?.finish(error: .loadFailed)
            }
        }
    }

    func cancelActiveRequest() {
        guard activeRequest != nil else { return }
        fileStore.remove(preview.map { Self.files(in: $0.payload) } ?? [])
        finish(error: .cancelled)
    }

    private func cancelActiveRequest(ifMatching requestID: UUID) {
        guard activeRequest?.id == requestID else { return }
        cancelActiveRequest()
    }

    private func finish(error: IOSPersonalContextPickerError) {
        guard let toolName = activeRequest?.toolName else { return }
        finish(result: failureResult(toolName: toolName, error: error))
    }

    private func finish(result: IOSPersonalContextToolResult) {
        let pending = continuation
        continuation = nil
        activeRequest = nil
        preview = nil
        isLoading = false
        pending?.resume(returning: result)
    }

    private func failureResult(toolName: String, error: IOSPersonalContextPickerError) -> IOSPersonalContextToolResult {
        IOSPersonalContextToolResult(
            imageURLs: [],
            json: Self.json([
                "ok": false,
                "tool": toolName,
                "status": Self.status(for: error),
                "reason": error.localizedDescription,
            ])
        )
    }

    private static func parseRequest(toolName: String, input: String) -> IOSPersonalContextRequest? {
        guard let data = input.data(using: .utf8),
              var arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        arguments.removeValue(forKey: "display_title")
        let kind: IOSPersonalContextPickerKind
        let maximum: Int
        switch toolName {
        case IOSAppleAgentToolCatalog.contactsPick:
            kind = .contacts
            maximum = 8
        case IOSAppleAgentToolCatalog.photosPick:
            kind = .photos
            maximum = 4
        case IOSAppleAgentToolCatalog.journalingSuggestionPick:
            kind = .journaling
            maximum = 1
        default:
            return nil
        }
        let allowedKeys: Set<String> = kind == .journaling ? [] : ["max_count"]
        guard Set(arguments.keys).isSubset(of: allowedKeys) else { return nil }
        let count: Int
        if let value = arguments["max_count"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            count = number.intValue
        } else {
            count = maximum
        }
        guard (1...maximum).contains(count) else { return nil }
        return IOSPersonalContextRequest(id: UUID(), toolName: toolName, kind: kind, maxSelectionCount: count)
    }

    private static func photoPreview(
        request: IOSPersonalContextRequest,
        files: [IOSPersonalContextFile]
    ) -> IOSPersonalContextPreview {
        IOSPersonalContextPreview(
            id: request.id,
            request: request,
            notice: nil,
            items: files.enumerated().map { index, file in
                IOSPersonalContextPreviewItem(
                    id: file.id,
                    title: "照片 \(index + 1)",
                    subtitle: ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file),
                    imageURL: file.url,
                    systemImage: "photo"
                )
            },
            payload: .photos(files)
        )
    }

    private static func journalingPreview(
        request: IOSPersonalContextRequest,
        suggestion: IOSSelectedJournalingSuggestion
    ) -> IOSPersonalContextPreview {
        var items = [IOSPersonalContextPreviewItem(
            id: UUID(),
            title: suggestion.title,
            subtitle: dateRange(start: suggestion.startDate, end: suggestion.endDate),
            imageURL: suggestion.files.first?.url,
            systemImage: "book.pages"
        )]
        items.append(contentsOf: suggestion.details.map {
            IOSPersonalContextPreviewItem(
                id: UUID(),
                title: $0,
                subtitle: nil,
                imageURL: nil,
                systemImage: "sparkles"
            )
        })
        items.append(contentsOf: suggestion.files.dropFirst().map { file in
            IOSPersonalContextPreviewItem(
                id: file.id,
                title: "日记建议照片",
                subtitle: ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file),
                imageURL: file.url,
                systemImage: "photo"
            )
        })
        return IOSPersonalContextPreview(
            id: request.id,
            request: request,
            notice: nil,
            items: items,
            payload: .journaling(suggestion)
        )
    }

    nonisolated private static func files(in payload: IOSPersonalContextPreview.Payload) -> [IOSPersonalContextFile] {
        switch payload {
        case .contacts: []
        case .photos(let files): files
        case .journaling(let suggestion): suggestion.files
        }
    }

    nonisolated private static func result(for preview: IOSPersonalContextPreview) throws -> IOSPersonalContextToolResult {
        let imageURLs = try files(in: preview.payload).map { file -> String in
            guard file.byteCount <= IOSPersonalContextFileStore.maxFileBytes,
                  let data = try? Data(contentsOf: file.url),
                  data.count == file.byteCount else {
                throw IOSPersonalContextPickerError.loadFailed
            }
            return "data:\(file.mimeType);base64,\(data.base64EncodedString())"
        }
        let payload: [String: Any]
        switch preview.payload {
        case .contacts(let contacts):
            payload = [
                "ok": true,
                "tool": preview.request.toolName,
                "selected_count": contacts.count,
                "contacts": contacts.map {
                    [
                        "name": $0.displayName,
                        "phone_numbers": $0.phoneNumbers,
                        "email_addresses": $0.emailAddresses,
                    ]
                },
            ]
        case .photos(let files):
            payload = [
                "ok": true,
                "tool": preview.request.toolName,
                "selected_count": files.count,
                "photos": files.map {
                    ["id": $0.id.uuidString, "mime_type": $0.mimeType, "byte_count": $0.byteCount]
                },
            ]
        case .journaling(let suggestion):
            var journalingPayload: [String: Any] = [
                "ok": true,
                "tool": preview.request.toolName,
                "title": suggestion.title,
                "details": suggestion.details,
                "media_count": suggestion.files.count,
            ]
            if let startDate = suggestion.startDate {
                journalingPayload["start_at"] = Self.iso8601(startDate)
            }
            if let endDate = suggestion.endDate {
                journalingPayload["end_at"] = Self.iso8601(endDate)
            }
            payload = journalingPayload
        }
        return IOSPersonalContextToolResult(imageURLs: imageURLs, json: json(payload))
    }

    private static func status(for error: IOSPersonalContextPickerError) -> String {
        switch error {
        case .cancelled: "cancelled"
        case .emptySelection: "empty_selection"
        case .unavailableEntitlement: "unavailable_entitlement"
        case .staleTemporaryFile: "stale_temporary_file"
        case .busy: "busy"
        case .invalidArguments: "invalid_arguments"
        case .mediaTooLarge: "media_too_large"
        case .loadFailed: "load_failed"
        }
    }

    nonisolated private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func dateRange(start: Date?, end: Date?) -> String? {
        let values = [start, end].compactMap {
            $0?.formatted(date: .abbreviated, time: .shortened)
        }
        return values.isEmpty ? nil : values.joined(separator: " – ")
    }

    nonisolated private static func json(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"status":"serialization_failed"}"#
        }
        return value
    }
}

#if canImport(JournalingSuggestions)
@MainActor
enum IOSJournalingSuggestionMapper {
    static func map(
        _ suggestion: JournalingSuggestion,
        requestID: UUID,
        fileStore: IOSPersonalContextFileStore
    ) async throws -> IOSSelectedJournalingSuggestion {
        var details: [String] = []

        let contacts = await suggestion.content(forType: JournalingSuggestion.Contact.self)
        details.append(contentsOf: contacts.prefix(4).map { "联系人：\($0.name)" })

        let locations = await suggestion.content(forType: JournalingSuggestion.Location.self)
        details.append(contentsOf: locations.prefix(4).compactMap { location in
            [location.place, location.city].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }.map { "地点：\($0)" })

        let songs = await suggestion.content(forType: JournalingSuggestion.Song.self)
        details.append(contentsOf: songs.prefix(4).compactMap { song in
            [song.song, song.artist].compactMap { $0 }.joined(separator: " — ").nilIfEmpty
        }.map { "音乐：\($0)" })

        let activities = await suggestion.content(forType: JournalingSuggestion.MotionActivity.self)
        details.append(contentsOf: activities.prefix(3).map { "活动：\($0.steps) 步" })

        if #available(iOS 18.0, *) {
            let reflections = await suggestion.content(forType: JournalingSuggestion.Reflection.self)
            details.append(contentsOf: reflections.prefix(3).map { "回顾：\($0.prompt)" })
        }

        var files: [IOSPersonalContextFile] = []
        let photos = await suggestion.content(forType: JournalingSuggestion.Photo.self)
        do {
            for (index, photo) in photos.prefix(4).enumerated() {
                let data = try await IOSPersonalContextImageEncoder.jpegData(contentsOf: photo.photo)
                files.append(try fileStore.store(
                    data: data,
                    requestID: requestID,
                    index: index,
                    contentType: .jpeg,
                    currentTotalBytes: files.reduce(0) { $0 + $1.byteCount }
                ))
            }
        } catch {
            fileStore.remove(files)
            throw error
        }

        return IOSSelectedJournalingSuggestion(
            title: suggestion.title,
            startDate: suggestion.date?.start,
            endDate: suggestion.date?.end,
            details: Array(details.prefix(12)),
            files: files
        )
    }
}
#endif

extension View {
    @MainActor
    @ViewBuilder
    func iosPersonalContextJournalingPicker(
        isPresented: Binding<Bool>,
        coordinator: IOSPersonalContextPickerCoordinator
    ) -> some View {
        #if canImport(JournalingSuggestions)
        journalingSuggestionsPicker(isPresented: isPresented) { suggestion in
            await coordinator.receiveJournalingSuggestion(suggestion)
        }
        #else
        self
        #endif
    }
}

struct IOSContactPickerView: UIViewControllerRepresentable {
    let onSelect: ([IOSSelectedContact]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let controller = CNContactPickerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: ([IOSSelectedContact]) -> Void
        let onCancel: () -> Void

        init(
            onSelect: @escaping ([IOSSelectedContact]) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onSelect = onSelect
            self.onCancel = onCancel
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onSelect(contacts.map(Self.selectedContact))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
        }

        private static func selectedContact(_ contact: CNContact) -> IOSSelectedContact {
            let name = CNContactFormatter.string(from: contact, style: .fullName)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return IOSSelectedContact(
                displayName: name?.isEmpty == false ? name! : "未命名联系人",
                phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
                emailAddresses: contact.emailAddresses.map { String($0.value) }
            )
        }
    }
}

struct IOSPersonalContextHandoffSheet: View {
    let preview: IOSPersonalContextPreview
    let isLoading: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    Text("只有下列已选内容会交给当前 Agent；未选择的内容不会被读取。")
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    if let notice = preview.notice {
                        Label(notice, systemImage: "info.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(preview.items) { item in
                        row(item)
                    }
                }
                .padding(16)
            }
            .navigationTitle("确认提供给 Amber")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                actions
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
            }
        }
    }

    private func row(_ item: IOSPersonalContextPreviewItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let imageURL = item.imageURL,
               let image = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                    .background(AmberTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: "，"))
    }

    @ViewBuilder
    private var actions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                cancelButton
                confirmButton
            }
        } else {
            HStack(spacing: 10) {
                cancelButton
                confirmButton
            }
        }
    }

    private var cancelButton: some View {
        Button("取消", action: onCancel)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var confirmButton: some View {
        Button(action: onConfirm) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在提供…")
                }
            } else {
                Text("提供给 Amber")
            }
        }
            .buttonStyle(.borderedProminent)
            .tint(AmberTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(isLoading)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
