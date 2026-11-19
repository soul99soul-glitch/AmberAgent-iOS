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
        #if DEBUG
        if ProcessInfo.processInfo.environment["AMBER_CLOUD_CONFIG_FIXTURE"] == "1" {
            return
        }
        #endif
        guard let client, let transport = cloudConfigTransport else {
            cloudConfig = nil
            cloudConfigError = nil
            return
        }
        cloudConfigLoading = true
        defer { cloudConfigLoading = false }
        do {
            let snapshot = try await transport.fetchCloudConfiguration()
            guard self.client === client else { return }
            cloudConfig = snapshot
            cloudConfigError = nil
        } catch is CancellationError {
        } catch {
            guard self.client === client else { return }
            if forgetIfRevoked(error, for: client) { return }
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
    /// `expectedRevision` is the revision the confirming UI displayed — never a
    /// refetched value, so a stale draft can't silently cover another device's
    /// unseen update.
    @discardableResult
    func applyCloudImport(
        draft: IOSCloudImportDraft,
        sharedSettings: IOSSharedSettingsStore,
        expectedRevision: Int?
    ) async -> String? {
        await applyCloudBundle(draft.bundle(using: sharedSettings), expectedRevision: expectedRevision)
    }

    /// Uploads one bundle (from local import or manual edit). Secrets live only
    /// in the bundle's memory, get sealed by the transport, and are never
    /// persisted, logged or sent to chat/agent inputs. Returns nil on success
    /// or a user-readable error.
    ///
    /// requestId semantics: bound to the operation's wire-level hash — retrying
    /// the same selection while the outcome is unknown replays the same id;
    /// a successful receipt ends the operation so the next submit (even with
    /// identical content) is a new operation with a fresh id.
    @discardableResult
    func applyCloudBundle(_ bundle: IOSCloudConfigBundle, expectedRevision: Int?) async -> String? {
        guard !cloudImporting else { return nil }
        notice = nil
        guard let client, let transport = cloudConfigTransport else {
            return localized("云端还不支持配置导入，请等待服务端更新")
        }
        guard !bundle.isEmpty else {
            return localized("没有选择要导入的配置")
        }
        guard let expected = expectedRevision else {
            // The user never saw a snapshot — submitting now could overwrite an
            // unseen remote config. Refresh once so the UI shows the truth,
            // then make the user re-confirm rather than silently baseline.
            await refreshCloudConfig()
            return cloudConfig == nil
                ? localized("无法读取云端配置，请刷新后重试")
                : localized("云端配置已更新，请重新查看后提交")
        }
        cloudImporting = true
        defer { cloudImporting = false }
        let requestId = pendingImportOperation.requestId(forOperationKey: bundle.operationKey)
        do {
            let receipt = try await transport.applyCloudConfiguration(
                bundle, requestId: requestId, expectedRevision: expected)
            guard self.client === client else { return nil }
            // Terminal receipt — this operation is over. Keeping the id would
            // let a later identical-but-new submit silently replay this receipt.
            pendingImportOperation.finish()
            cloudImportKeyChanged = false
            let summaryText: String
            if receipt.replayed {
                summaryText = localized("云端已应用过该配置（重复请求已合并）")
            } else if let model = bundle.model {
                let trimmedDisplayName = model.providerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let providerLabel = (trimmedDisplayName?.isEmpty == false)
                    ? trimmedDisplayName!
                    : IOSCloudConfigWire.shortProtocolName(for: model.providerKind)
                summaryText = localized("已切换云端配置为 \(providerLabel) · \(model.modelId)，新任务开始使用")
            } else {
                summaryText = localized("云端配置已更新，新任务开始使用")
            }
            notice = Notice(
                text: summaryText,
                isError: false
            )
            await refreshCloudConfig()
            return nil
        } catch {
            guard self.client === client else { return nil }
            if forgetIfRevoked(error, for: client) { return MacGatewayError.unauthorized.localizedDescription }
            // Result unknown or a clean 409: the pending id survives so a
            // verbatim retry merges/replays instead of doubling the apply;
            // the draft's selections survive for the user to re-review.
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
