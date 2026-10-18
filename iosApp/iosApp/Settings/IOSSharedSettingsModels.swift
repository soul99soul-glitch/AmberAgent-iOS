import Foundation
@preconcurrency import Shared

struct MiniAppSettingPatch {
    var enabled: Bool?
    var networkEnabled: Bool?
    var externalImagesEnabled: Bool?
    var searchEnabled: Bool?
    var clipboardCopyEnabled: Bool?
    var boardSummaryUpdateEnabled: Bool?
    var hostContextEnabled: Bool?
    var hostWriteEnabled: Bool?
    var aiEnabled: Bool?
    var sharedStoreEnabled: Bool?
    var eventBusEnabled: Bool?
    var launchEnabled: Bool?
    var sensorEnabled: Bool?
    var locationEnabled: Bool?
    var clipboardReadEnabled: Bool?
    var webViewDebugEnabled: Bool?
    var showSourceButton: Bool?

    init(
        enabled: Bool? = nil,
        networkEnabled: Bool? = nil,
        externalImagesEnabled: Bool? = nil,
        searchEnabled: Bool? = nil,
        clipboardCopyEnabled: Bool? = nil,
        boardSummaryUpdateEnabled: Bool? = nil,
        hostContextEnabled: Bool? = nil,
        hostWriteEnabled: Bool? = nil,
        aiEnabled: Bool? = nil,
        sharedStoreEnabled: Bool? = nil,
        eventBusEnabled: Bool? = nil,
        launchEnabled: Bool? = nil,
        sensorEnabled: Bool? = nil,
        locationEnabled: Bool? = nil,
        clipboardReadEnabled: Bool? = nil,
        webViewDebugEnabled: Bool? = nil,
        showSourceButton: Bool? = nil
    ) {
        self.enabled = enabled
        self.networkEnabled = networkEnabled
        self.externalImagesEnabled = externalImagesEnabled
        self.searchEnabled = searchEnabled
        self.clipboardCopyEnabled = clipboardCopyEnabled
        self.boardSummaryUpdateEnabled = boardSummaryUpdateEnabled
        self.hostContextEnabled = hostContextEnabled
        self.hostWriteEnabled = hostWriteEnabled
        self.aiEnabled = aiEnabled
        self.sharedStoreEnabled = sharedStoreEnabled
        self.eventBusEnabled = eventBusEnabled
        self.launchEnabled = launchEnabled
        self.sensorEnabled = sensorEnabled
        self.locationEnabled = locationEnabled
        self.clipboardReadEnabled = clipboardReadEnabled
        self.webViewDebugEnabled = webViewDebugEnabled
        self.showSourceButton = showSourceButton
    }
}

struct TodayBoardSettingPatch {
    var boardModelId: String?
    var clearBoardModelId: Bool
    var hotListRefreshIntervalMinutes: Int?
    var hotListWifiOnly: Bool?
    var hotListEnabledSources: [String]?
    var hotListFocusKeywords: [String]?
    var hotListFilterModeWireName: String?
    var boardReadingFontModeWireName: String?
    var boardReadingFontPackId: String?
    var clearBoardReadingFontPackId: Bool
    var deepReadFontScale: Float?
    var deepReadTemplateId: String?
    var hotListTranslateToChinese: Bool?

    init(
        boardModelId: String? = nil,
        clearBoardModelId: Bool = false,
        hotListRefreshIntervalMinutes: Int? = nil,
        hotListWifiOnly: Bool? = nil,
        hotListEnabledSources: [String]? = nil,
        hotListFocusKeywords: [String]? = nil,
        hotListFilterModeWireName: String? = nil,
        boardReadingFontModeWireName: String? = nil,
        boardReadingFontPackId: String? = nil,
        clearBoardReadingFontPackId: Bool = false,
        deepReadFontScale: Float? = nil,
        deepReadTemplateId: String? = nil,
        hotListTranslateToChinese: Bool? = nil
    ) {
        self.boardModelId = boardModelId
        self.clearBoardModelId = clearBoardModelId
        self.hotListRefreshIntervalMinutes = hotListRefreshIntervalMinutes
        self.hotListWifiOnly = hotListWifiOnly
        self.hotListEnabledSources = hotListEnabledSources
        self.hotListFocusKeywords = hotListFocusKeywords
        self.hotListFilterModeWireName = hotListFilterModeWireName
        self.boardReadingFontModeWireName = boardReadingFontModeWireName
        self.boardReadingFontPackId = boardReadingFontPackId
        self.clearBoardReadingFontPackId = clearBoardReadingFontPackId
        self.deepReadFontScale = deepReadFontScale
        self.deepReadTemplateId = deepReadTemplateId
        self.hotListTranslateToChinese = hotListTranslateToChinese
    }
}

struct IOSRemoteSyncStatus: Codable, Equatable {
    var lastUploadAt: Int64 = 0
    var lastDownloadAt: Int64 = 0
    var remoteRevision: String = ""
    var provider: IOSRemoteProviderKind = .localFolder
    var providerRevisions: [String: String] = [:]
    var deviceLabel: String = ""
    var lastBackupVersionName: String = ""
    var lastBackupVersionCode: Int64 = 0
    var lastError: String = ""

    init() {}

    func remoteRevision(for provider: IOSRemoteProviderKind) -> String {
        providerRevisions[provider.rawValue] ?? (self.provider == provider ? remoteRevision : "")
    }

    func scoped(to provider: IOSRemoteProviderKind) -> IOSRemoteSyncStatus {
        var scoped = self
        scoped.provider = provider
        scoped.remoteRevision = remoteRevision(for: provider)
        return scoped
    }

    mutating func setRemoteRevision(_ revision: String, for provider: IOSRemoteProviderKind) {
        self.provider = provider
        self.remoteRevision = revision
        providerRevisions[provider.rawValue] = revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lastUploadAt = try container.decodeIfPresent(Int64.self, forKey: .lastUploadAt) ?? 0
        self.lastDownloadAt = try container.decodeIfPresent(Int64.self, forKey: .lastDownloadAt) ?? 0
        self.remoteRevision = try container.decodeIfPresent(String.self, forKey: .remoteRevision) ?? ""
        self.provider = try container.decodeIfPresent(IOSRemoteProviderKind.self, forKey: .provider) ?? .localFolder
        self.providerRevisions = try container.decodeIfPresent([String: String].self, forKey: .providerRevisions) ?? [:]
        if !remoteRevision.isEmpty, providerRevisions[provider.rawValue] == nil {
            providerRevisions[provider.rawValue] = remoteRevision
        }
        self.deviceLabel = try container.decodeIfPresent(String.self, forKey: .deviceLabel) ?? ""
        self.lastBackupVersionName = try container.decodeIfPresent(String.self, forKey: .lastBackupVersionName) ?? ""
        self.lastBackupVersionCode = try container.decodeIfPresent(Int64.self, forKey: .lastBackupVersionCode) ?? 0
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError) ?? ""
    }
}

