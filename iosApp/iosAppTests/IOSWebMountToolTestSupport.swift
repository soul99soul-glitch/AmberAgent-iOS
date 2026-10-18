import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
class IOSWebMountToolTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        // Reset the shared mock session-id counter so each test starts from a
        // deterministic base (prevents the cross-test pollution that made
        // testWebMountTabLifecycleAndClosedSessionFailure order-dependent).
        MockWebMountRuntime.resetSessionCounter()
    }

    func makeExecutor(
        permissionStore: IOSPermissionStore? = nil,
        documentStore: DocumentAccessStore = DocumentAccessStore(),
        workspaceStore: IOSWorkspaceStore = IOSWorkspaceStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        webMountController: IOSWebMountController? = nil
    ) -> IOSLocalToolExecutor {
        IOSLocalToolExecutor(
            permissionStore: permissionStore ?? IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore,
            workspaceStore: workspaceStore,
            webMountController: webMountController
        )
    }

    func makeWebMountController(
        globalEnabled: Bool,
        resolveHost: @escaping IOSWebMountHostResolver = { _ in ["93.184.216.34"] }
    ) -> IOSWebMountController {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let settings = IOSWebMountSettings(userDefaults: defaults)
        settings.globalEnabled = globalEnabled
        return IOSWebMountController(
            registry: registry,
            settings: settings,
            cookieStore: MockWebMountCookieStore(),
            runtime: MockWebMountRuntime(),
            runtimeFactory: { MockWebMountRuntime() },
            resolveHost: resolveHost
        )
    }

    func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func makeTempFile(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data(repeating: 65, count: size).write(to: url)
        return url
    }

    func makeTempFile(text: String, extension fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try Data(text.utf8).write(to: url)
        return url
    }

    func makeWorkspaceStore() -> IOSWorkspaceStore {
        IOSWorkspaceStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }

    func utf8String(using scalar: String, bytes: Int) -> String {
        let scalarBytes = scalar.utf8.count
        let repetitions = bytes / scalarBytes
        let remainder = bytes % scalarBytes
        return String(repeating: scalar, count: repetitions)
            + String(repeating: "x", count: remainder)
    }

    func isolatedDefaults() -> UserDefaults {
        let suiteName = "app.amber.ios.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
