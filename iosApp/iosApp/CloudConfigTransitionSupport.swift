import Foundation

extension IOSCloudImportDraft {
    /// Structured "当前 → 目标（服务商 / 模型 / Base URL）" summary for switching the cloud model.
    func modelTransitionSummary(
        remote: IOSCloudConfigSnapshot?,
        localProviders: [IOSCloudProviderExportItem]? = nil
    ) -> IOSCloudModelTransitionSummary? {
        guard let provider = selectedProvider, let model = selectedModel else { return nil }
        let matchedRemoteFriendlyName = Self.matchedLocalProviderName(
            for: remote?.model,
            in: localProviders ?? providers
        )
        return IOSCloudModelTransitionSummary.build(
            remote: remote,
            remoteFriendlyProviderName: matchedRemoteFriendlyName,
            targetProviderLabel: "\(provider.name) (\(provider.kind.rawValue))",
            targetFriendlyProviderName: provider.name,
            targetProviderKind: provider.kind.rawValue,
            targetModelId: model.modelId,
            targetBaseUrl: provider.baseUrl,
            hasTargetKey: provider.hasApiKey
        )
    }

    private static func matchedLocalProviderName(
        for remoteModel: IOSCloudConfigSnapshot.Model?,
        in candidates: [IOSCloudProviderExportItem]
    ) -> String? {
        guard let remoteModel, !remoteModel.provider.isEmpty else { return nil }
        let remoteKind = remoteModel.provider.lowercased()
        let remoteEffectiveUrl = IOSCloudConfigWire.effectiveBaseUrl(
            provider: remoteModel.provider,
            baseUrl: remoteModel.baseUrl
        )
        return candidates.first { item in
            item.kind.rawValue.lowercased() == remoteKind
                && IOSCloudConfigWire.effectiveBaseUrl(provider: item.kind.rawValue, baseUrl: item.baseUrl) == remoteEffectiveUrl
        }?.name
    }

    /// Aligns the primary cloud-switch picker to the cloud's active (provider, model)
    /// when a matching exportable local provider/model exists, so opening the page shows
    /// "已在使用" for the cloud's real active model instead of a false diff against local chat.
    func alignedToRemoteModelIfMatched(_ remote: IOSCloudConfigSnapshot?) -> IOSCloudImportDraft {
        guard let remoteModel = remote?.model,
              !remoteModel.provider.isEmpty,
              !remoteModel.modelId.isEmpty else {
            return self
        }
        let remoteKind = remoteModel.provider.lowercased()
        let remoteEffectiveUrl = IOSCloudConfigWire.effectiveBaseUrl(
            provider: remoteModel.provider,
            baseUrl: remoteModel.baseUrl
        )
        let orderedCandidates: [IOSCloudProviderExportItem]
        if let current = selectedProvider, current.isExportable {
            orderedCandidates = [current] + exportableProviders.filter { $0.providerId != current.providerId }
        } else {
            orderedCandidates = exportableProviders
        }
        for provider in orderedCandidates {
            guard provider.kind.rawValue.lowercased() == remoteKind else { continue }
            let localEffectiveUrl = IOSCloudConfigWire.effectiveBaseUrl(
                provider: provider.kind.rawValue,
                baseUrl: provider.baseUrl
            )
            guard localEffectiveUrl == remoteEffectiveUrl,
                  let matchedModel = provider.chatModels.first(where: { $0.modelId == remoteModel.modelId }) else {
                continue
            }
            var aligned = self
            aligned.providerId = provider.providerId
            aligned.modelUuid = matchedModel.uuid
            return aligned
        }
        return self
    }

    /// Prepares the primary "云端模型" switcher selection:
    /// 1. Prefers aligning to the cloud's active (provider, model) when matched locally;
    /// 2. When local active chat is OAuth/non-exportable (`providerId == nil`) and cloud is
    ///    unconfigured or unmatched, falls back to the first exportable provider so the
    ///    model picker & switch CTA never collapse into an incomplete card.
    func alignedForPrimarySwitch(remote: IOSCloudConfigSnapshot?) -> IOSCloudImportDraft {
        var aligned = alignedToRemoteModelIfMatched(remote)
        if aligned.selectedProvider?.isExportable == true {
            return aligned
        }
        if let fallback = aligned.exportableProviders.first {
            aligned.providerId = fallback.providerId
            aligned.modelUuid = fallback.defaultModelUuid
        }
        return aligned
    }
}

/// Pure UI state for the primary "云端模型" card footer row:
/// - `.inUse`: plain non-clickable status text ("已在使用"), never a button.
/// - `.readyToSwitch`: concise single-line change hint + sole primary button "切换并使用".
/// - `.switching`: in-flight progress indicator.
enum IOSCloudPrimarySwitchState: Equatable, Sendable {
    case switching
    case inUse(missingKey: Bool)
    case readyToSwitch(changeHint: String)

    var showsPrimaryActionButton: Bool {
        if case .readyToSwitch = self { return true }
        return false
    }

    var statusText: String? {
        switch self {
        case .switching:
            return macGatewayL("正在切换…")
        case .inUse(let missingKey):
            return missingKey ? macGatewayL("已在使用 · 缺少 Key") : macGatewayL("已在使用")
        case .readyToSwitch:
            return nil
        }
    }

    static func resolve(
        transition: IOSCloudModelTransitionSummary,
        remote: IOSCloudConfigSnapshot?,
        isLoadingRemote: Bool,
        isSubmitting: Bool
    ) -> IOSCloudPrimarySwitchState {
        if isSubmitting {
            return .switching
        }
        if !transition.changesEndpointOrModel, transition.current != nil {
            let missingKey = (remote?.model?.keyConfigured == false)
            if missingKey && transition.replacesOrSetsKey {
                return .readyToSwitch(changeHint: macGatewayL("云端当前缺少 API Key"))
            }
            return .inUse(missingKey: missingKey)
        }
        let hint: String
        if remote == nil && isLoadingRemote {
            hint = macGatewayL("正在读取云端状态…")
        } else if let current = transition.current {
            let endpointChanged = current.providerKind != transition.target.providerKind
                || current.effectiveBaseUrl != transition.target.effectiveBaseUrl
            if endpointChanged {
                let currentProvider = current.friendlyProviderName
                    ?? IOSCloudConfigWire.shortProtocolName(for: current.providerKind)
                if currentProvider != transition.target.friendlyProviderName || current.modelId != transition.target.modelId {
                    hint = macGatewayL("当前：\(currentProvider) · \(current.modelId)")
                } else {
                    hint = macGatewayL("将切换接入地址")
                }
            } else if current.modelId != transition.target.modelId {
                hint = macGatewayL("当前：\(current.modelId)")
            } else {
                hint = macGatewayL("将切换接入地址")
            }
        } else {
            hint = macGatewayL("尚未设置云端模型")
        }
        return .readyToSwitch(changeHint: hint)
    }
}

// MARK: - Current → Target transition & action readiness

/// Side-by-side comparison of the cloud's current model configuration and the target
/// configuration being switched to, surfacing Provider, Model, and Base URL explicitly.
struct IOSCloudModelTransitionSummary: Equatable, Sendable {
    struct Endpoint: Equatable, Sendable {
        var providerLabel: String
        var friendlyProviderName: String? = nil
        var providerKind: String
        var modelId: String
        var baseUrlDisplay: String
        var effectiveBaseUrl: String
        var keyStatusLabel: String
    }

    /// nil when the cloud has no model configured yet.
    var current: Endpoint?
    var target: Endpoint
    /// True when provider, modelId, or effectiveBaseUrl differs from current, or cloud has no model yet.
    var changesEndpointOrModel: Bool
    /// True when the action will also upload/replace the model API key.
    var replacesOrSetsKey: Bool
    /// True when remote holds a model key, destination (provider/baseUrl) changed, and no new key is provided.
    var requiresNewKeyForDestinationChange: Bool

    var currentSummaryLine: String {
        guard let current else { return macGatewayL("未设置云端模型") }
        return "\(current.providerLabel) · \(current.modelId) · \(current.baseUrlDisplay)"
    }

    var targetSummaryLine: String {
        "\(target.providerLabel) · \(target.modelId) · \(target.baseUrlDisplay)"
    }

    var transitionArrowLine: String {
        "\(currentSummaryLine) → \(targetSummaryLine)"
    }

    static func forManualEdit(
        remote: IOSCloudConfigSnapshot?,
        providerKind: IOSCloudProviderKind,
        modelId: String,
        baseUrl: String,
        hasNewApiKey: Bool
    ) -> IOSCloudModelTransitionSummary {
        let trimmedModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return build(
            remote: remote,
            targetProviderLabel: IOSCloudConfigWire.providerDisplayName(for: providerKind.rawValue),
            targetProviderKind: providerKind.rawValue,
            targetModelId: trimmedModelId.isEmpty ? macGatewayL("待填写模型 ID") : trimmedModelId,
            targetBaseUrl: baseUrl,
            hasTargetKey: hasNewApiKey
        )
    }

    static func build(
        remote: IOSCloudConfigSnapshot?,
        remoteFriendlyProviderName: String? = nil,
        targetProviderLabel: String,
        targetFriendlyProviderName: String? = nil,
        targetProviderKind: String,
        targetModelId: String,
        targetBaseUrl: String,
        hasTargetKey: Bool
    ) -> IOSCloudModelTransitionSummary {
        let currentEndpoint: Endpoint?
        if let remoteModel = remote?.model,
           !remoteModel.provider.isEmpty || !remoteModel.modelId.isEmpty {
            currentEndpoint = Endpoint(
                providerLabel: IOSCloudConfigWire.providerDisplayName(for: remoteModel.provider),
                friendlyProviderName: remoteFriendlyProviderName,
                providerKind: remoteModel.provider.lowercased(),
                modelId: remoteModel.modelId,
                baseUrlDisplay: IOSCloudConfigWire.displayBaseUrl(provider: remoteModel.provider, baseUrl: remoteModel.baseUrl),
                effectiveBaseUrl: IOSCloudConfigWire.effectiveBaseUrl(provider: remoteModel.provider, baseUrl: remoteModel.baseUrl),
                keyStatusLabel: remoteModel.keyConfigured ? macGatewayL("Key 已配置") : macGatewayL("缺少 Key")
            )
        } else {
            currentEndpoint = nil
        }

        let targetEffectiveUrl = IOSCloudConfigWire.effectiveBaseUrl(provider: targetProviderKind, baseUrl: targetBaseUrl)
        let targetKeyLabel: String
        if hasTargetKey {
            targetKeyLabel = currentEndpoint != nil ? macGatewayL("同步并替换云端 Key") : macGatewayL("同步 Key 到云端")
        } else if remote?.model?.keyConfigured == true {
            targetKeyLabel = macGatewayL("保留云端现有 Key")
        } else {
            targetKeyLabel = macGatewayL("未提供 Key")
        }

        let targetEndpoint = Endpoint(
            providerLabel: targetProviderLabel,
            friendlyProviderName: targetFriendlyProviderName,
            providerKind: targetProviderKind.lowercased(),
            modelId: targetModelId,
            baseUrlDisplay: IOSCloudConfigWire.displayBaseUrl(provider: targetProviderKind, baseUrl: targetBaseUrl),
            effectiveBaseUrl: targetEffectiveUrl,
            keyStatusLabel: targetKeyLabel
        )

        let destinationChanged = currentEndpoint.map {
            $0.providerKind != targetEndpoint.providerKind || $0.effectiveBaseUrl != targetEndpoint.effectiveBaseUrl
        } ?? false

        let changesEndpointOrModel = currentEndpoint.map {
            destinationChanged || $0.modelId != targetEndpoint.modelId
        } ?? true

        let requiresNewKey = (remote?.model?.keyConfigured == true) && destinationChanged && !hasTargetKey

        return IOSCloudModelTransitionSummary(
            current: currentEndpoint,
            target: targetEndpoint,
            changesEndpointOrModel: changesEndpointOrModel,
            replacesOrSetsKey: hasTargetKey,
            requiresNewKeyForDestinationChange: requiresNewKey
        )
    }
}

/// Evaluates whether a cloud configuration primary action can proceed, and when disabled,
/// produces the exact reason and actionable next step to display right next to the button.
///
/// Crucially: if `reviewed` was nil when opening a sheet (because the initial GET was still
/// in flight) and `latest` arrives, `effectiveReviewed` automatically adopts `latest` so
/// initial load completion never causes a false-positive version conflict.
struct IOSCloudConfigActionReadiness: Equatable, Sendable {
    enum FormBlocker: Equatable, Sendable {
        case noSelection
        case missingModelId
        case missingDestinationApiKey
        case missingSearchApiKey(serviceName: String)
    }

    var effectiveReviewed: IOSCloudConfigSnapshot?
    var shouldAutoAdoptLatest: Bool
    var hasVersionConflict: Bool
    var canSubmit: Bool
    var disabledReason: String?
    var nextStep: String?

    var effectiveExpectedRevision: Int? {
        effectiveReviewed?.revision
    }

    var combinedGuidance: String? {
        guard let disabledReason else { return nil }
        if let nextStep, !nextStep.isEmpty {
            return "\(disabledReason)。\(nextStep)"
        }
        return disabledReason
    }

    static func evaluate(
        reviewed: IOSCloudConfigSnapshot?,
        latest: IOSCloudConfigSnapshot?,
        isLoading: Bool = false,
        isSubmitting: Bool = false,
        formBlocker: FormBlocker? = nil
    ) -> IOSCloudConfigActionReadiness {
        let shouldAutoAdopt = (reviewed == nil && latest != nil)
        let effectiveReviewed = reviewed ?? latest
        let hasConflict: Bool
        if let reviewed, let latest {
            hasConflict = !reviewed.hasSameVersion(as: latest)
        } else {
            hasConflict = false
        }

        if isSubmitting {
            return IOSCloudConfigActionReadiness(
                effectiveReviewed: effectiveReviewed,
                shouldAutoAdoptLatest: shouldAutoAdopt,
                hasVersionConflict: hasConflict,
                canSubmit: false,
                disabledReason: macGatewayL("正在加密同步到云端"),
                nextStep: macGatewayL("请等待当前请求完成")
            )
        }

        if let formBlocker {
            let (reason, step): (String, String) = switch formBlocker {
            case .noSelection:
                (
                    macGatewayL("无法继续：尚未勾选任何要导入的模型或搜索配置"),
                    macGatewayL("下一步：请在上方至少勾选一个模型服务商或联网搜索服务")
                )
            case .missingModelId:
                (
                    macGatewayL("无法切换：尚未填写目标模型 ID"),
                    macGatewayL("下一步：请在上方「模型 ID」输入框填写模型标识（例如 deepseek-chat）")
                )
            case .missingDestinationApiKey:
                (
                    macGatewayL("无法切换：更改服务商或 Base URL 时不能沿用旧地址的 API Key"),
                    macGatewayL("下一步：请在上方「API Key」输入框长按粘贴新服务的 Key，或先删除云端旧 Key")
                )
            case .missingSearchApiKey(let serviceName):
                (
                    macGatewayL("无法保存：尚未填写 \(serviceName) API Key"),
                    macGatewayL("下一步：请在上方输入框长按选择「粘贴」（或按 ⌘V）填入 API Key")
                )
            }
            return IOSCloudConfigActionReadiness(
                effectiveReviewed: effectiveReviewed,
                shouldAutoAdoptLatest: shouldAutoAdopt,
                hasVersionConflict: hasConflict,
                canSubmit: false,
                disabledReason: reason,
                nextStep: step
            )
        }

        if latest == nil {
            let reason = isLoading
                ? macGatewayL("正在读取云端当前配置版本")
                : macGatewayL("无法提交：尚未读取到云端当前配置状态")
            let step = isLoading
                ? macGatewayL("下一步：读取完成后按钮将自动启用")
                : macGatewayL("下一步：请点击「刷新云端状态」后再提交，已填写内容会保留")
            return IOSCloudConfigActionReadiness(
                effectiveReviewed: nil,
                shouldAutoAdoptLatest: false,
                hasVersionConflict: false,
                canSubmit: false,
                disabledReason: reason,
                nextStep: step
            )
        }

        if hasConflict, let latest {
            return IOSCloudConfigActionReadiness(
                effectiveReviewed: effectiveReviewed,
                shouldAutoAdoptLatest: false,
                hasVersionConflict: true,
                canSubmit: false,
                disabledReason: macGatewayL("暂停提交：云端配置刚在其他终端更新至版本 #\(latest.revision)"),
                nextStep: macGatewayL("下一步：请点击上方「确认最新云端版本并继续」按钮，已填写内容会完整保留")
            )
        }

        return IOSCloudConfigActionReadiness(
            effectiveReviewed: effectiveReviewed,
            shouldAutoAdoptLatest: shouldAutoAdopt,
            hasVersionConflict: false,
            canSubmit: true,
            disabledReason: nil,
            nextStep: nil
        )
    }
}
