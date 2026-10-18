import Foundation
import CryptoKit

enum IOSCapabilityStatus: String, CaseIterable, Identifiable {
    case supported
    case degraded
    case requiresEntitlement
    case requiresExtensionTarget
    case requiresSystemSettings
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .supported: "Supported"
        case .degraded: "Requires foreground system UI"
        case .requiresEntitlement: "Requires entitlement"
        case .requiresExtensionTarget: "Requires extension"
        case .requiresSystemSettings: "Requires Settings"
        case .unsupported: "Unavailable on iOS"
        }
    }
}

enum IOSCapabilityRisk: String, CaseIterable, Identifiable {
    case normal
    case sensitive
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .sensitive: "Sensitive"
        case .high: "High"
        }
    }
}

enum IOSCapabilityDomain: String, CaseIterable, Identifiable {
    case agentMemory
    case filesAndPhotos
    case healthAndMotion
    case location
    case contacts
    case calendarAndReminders
    case cameraAndMicrophone
    case speechAndMedia
    case notifications
    case networkAndConnectivity
    case identityAndAuthentication
    case homeAndNearby
    case extensionsAndEntitlements
    case externalApps
    case unavailableOnIOS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agentMemory: "Agent Memory"
        case .filesAndPhotos: "Files & Photos"
        case .healthAndMotion: "Health & Motion"
        case .location: "Location"
        case .contacts: "Contacts"
        case .calendarAndReminders: "Calendar & Reminders"
        case .cameraAndMicrophone: "Camera & Microphone"
        case .speechAndMedia: "Speech & Media"
        case .notifications: "Notifications"
        case .networkAndConnectivity: "Network & Connectivity"
        case .identityAndAuthentication: "Identity & Authentication"
        case .homeAndNearby: "Home & Nearby"
        case .extensionsAndEntitlements: "Extensions & Entitlements"
        case .externalApps: "External Apps & Sharing"
        case .unavailableOnIOS: "Unavailable on iOS"
        }
    }
}

enum IOSPermissionRequestKind: String, CaseIterable, Identifiable {
    case directSystemPrompt
    case foregroundSystemUI
    case foregroundSession
    case authenticationOperation
    case picker
    case settingsOnly
    case entitlementRequired
    case extensionTargetRequired
    case entitlementAndExtensionRequired
    case diagnosticOnly
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directSystemPrompt: "Direct system prompt"
        case .foregroundSystemUI: "Foreground system UI"
        case .foregroundSession: "Foreground session"
        case .authenticationOperation: "Authentication operation"
        case .picker: "System picker"
        case .settingsOnly: "Settings only"
        case .entitlementRequired: "Entitlement required"
        case .extensionTargetRequired: "Extension target required"
        case .entitlementAndExtensionRequired: "Entitlement and extension required"
        case .diagnosticOnly: "Diagnostic only"
        case .unsupported: "Unsupported"
        }
    }

    var canRequestInApp: Bool {
        switch self {
        case .directSystemPrompt, .foregroundSystemUI, .foregroundSession, .authenticationOperation, .picker:
            true
        case .settingsOnly,
             .entitlementRequired,
             .extensionTargetRequired,
             .entitlementAndExtensionRequired,
             .diagnosticOnly,
             .unsupported:
            false
        }
    }
}

enum IOSAgentPermissionPolicy: String, CaseIterable, Identifiable {
    case disabled
    case askEveryTime
    case allowOncePerRun
    case autoApprove
    case autoApproveHighRisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .askEveryTime: "Ask every time"
        case .allowOncePerRun: "Allow once per run"
        case .autoApprove: "Auto approve"
        case .autoApproveHighRisk: "Auto approve (high risk)"
        }
    }
}

struct IOSPlatformToolGate: Hashable {
    let requiresFreshUserPresence: Bool
    let allowRunScopedReuse: Bool
    let allowGlobalAutoApproval: Bool
}

struct IOSPlatformCapability: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let domain: IOSCapabilityDomain
    let status: IOSCapabilityStatus
    let risk: IOSCapabilityRisk
    let requestKind: IOSPermissionRequestKind
    let requestEntryPoint: String
    let uiActionNames: [String]
    let modelToolNames: [String]
    let blockedToolNames: [String]
    let unavailableReason: String?
    let requiredInfoPlistKeys: [String]
    let requiredEntitlements: [String]
    let requiredBackgroundModes: [String]
    let requiredExtensionTargets: [String]
    let defaultEnabled: Bool
    let canOpenSettings: Bool
    let gate: IOSPlatformToolGate

    var canRequestInApp: Bool {
        requestKind.canRequestInApp && status != .unsupported
    }
}

extension IOSCapabilityRegistry {
    static func capability(forToolName toolName: String) -> IOSPlatformCapability? {
        capabilities
            .filter { $0.modelToolNames.contains(toolName) || $0.blockedToolNames.contains(toolName) }
            .max { lhs, rhs in
                lhs.enforcementRank < rhs.enforcementRank
            }
    }

    static func capability(forUIActionName actionName: String) -> IOSPlatformCapability? {
        capabilities
            .filter { $0.uiActionNames.contains(actionName) }
            .max { lhs, rhs in
                lhs.enforcementRank < rhs.enforcementRank
            }
    }

    static func capabilities(forActionName actionName: String) -> [IOSPlatformCapability] {
        let directMatches = capabilities.filter {
            $0.uiActionNames.contains(actionName) ||
                $0.modelToolNames.contains(actionName) ||
                $0.blockedToolNames.contains(actionName)
        }
        let compositeIds = compositeActionRequirements[actionName] ?? []
        let compositeMatches = capabilities.filter { compositeIds.contains($0.id) }
        return Array(Set(directMatches + compositeMatches))
            .sorted { lhs, rhs in
                if lhs.enforcementRank == rhs.enforcementRank {
                    lhs.id < rhs.id
                } else {
                    lhs.enforcementRank > rhs.enforcementRank
                }
            }
    }

    static func capability(
        id: String,
        title: String,
        summary: String,
        domain: IOSCapabilityDomain,
        status: IOSCapabilityStatus,
        risk: IOSCapabilityRisk,
        requestKind: IOSPermissionRequestKind,
        requestEntryPoint: String,
        uiActionNames: [String] = [],
        modelToolNames: [String] = [],
        blockedToolNames: [String] = [],
        unavailableReason: String? = nil,
        requiredInfoPlistKeys: [String] = [],
        requiredEntitlements: [String] = [],
        requiredBackgroundModes: [String] = [],
        requiredExtensionTargets: [String] = [],
        defaultEnabled: Bool,
        canOpenSettings: Bool = true,
        gate: IOSPlatformToolGate
    ) -> IOSPlatformCapability {
        IOSPlatformCapability(
            id: id,
            title: title,
            summary: summary,
            domain: domain,
            status: status,
            risk: risk,
            requestKind: requestKind,
            requestEntryPoint: requestEntryPoint,
            uiActionNames: uiActionNames,
            modelToolNames: modelToolNames,
            blockedToolNames: blockedToolNames,
            unavailableReason: unavailableReason,
            requiredInfoPlistKeys: requiredInfoPlistKeys,
            requiredEntitlements: requiredEntitlements,
            requiredBackgroundModes: requiredBackgroundModes,
            requiredExtensionTargets: requiredExtensionTargets,
            defaultEnabled: defaultEnabled,
            canOpenSettings: canOpenSettings,
            gate: gate
        )
    }

    static func unsupported(
        id: String,
        title: String,
        toolNames: [String],
        reason: String
    ) -> IOSPlatformCapability {
        capability(
            id: id,
            title: title,
            summary: reason,
            domain: .unavailableOnIOS,
            status: .unsupported,
            risk: .high,
            requestKind: .unsupported,
            requestEntryPoint: "No public iOS API",
            blockedToolNames: toolNames,
            unavailableReason: reason,
            defaultEnabled: false,
            canOpenSettings: false,
            gate: freshHighRiskGate
        )
    }
}

private extension IOSPlatformCapability {
    var enforcementRank: Int {
        var rank = 0
        if risk == .sensitive { rank += 10 }
        if risk == .high { rank += 20 }
        if gate.requiresFreshUserPresence { rank += 8 }
        if !gate.allowGlobalAutoApproval { rank += 4 }
        if requestKind == .entitlementRequired || requestKind == .entitlementAndExtensionRequired { rank += 18 }
        if requestKind == .extensionTargetRequired { rank += 18 }
        if status == .unsupported { rank += 100 }
        return rank
    }
}

extension IOSPlatformCapability {
    /// `title` remains the canonical capability label used by policy snapshots
    /// and tool execution; this variant is for user-facing display only.
    var localizedTitle: String {
        IOSAppLocalization.string(title, defaultValue: title)
    }
}

extension IOSAgentPermissionPolicy {
    /// `title` remains the canonical policy label; this variant is for settings UI.
    var localizedTitle: String {
        let key: String
        switch self {
        case .disabled:
            key = "禁用"
        case .askEveryTime, .allowOncePerRun:
            key = "每次询问"
        case .autoApprove:
            key = "自动批准"
        case .autoApproveHighRisk:
            key = "自动批准·高风险"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }
}
