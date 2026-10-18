import XCTest
@testable import iosApp

@MainActor
final class IOSPermissionStoreTests: XCTestCase {
    func testOnlyUnsupportedCapabilitiesAreForcedDisabled() throws {
        let store = IOSPermissionStore(userDefaults: isolatedDefaults())
        let unsupported = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "android.sms.read" }
        )
        let entitlement = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.health.read" }
        )
        let direct = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.location.when_in_use" }
        )

        store.setPolicy(.askEveryTime, for: unsupported)
        XCTAssertEqual(store.policy(for: unsupported), .disabled)
        XCTAssertEqual(store.availablePolicies(for: unsupported), [.disabled])

        XCTAssertTrue(store.availablePolicies(for: entitlement).contains(.askEveryTime))
        XCTAssertTrue(store.availablePolicies(for: direct).contains(.askEveryTime))
    }

    func testHighAndFreshPresenceCapabilitiesDoNotOfferRunScopedReuse() throws {
        let camera = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.camera.capture" }
        )
        XCTAssertFalse(IOSPermissionStore.availablePolicies(for: camera).contains(.allowOncePerRun))
    }

    func testRunScopedReuseIsNotOfferedUntilRunScopeExists() throws {
        let photos = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.photos.library_read" }
        )
        XCTAssertFalse(IOSPermissionStore.availablePolicies(for: photos).contains(.allowOncePerRun))
    }

    func testPolicyPersistsAndUnsafeRunScopedPolicyIsNormalized() throws {
        let defaults = isolatedDefaults()
        let storageKey = "test.permissionPolicies"
        let fileCapability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.files.selected_read" }
        )

        var raw = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        raw["unknown.capability"] = IOSAgentPermissionPolicy.askEveryTime.rawValue
        raw[fileCapability.id] = IOSAgentPermissionPolicy.allowOncePerRun.rawValue
        defaults.set(raw, forKey: storageKey)

        let firstStore = IOSPermissionStore(userDefaults: defaults, storageKey: storageKey)
        XCTAssertEqual(firstStore.policy(for: fileCapability), .askEveryTime)

        firstStore.setPolicy(.allowOncePerRun, for: fileCapability)

        let secondStore = IOSPermissionStore(userDefaults: defaults, storageKey: storageKey)
        XCTAssertEqual(secondStore.policy(for: fileCapability), .askEveryTime)

        let persisted = try XCTUnwrap(defaults.dictionary(forKey: storageKey) as? [String: String])
        XCTAssertNil(persisted["unknown.capability"])
        XCTAssertEqual(persisted[fileCapability.id], IOSAgentPermissionPolicy.askEveryTime.rawValue)
    }

    func testDefaultPolicyMigrationRestoresLegacyDisabledValueOnlyOnce() throws {
        let defaults = isolatedDefaults()
        let storageKey = "test.permissionPolicies.migration"
        let capability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.local.ambershell" }
        )
        defaults.set(
            [capability.id: IOSAgentPermissionPolicy.disabled.rawValue],
            forKey: storageKey
        )

        let migrated = IOSPermissionStore(
            capabilities: [capability],
            userDefaults: defaults,
            storageKey: storageKey,
            defaultPolicyMigrationIds: [capability.id],
            taskStore: nil
        )
        XCTAssertEqual(migrated.policy(for: capability), .askEveryTime)

        migrated.setPolicy(.disabled, for: capability)
        let reloaded = IOSPermissionStore(
            capabilities: [capability],
            userDefaults: defaults,
            storageKey: storageKey,
            defaultPolicyMigrationIds: [capability.id],
            taskStore: nil
        )
        XCTAssertEqual(reloaded.policy(for: capability), .disabled)
    }

    func testUnavailableBuildPreservesSavedIshPolicyWithoutMakingItExecutable() throws {
        let defaults = isolatedDefaults()
        let storageKey = "test.permissionPolicies.buildSwitch"
        let supported = embeddedIshCapability(status: .supported)
        let unsupported = embeddedIshCapability(status: .unsupported)
        let unrelated = try XCTUnwrap(IOSCapabilityRegistry.capabilities.first { $0.id == "ios.local.ambershell" })
        defaults.set([supported.id: IOSAgentPermissionPolicy.askEveryTime.rawValue], forKey: storageKey)

        let unavailableBuild = IOSPermissionStore(
            capabilities: [unsupported, unrelated],
            userDefaults: defaults,
            storageKey: storageKey,
            taskStore: nil
        )
        XCTAssertEqual(unavailableBuild.policy(for: unsupported), .disabled)
        // Saving an unrelated setting must not replace a temporarily unavailable runtime's choice.
        unavailableBuild.setPolicy(.disabled, for: unrelated)
        XCTAssertEqual(defaults.dictionary(forKey: storageKey)?[supported.id] as? String, "askEveryTime")

        let availableBuild = IOSPermissionStore(
            capabilities: [supported, unrelated],
            userDefaults: defaults,
            storageKey: storageKey,
            taskStore: nil
        )
        XCTAssertEqual(availableBuild.policy(for: supported), .askEveryTime)
        availableBuild.setPolicy(.disabled, for: supported)
        let unavailableAgain = IOSPermissionStore(
            capabilities: [unsupported, unrelated],
            userDefaults: defaults,
            storageKey: storageKey,
            taskStore: nil
        )
        unavailableAgain.setPolicy(.askEveryTime, for: unrelated)
        let availableAgain = IOSPermissionStore(
            capabilities: [supported, unrelated],
            userDefaults: defaults,
            storageKey: storageKey,
            taskStore: nil
        )
        XCTAssertEqual(availableAgain.policy(for: supported), .disabled)
    }

    func testApprovalRecordsPersistAndRedactSensitiveValues() throws {
        let defaults = isolatedDefaults()
        let store = IOSPermissionStore(userDefaults: defaults, taskStore: nil)

        store.recordApproval(
            capabilityId: "ios.remote.command",
            toolName: "remote_command_run",
            action: .allowed,
            reason: "password=secret token=abc123",
            runId: "run-1",
            scopeDigest: "scope-digest",
            payloadDigest: "payload-digest",
            policyDigest: "policy-digest"
        )

        let reloaded = IOSPermissionStore(userDefaults: defaults, taskStore: nil)
        let record = try XCTUnwrap(reloaded.latestApproval(
            for: try XCTUnwrap(IOSCapabilityRegistry.capabilities.first { $0.id == "ios.remote.command" })
        ))

        XCTAssertEqual(record.action, .allowed)
        XCTAssertEqual(record.toolName, "remote_command_run")
        XCTAssertFalse(record.reason.contains("secret"))
        XCTAssertFalse(record.reason.contains("abc123"))
        XCTAssertEqual(record.scopeDigest, "scope-digest")
        XCTAssertEqual(record.payloadDigest, "payload-digest")
        XCTAssertEqual(record.policyDigest, "policy-digest")
    }

    func testHighRiskAdvancedCapabilitiesDoNotOfferRunScopedReuse() throws {
        let mcp = try XCTUnwrap(IOSCapabilityRegistry.capabilities.first { $0.id == "ios.mcp.tool_call" })
        let remote = try XCTUnwrap(IOSCapabilityRegistry.capabilities.first { $0.id == "ios.remote.command" })

        XCTAssertEqual(mcp.risk, .high)
        XCTAssertEqual(remote.risk, .high)
        XCTAssertFalse(IOSPermissionStore.availablePolicies(for: mcp).contains(.allowOncePerRun))
        XCTAssertFalse(IOSPermissionStore.availablePolicies(for: remote).contains(.allowOncePerRun))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "app.amber.ios.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func embeddedIshCapability(status: IOSCapabilityStatus) -> IOSPlatformCapability {
        IOSPlatformCapability(
            id: "ios.embedded.ish_runtime", title: "Embedded iSH", summary: "Build-dependent runtime",
            domain: .networkAndConnectivity, status: status, risk: .high,
            requestKind: status == .supported ? .foregroundSession : .unsupported,
            requestEntryPoint: "ios_ish_execute", uiActionNames: [],
            modelToolNames: status == .supported ? ["ios_ish_execute"] : [],
            blockedToolNames: [], unavailableReason: nil, requiredInfoPlistKeys: [],
            requiredEntitlements: [], requiredBackgroundModes: [], requiredExtensionTargets: [],
            defaultEnabled: true, canOpenSettings: false,
            gate: IOSPlatformToolGate(requiresFreshUserPresence: true, allowRunScopedReuse: false, allowGlobalAutoApproval: false)
        )
    }
}
