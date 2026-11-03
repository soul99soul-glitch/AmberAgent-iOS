import Foundation
import Security

/// Keychain side-table for iOS-only scheme B credential storage.
///
/// Scheme B strips credentials from the persisted (UserDefaults/backup) form
/// (see `IOSCredentialRedactor`) and stores the real values here, in the
/// Keychain. On load, the masked values are rehydrated from this side-table.
///
/// The side-table is keyed by a stable credential ref (provider id + field, or
/// MCP server name + header name). It does NOT modify the shared
/// `ProviderSetting` KMP type (locked_decision). (P0.5 ships the slice pattern;
/// P2 extends coverage to all credential classes + migration of existing
/// plaintext values.)
///
/// This mirrors the existing per-provider Keychain pattern in
/// `KeychainProviderRegistryKeyStore` but is a generic store usable for any
/// credential class.
enum IOSCredentialSideTable {
    private static let service = "app.amber.ios.credentials"
    private static let cacheLock = NSLock()
    /// In-memory write-through cache mapping credential key -> Optional<String>
    /// (`.some(nil)` means confirmed absent in Keychain), eliminating repeated
    /// synchronous main-thread `SecItemCopyMatching` IPC during view body and
    /// model-availability evaluations.
    nonisolated(unsafe) private static var memoryCache: [String: String?] = [:]

    // MARK: - store / load

    /// Stores a credential value for a key. Returns true on success.
    ///
    /// 原位更新优先（SecItemUpdate）：写失败时不丢旧可用值。旧的
    /// delete-then-add 语义会先删后写，SecItemAdd 一旦失败旧 Key 即丢失。
    @discardableResult
    static func store(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8), !value.isEmpty else { return false }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            memoryCache[key] = .some(value)
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            memoryCache.removeValue(forKey: key)
            return false
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        if added {
            memoryCache[key] = .some(value)
        } else {
            memoryCache.removeValue(forKey: key)
        }
        return added
    }

    /// Loads a credential value for a key, or nil if absent.
    static func load(key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = memoryCache[key] {
            return cached
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let decoded = String(data: data, encoding: .utf8) {
            memoryCache[key] = .some(decoded)
            return decoded
        }
        if status == errSecItemNotFound {
            memoryCache[key] = .some(nil)
        }
        return nil
    }

    /// Deletes a credential value for a key.
    @discardableResult
    static func delete(key: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        let succeeded = status == errSecSuccess || status == errSecItemNotFound
        if succeeded {
            memoryCache[key] = .some(nil)
        } else {
            memoryCache.removeValue(forKey: key)
        }
        return succeeded
    }

    // MARK: - key builders (stable credential refs)

    /// Provider API key credential ref. Used by IOSSharedSettingsStore to store
    /// the real apiKey (scheme B) and rehydrate it on load, since the persisted
    /// Settings JSON form is redacted. Keyed by provider id (stable across
    /// restarts).
    static func providerApiKey(providerId: String) -> String {
        "provider.\(providerId).apiKey"
    }

    /// Search service API key credential ref.
    static func searchServiceApiKey(serviceId: String) -> String {
        "search.\(serviceId).apiKey"
    }

    /// MCP server header credential ref.
    static func mcpHeader(serverName: String, headerName: String) -> String {
        "mcp.\(serverName).header.\(headerName)"
    }

    /// Generic Settings-JSON credential ref for credential classes that do not
    /// have a Swift/KMP typed mutation (TTS, WebDAV/S3, model/assistant headers).
    static func settingsPath(_ path: String) -> String {
        "settings.\(path)"
    }
}
