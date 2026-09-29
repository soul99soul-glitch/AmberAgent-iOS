import Foundation
import Shared

/// Per-provider request header disguise (User-Agent + extras).
///
/// Coding Plan modes inject `opencode/<version>` at the KMP request layer when
/// no User-Agent is persisted here. A user-picked preset is stored locally so
/// listModels and chat send the same disguise without changing ProviderSetting.
enum IOSProviderRequestHeaderStore {
    private static let defaultsKey = "app.amber.ios.providerRequestHeaders.v1"

    struct Record: Codable, Equatable {
        var userAgent: String?
        var extra: [Item]
    }

    struct Item: Codable, Equatable {
        var name: String
        var value: String
    }

    static func record(for providerId: String, defaults: UserDefaults = .standard) -> Record {
        guard var all = loadAll(defaults: defaults),
              var stored = all[providerId] else {
            return Record(userAgent: nil, extra: [])
        }

        var changed = false
        for index in stored.extra.indices {
            let item = stored.extra[index]
            guard IOSCredentialRedactor.isHeaderSensitive(item.name),
                  !item.value.isEmpty,
                  item.value != IOSCredentialRedactor.mask else {
                continue
            }
            let key = credentialKey(providerId: providerId, headerName: item.name, rowIndex: index)
            // Mask only values that were successfully moved to Keychain.
            guard IOSCredentialSideTable.store(key: key, value: item.value) else { continue }
            stored.extra[index].value = IOSCredentialRedactor.mask
            changed = true
        }
        if changed {
            all[providerId] = stored
            persist(all, defaults: defaults)
        }

        var hydrated = stored
        for index in hydrated.extra.indices where hydrated.extra[index].value == IOSCredentialRedactor.mask {
            let item = hydrated.extra[index]
            let key = credentialKey(providerId: providerId, headerName: item.name, rowIndex: index)
            hydrated.extra[index].value = IOSCredentialSideTable.load(key: key) ?? ""
        }
        return hydrated
    }

    @discardableResult
    static func save(
        providerId: String,
        userAgent: String?,
        extra: [Item],
        defaults: UserDefaults = .standard
    ) -> Bool {
        var all = loadAll(defaults: defaults) ?? [:]
        let oldRefs = Set((all[providerId]?.extra ?? []).enumerated().compactMap { index, item -> String? in
            guard IOSCredentialRedactor.isHeaderSensitive(item.name), !item.value.isEmpty else { return nil }
            return credentialKey(providerId: providerId, headerName: item.name, rowIndex: index)
        })
        let trimmedAgent = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanedExtra = extra.compactMap { item -> Item? in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return Item(name: name, value: item.value)
        }
        if trimmedAgent?.isEmpty != false && cleanedExtra.isEmpty {
            all.removeValue(forKey: providerId)
        } else {
            var activeRefs = Set<String>()
            for index in cleanedExtra.indices {
                let item = cleanedExtra[index]
                guard IOSCredentialRedactor.isHeaderSensitive(item.name), !item.value.isEmpty else { continue }
                let key = credentialKey(providerId: providerId, headerName: item.name, rowIndex: index)
                if item.value != IOSCredentialRedactor.mask,
                   !IOSCredentialSideTable.store(key: key, value: item.value) {
                    return false
                } else if item.value != IOSCredentialRedactor.mask {
                    cleanedExtra[index].value = IOSCredentialRedactor.mask
                }
                activeRefs.insert(key)
            }
            all[providerId] = Record(
                userAgent: trimmedAgent?.isEmpty == true ? nil : trimmedAgent,
                extra: cleanedExtra
            )
            for key in oldRefs.subtracting(activeRefs) {
                IOSCredentialSideTable.delete(key: key)
            }
        }
        if all[providerId] == nil {
            for key in oldRefs {
                IOSCredentialSideTable.delete(key: key)
            }
        }
        persist(all, defaults: defaults)
        return true
    }

    static func headers(for providerId: String, defaults: UserDefaults = .standard) -> [CustomHeader] {
        let record = record(for: providerId, defaults: defaults)
        var headers: [CustomHeader] = []
        if let userAgent = record.userAgent, !userAgent.isEmpty {
            headers.append(CustomHeader(name: "User-Agent", value: userAgent))
        }
        headers.append(contentsOf: record.extra.map { CustomHeader(name: $0.name, value: $0.value) })
        return headers
    }

    /// Stable reference for each provider header row. The row index keeps
    /// repeated sensitive header names from sharing a single secret value.
    private static func credentialKey(providerId: String, headerName: String, rowIndex: Int) -> String {
        IOSCredentialSideTable.settingsPath(
            "providerRequestHeaders.\(providerId).extra[\(headerName)#\(rowIndex)].value"
        )
    }

    private static func loadAll(defaults: UserDefaults) -> [String: Record]? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode([String: Record].self, from: data)
    }

    private static func persist(_ all: [String: Record], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

enum ProviderUserAgentPreset: String, CaseIterable, Identifiable {
    case opencode
    case claudeCode
    case cursor
    case cline
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opencode: "OpenCode"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .cline: "Cline"
        case .custom: "自定义"
        }
    }

    var userAgent: String? {
        switch self {
        case .opencode: OpenAICompatUserAgents.shared.OPENCODE
        case .claudeCode: OpenAICompatUserAgents.shared.CLAUDE_CODE
        case .cursor: OpenAICompatUserAgents.shared.CURSOR
        case .cline: OpenAICompatUserAgents.shared.CLINE
        case .custom: nil
        }
    }

    static func matching(userAgent: String?) -> ProviderUserAgentPreset? {
        let trimmed = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return nil }
        return allCases.first { preset in
            guard let value = preset.userAgent else { return false }
            return value.caseInsensitiveCompare(trimmed) == .orderedSame
        } ?? .custom
    }
}
