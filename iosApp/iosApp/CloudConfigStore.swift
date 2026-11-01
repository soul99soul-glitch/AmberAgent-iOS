import Foundation
@preconcurrency import Shared

/// Cloud configuration state and import actions, kept on `MacGatewayStore` so the
/// paired HTTPS/SPKI channel and its lifecycle stay in one owner. State fields
/// are declared on the class in `MacGatewayStore.swift` (extension members are
/// not tracked by @Observable); this file owns the behavior.
extension MacGatewayStore {

    /// Contract transport over the paired client
    /// (docs/architecture/cloud-configuration-api.md): the same Bearer +
    /// SPKI-pinned HTTPS channel, kid pinning in the Keychain.
    var cloudConfigTransport: (any IOSCloudConfigTransport)? {
        guard let client, let connection else { return nil }
        return IOSCloudConfigClient(client: client, gatewayId: connection.gatewayId)
    }

    /// Whether the paired gateway answers the cloud-config endpoints.
    var cloudConfigAvailable: Bool { cloudConfigTransport != nil }

    // MARK: - Refresh

    /// Fetches the cloud's non-secret config view. `notFound` means an older
    /// gateway — surfaced as "接口待接入", not an error banner.
    func refreshCloudConfig() async {
        guard let transport = cloudConfigTransport else {
            cloudConfig = nil
            cloudConfigError = nil
            return
        }
        cloudConfigLoading = true
        defer { cloudConfigLoading = false }
        do {
            let snapshot = try await transport.fetchCloudConfiguration()
            cloudConfig = snapshot
            cloudConfigError = nil
        } catch is CancellationError {
        } catch {
            if forgetIfRevoked(error) { return }
            if error as? IOSCloudConfigError == .notFound {
                cloudConfig = nil
                cloudConfigError = nil
                return
            }
            cloudConfigError = error.localizedDescription
        }
    }

    // MARK: - Import from this device

    /// Uploads the draft's selected configuration. Credentials resolve at this
    /// explicit action; the draft keeps its selections on conflict/failure.
    @discardableResult
    func applyCloudImport(
        draft: IOSCloudImportDraft,
        sharedSettings: IOSSharedSettingsStore
    ) async -> String? {
        await applyCloudBundle(draft.bundle(using: sharedSettings))
    }

    /// Uploads one bundle (from local import or manual edit). Secrets live only
    /// in the bundle's memory, get sealed by the transport, and are never
    /// persisted, logged or sent to chat/agent inputs. Returns nil on success
    /// or a user-readable error.
    ///
    /// requestId semantics: bound to the operation's wire-level hash — retrying
    /// the same selection replays the same id (the server answers its stored
    /// receipt), while a changed selection generates a fresh one.
    @discardableResult
    func applyCloudBundle(_ bundle: IOSCloudConfigBundle) async -> String? {
        guard !cloudImporting else { return nil }
        guard let transport = cloudConfigTransport else {
            return localized("云端还不支持配置导入，请等待服务端更新")
        }
        guard !bundle.isEmpty else {
            return localized("没有选择要导入的配置")
        }
        cloudImporting = true
        defer { cloudImporting = false }
        let operationKey = bundle.operationKey
        let requestId = (pendingImportOperationKey == operationKey ? pendingImportRequestId : nil)
            ?? UUID().uuidString
        pendingImportOperationKey = operationKey
        pendingImportRequestId = requestId
        do {
            let receipt = try await transport.applyCloudConfiguration(bundle, requestId: requestId)
            cloudImportKeyChanged = false
            notice = Notice(
                text: receipt.replayed
                    ? localized("云端已应用过该配置（重复请求已合并）")
                    : localized("云端配置已更新，新任务开始使用"),
                isError: false
            )
            await refreshCloudConfig()
            return nil
        } catch {
            if forgetIfRevoked(error) { return MacGatewayError.unauthorized.localizedDescription }
            // A changed remote revision invalidates any staged retry context —
            // the next attempt re-reads it; the draft's selections survive.
            if case IOSCloudConfigError.revisionConflict = error {
                await refreshCloudConfig()
            }
            cloudImportKeyChanged = error as? IOSCloudConfigError == .importKeyChanged
            return error.localizedDescription
        }
    }

    /// The explicit re-trust action after the gateway's import kid changed:
    /// drops the pinned kid so the next apply re-pins over the trusted channel.
    func resetCloudImportKeyTrust() {
        guard let connection else { return }
        IOSCloudConfigClient.resetImportKeyTrust(gatewayId: connection.gatewayId)
        cloudImportKeyChanged = false
        notice = Notice(text: localized("已重置云端导入公钥信任，重试导入时重新固定"), isError: false)
    }
}
