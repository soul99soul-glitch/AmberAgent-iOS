import XCTest
@testable import iosApp

final class IOSReleaseConfigurationTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testStableInfoPlistUsesReleaseSafeBackgroundAndTransportPolicy() throws {
        let info = try plist("iosApp/Info.plist")
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
        XCTAssertEqual(modes, ["processing"])

        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNil(ats["NSAllowsArbitraryLoads"])
        XCTAssertNil(ats["NSExceptionDomains"])
    }

    func testPrivacyManifestDeclaresRequiredReasonAPIsWithoutTracking() throws {
        let privacy = try plist("iosApp/PrivacyInfo.xcprivacy")
        XCTAssertEqual(privacy["NSPrivacyTracking"] as? Bool, false)

        let entries = try XCTUnwrap(privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry -> (String, Set<String>)? in
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                  let values = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else {
                return nil
            }
            return (category, Set(values))
            }
        )

        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1", "3B52.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
    }

    func testStableAndExperimentalTargetsOwnSeparateEntitlementFiles() throws {
        let stable = try plist("iosApp/AmberAgent.entitlements")
        let experimental = try plist("iosApp/AmberAgentExperimental.entitlements")
        let info = try plist("iosApp/Info.plist")
        let stableMirror = Set(try XCTUnwrap(info["AmberAgentConfiguredEntitlements"] as? [String]))
        let experimentalMirror = Set(try XCTUnwrap(info["AmberAgentExperimentalConfiguredEntitlements"] as? [String]))

        XCTAssertEqual(Set(stable.keys), stableMirror)
        XCTAssertEqual(Set(experimental.keys), experimentalMirror)
        XCTAssertEqual(stable["com.apple.developer.healthkit"] as? Bool, true)
        XCTAssertEqual(stable["com.apple.developer.weatherkit"] as? Bool, true)
        XCTAssertEqual(stable["com.apple.developer.icloud-services"] as? [String], ["CloudKit"])
        XCTAssertEqual(
            stable["com.apple.developer.icloud-container-identifiers"] as? [String],
            ["iCloud.app.amber.ios"]
        )
        XCTAssertEqual(stable["com.apple.developer.applesignin"] as? [String], ["Default"])
        XCTAssertEqual(stable["aps-environment"] as? String, "$(APS_ENVIRONMENT)")
        XCTAssertEqual(
            stable["com.apple.developer.devicecheck.appattest-environment"] as? String,
            "$(APP_ATTEST_ENVIRONMENT)"
        )
        XCTAssertNil(experimental["com.apple.developer.healthkit"])
        XCTAssertNil(experimental["com.apple.developer.weatherkit"])
        XCTAssertNil(experimental["com.apple.developer.icloud-services"])
        XCTAssertNil(experimental["com.apple.developer.applesignin"])
        XCTAssertNil(experimental["aps-environment"])
        XCTAssertNil(experimental["com.apple.developer.devicecheck.appattest-environment"])
        XCTAssertNil(stable["com.apple.developer.associated-domains"])
        XCTAssertNil(experimental["com.apple.developer.associated-domains"])

        let project = try String(
            contentsOf: appRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS: iosApp/AmberAgent.entitlements"))
        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS: iosApp/AmberAgentExperimental.entitlements"))
        XCTAssertTrue(project.contains("Prepare Experimental Info.plist"))
        XCTAssertTrue(project.contains("AmberExperimental-Info.plist"))
        XCTAssertTrue(project.contains("UIBackgroundModes -json '[\"audio\",\"processing\"]'"))
        XCTAssertFalse(project.contains("Enable Experimental Audio Background Mode"))
        XCTAssertTrue(project.contains("AmberAgentExperimentalConfiguredEntitlements"))
        XCTAssertTrue(project.contains("APS_ENVIRONMENT: production"))
        XCTAssertTrue(project.contains("APP_ATTEST_ENVIRONMENT: production"))
    }

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
    }
}
