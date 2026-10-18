import Foundation
import CryptoKit

enum IOSToolApprovalAction: String, Codable, Equatable, Identifiable {
    case allowed
    case denied
    case asked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .asked: "Asked"
        }
    }
}

/// Immutable, secret-free policy values captured once when an agent run starts.
/// Tool declarations are already frozen in `TextGenerationParams`; this snapshot
/// closes the remaining execution-time policy reads that used to change between
/// provider rounds or after a foreground-to-background handoff.
struct IOSExecutionPolicySnapshot: Codable, Equatable, Sendable {
    let capabilityPolicies: [String: String]
    let globalAutoApproveEnabled: Bool
    let highRiskAutoApproveEnabled: Bool
    let execJavaScriptEnabled: Bool
    let webSearchEnabled: Bool
    let mcpEnabled: Bool?

    init(
        capabilityPolicies: [String: String],
        globalAutoApproveEnabled: Bool,
        highRiskAutoApproveEnabled: Bool,
        execJavaScriptEnabled: Bool,
        webSearchEnabled: Bool,
        mcpEnabled: Bool? = nil
    ) {
        self.capabilityPolicies = capabilityPolicies
        self.globalAutoApproveEnabled = globalAutoApproveEnabled
        self.highRiskAutoApproveEnabled = highRiskAutoApproveEnabled
        self.execJavaScriptEnabled = execJavaScriptEnabled
        self.webSearchEnabled = webSearchEnabled
        self.mcpEnabled = mcpEnabled
    }

    /// Jev 自动批准复核收紧时使用：关闭全局与高风险自动批准，并把逐能力的自动批准
    /// 降为每次询问（仅限该能力提供"每次询问"选项）；其余保持不变。
    func withoutAutoApprove() -> IOSExecutionPolicySnapshot {
        var policies = capabilityPolicies
        for capability in IOSCapabilityRegistry.capabilities
        where [.autoApprove, .autoApproveHighRisk].contains(policy(for: capability))
            && IOSPermissionStore.availablePolicies(for: capability).contains(.askEveryTime) {
            policies[capability.id] = IOSAgentPermissionPolicy.askEveryTime.rawValue
        }
        return IOSExecutionPolicySnapshot(
            capabilityPolicies: policies,
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: execJavaScriptEnabled,
            webSearchEnabled: webSearchEnabled,
            mcpEnabled: mcpEnabled
        )
    }

    func policy(for capability: IOSPlatformCapability) -> IOSAgentPermissionPolicy {
        capabilityPolicies[capability.id]
            .flatMap(IOSAgentPermissionPolicy.init(rawValue:))
            ?? IOSPermissionStore.defaultPolicy(for: capability)
    }

    var encodedJSON: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var digest: String {
        let data = Data((encodedJSON ?? "{}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(json: String) -> IOSExecutionPolicySnapshot? {
        try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

struct IOSToolApprovalRecord: Codable, Equatable, Identifiable {
    var id: String
    var capabilityId: String
    var toolName: String
    var action: IOSToolApprovalAction
    var reason: String
    var runId: String
    var scopeDigest: String
    var payloadDigest: String
    var policyDigest: String? = nil
    var createdAt: Date
}

@MainActor
@Observable
final class IOSPermissionStore {
    var policies: [String: IOSAgentPermissionPolicy]
    var approvalRecords: [IOSToolApprovalRecord]
    private let capabilities: [IOSPlatformCapability]
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let approvalStorageKey: String
    @ObservationIgnored private let taskStore: IOSAdvancedTaskStore?

    init(
        capabilities: [IOSPlatformCapability] = IOSCapabilityRegistry.capabilities,
        userDefaults: UserDefaults = .standard,
        storageKey: String = "app.amber.ios.permissionPolicies.v2",
        approvalStorageKey: String = "app.amber.ios.toolApprovalRecords.v1",
        defaultPolicyMigrationIds: Set<String> = [],
        taskStore: IOSAdvancedTaskStore? = IOSAdvancedTaskStore.shared
    ) {
        self.capabilities = capabilities
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.approvalStorageKey = approvalStorageKey
        self.taskStore = taskStore

        let defaults = Dictionary(
            uniqueKeysWithValues: capabilities.map { capability in
                return (capability.id, Self.defaultPolicy(for: capability))
            }
        )
        let allowedIds = Set(capabilities.map(\.id))
        let savedRaw = userDefaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        var loaded = defaults
        var didDropUnknown = false

        for (id, rawPolicy) in savedRaw {
            guard allowedIds.contains(id) else {
                didDropUnknown = true
                continue
            }
            guard let capability = capabilities.first(where: { $0.id == id }),
                  let policy = IOSAgentPermissionPolicy(rawValue: rawPolicy) else {
                didDropUnknown = true
                continue
            }
            // Target availability must not erase a previously saved user choice.
            // policy(for:) still blocks unsupported capabilities in this build.
            if capability.status == .unsupported {
                loaded[id] = policy
                continue
            }
            guard let normalizedPolicy = Self.normalizedPolicy(policy, for: capability) else {
                didDropUnknown = true
                continue
            }
            loaded[id] = normalizedPolicy
            if normalizedPolicy != policy {
                didDropUnknown = true
            }
        }

        for id in defaultPolicyMigrationIds {
            let migrationKey = "\(storageKey).default-policy-migration.v1.\(id)"
            guard !userDefaults.bool(forKey: migrationKey) else { continue }
            if savedRaw[id] == IOSAgentPermissionPolicy.disabled.rawValue,
               let capability = capabilities.first(where: { $0.id == id }),
               Self.defaultPolicy(for: capability) != .disabled {
                loaded[id] = Self.defaultPolicy(for: capability)
                didDropUnknown = true
            }
            userDefaults.set(true, forKey: migrationKey)
        }

        policies = loaded
        approvalRecords = Self.loadApprovalRecords(from: userDefaults, key: approvalStorageKey)
        if didDropUnknown || savedRaw.isEmpty == false {
            persist()
        }
    }

    func policy(for capability: IOSPlatformCapability) -> IOSAgentPermissionPolicy {
        let policy = policies[capability.id] ?? Self.defaultPolicy(for: capability)
        return Self.normalizedPolicy(policy, for: capability) ?? Self.defaultPolicy(for: capability)
    }

    func setPolicy(_ policy: IOSAgentPermissionPolicy, for capability: IOSPlatformCapability) {
        guard let normalizedPolicy = Self.normalizedPolicy(policy, for: capability) else { return }
        policies[capability.id] = normalizedPolicy
        persist()
    }

    @discardableResult
    func recordApproval(
        capabilityId: String,
        toolName: String,
        action: IOSToolApprovalAction,
        reason: String,
        runId: String = "",
        scopeDigest: String = "",
        payloadDigest: String = "",
        policyDigest: String? = nil,
        now: Date = Date()
    ) -> IOSToolApprovalRecord {
        let record = IOSToolApprovalRecord(
            id: UUID().uuidString,
            capabilityId: capabilityId,
            toolName: IOSAdvancedTaskStore.redacted(toolName),
            action: action,
            reason: IOSAdvancedTaskStore.redacted(reason),
            runId: IOSAdvancedTaskStore.redacted(runId),
            scopeDigest: IOSAdvancedTaskStore.redacted(scopeDigest),
            payloadDigest: IOSAdvancedTaskStore.redacted(payloadDigest),
            policyDigest: policyDigest.map(IOSAdvancedTaskStore.redacted),
            createdAt: now
        )
        approvalRecords.insert(record, at: 0)
        approvalRecords = Array(approvalRecords.prefix(120))
        persistApprovalRecords()
        let task = taskStore?.startTask(
            kind: .toolApproval,
            title: "Approval · \(record.toolName)",
            objective: record.reason,
            toolScope: [record.toolName],
            sourceToolName: record.toolName,
            metadata: [
                "capability_id": capabilityId,
                "action": action.rawValue
            ],
            now: now
        )
        _ = taskStore?.updateTask(
            id: task?.id ?? record.id,
            status: action == .denied ? .failed : .completed,
            resultSummary: "\(action.title): \(record.reason)",
            retryable: false,
            cancelCapability: false,
            now: now
        )
        return record
    }

    func latestApproval(for capability: IOSPlatformCapability) -> IOSToolApprovalRecord? {
        approvalRecords.first { $0.capabilityId == capability.id }
    }

    func availablePolicies(for capability: IOSPlatformCapability) -> [IOSAgentPermissionPolicy] {
        Self.availablePolicies(for: capability)
    }

    nonisolated static func availablePolicies(for capability: IOSPlatformCapability) -> [IOSAgentPermissionPolicy] {
        if capability.status == .unsupported {
            return [.disabled]
        }
        if capability.id == "ios.agent.subagent_dispatch" {
            // Dispatching a read-only worker is orchestration, not an external
            // side effect. Its nested tools keep their own permission gates.
            return [.disabled, .autoApprove]
        }
        if capability.risk == .high || capability.gate.requiresFreshUserPresence {
            // 高风险工具：禁用 / 每次询问 / 高风险自动批准
            return [.disabled, .askEveryTime, .autoApproveHighRisk]
        }
        // 普通工具：禁用 / 每次询问 / 自动批准
        return [.disabled, .askEveryTime, .autoApprove]
    }

    nonisolated static func defaultPolicy(for capability: IOSPlatformCapability) -> IOSAgentPermissionPolicy {
        if capability.id == "ios.agent.subagent_dispatch" {
            return capability.defaultEnabled ? .autoApprove : .disabled
        }
        let preferred: IOSAgentPermissionPolicy = capability.defaultEnabled ? .askEveryTime : .disabled
        return availablePolicies(for: capability).contains(preferred)
            ? preferred
            : (availablePolicies(for: capability).first ?? .disabled)
    }

    static func normalizedPolicy(
        _ policy: IOSAgentPermissionPolicy,
        for capability: IOSPlatformCapability
    ) -> IOSAgentPermissionPolicy? {
        let supportedPolicies = availablePolicies(for: capability)
        if supportedPolicies.contains(policy) {
            return policy
        }
        if policy == .allowOncePerRun, supportedPolicies.contains(.askEveryTime) {
            return .askEveryTime
        }
        return nil
    }

    func decisionSummary(
        for capability: IOSPlatformCapability,
        globalAutoApproval: Bool = false,
        highRiskAutoApproval: Bool = false
    ) -> String {
        let policy = policy(for: capability)
        if capability.status == .unsupported {
            return "Unavailable: \(capability.unavailableReason ?? "not available on iOS")"
        }
        if capability.requestKind == .entitlementRequired {
            return "Requires entitlement before system request"
        }
        if capability.requestKind == .extensionTargetRequired {
            return "Requires extension target"
        }
        if capability.requestKind == .entitlementAndExtensionRequired {
            return "Requires entitlement and extension target"
        }
        if capability.requestKind == .settingsOnly {
            return "Managed in system Settings"
        }
        if policy == .disabled {
            return "Agent use disabled; system request still visible"
        }
        if capability.gate.requiresFreshUserPresence {
            return "Requires foreground user action"
        }
        if !capability.gate.allowGlobalAutoApproval && (globalAutoApproval || highRiskAutoApproval) {
            return "Auto-approval ignored"
        }
        return "Ask before agent use"
    }

    private func persist() {
        let currentCapabilityIds = Set(capabilities.map(\.id))
        let raw = policies
            .filter { currentCapabilityIds.contains($0.key) }
            .mapValues(\.rawValue)
        userDefaults.set(raw, forKey: storageKey)
    }

    private func persistApprovalRecords() {
        if let data = try? JSONEncoder().encode(approvalRecords) {
            userDefaults.set(data, forKey: approvalStorageKey)
        }
    }

    private static func loadApprovalRecords(from defaults: UserDefaults, key: String) -> [IOSToolApprovalRecord] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([IOSToolApprovalRecord].self, from: data) else {
            return []
        }
        return Array(decoded.sorted { $0.createdAt > $1.createdAt }.prefix(120))
    }
}
