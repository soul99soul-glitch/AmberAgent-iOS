import AuthenticationServices
import Foundation
import XCTest
@testable import iosApp

private final class FakeAppleAccountStore: IOSAppleAccountStoring {
    var userIdentifier: String?
    var displayName: String?
    var saveSucceeds = true

    func save(_ credential: IOSAppleAccountCredential) -> Bool {
        guard saveSucceeds else { return false }
        userIdentifier = credential.userIdentifier
        displayName = credential.displayName
        return true
    }

    func clear() {
        userIdentifier = nil
        displayName = nil
    }
}

@MainActor
private final class FakeAppleCredentialStateProvider: IOSAppleCredentialStateProviding {
    var result: Result<IOSAppleAccountCredentialState, Error> = .success(.authorized)
    private(set) var checkedIdentifiers: [String] = []

    func credentialState(for userIdentifier: String) async throws -> IOSAppleAccountCredentialState {
        checkedIdentifiers.append(userIdentifier)
        return try result.get()
    }
}

@MainActor
final class IOSAppleSignInTests: XCTestCase {
    func testLocalFirstStateDoesNotRequireAppleAccount() async {
        let store = FakeAppleAccountStore()
        let provider = FakeAppleCredentialStateProvider()
        let model = IOSAppleSignInModel(store: store, credentialStateProvider: provider, isConfigured: true)

        await model.refresh()

        XCTAssertEqual(model.state, .localOnly)
        XCTAssertTrue(provider.checkedIdentifiers.isEmpty)
    }

    func testAuthorizedStoredAccountRefreshesAndCanUnlinkLocally() async {
        let store = FakeAppleAccountStore()
        store.userIdentifier = "apple-user"
        store.displayName = "Amber User"
        let provider = FakeAppleCredentialStateProvider()
        let model = IOSAppleSignInModel(store: store, credentialStateProvider: provider, isConfigured: true)

        await model.refresh()
        XCTAssertEqual(model.state, .signedIn(displayName: "Amber User"))

        model.unlinkLocalAccount()
        XCTAssertEqual(model.state, .localOnly)
        XCTAssertNil(store.userIdentifier)
    }

    func testRevokedCredentialClearsLocalBinding() async {
        let store = FakeAppleAccountStore()
        store.userIdentifier = "revoked-user"
        let provider = FakeAppleCredentialStateProvider()
        provider.result = .success(.revoked)
        let model = IOSAppleSignInModel(store: store, credentialStateProvider: provider, isConfigured: true)

        await model.refresh()

        XCTAssertEqual(model.state, .revoked)
        XCTAssertNil(store.userIdentifier)
    }

    func testCompletedAuthorizationPersistsOnlyAccountBoundary() {
        let store = FakeAppleAccountStore()
        let model = IOSAppleSignInModel(
            store: store,
            credentialStateProvider: FakeAppleCredentialStateProvider(),
            isConfigured: true
        )

        model.complete(IOSAppleAccountCredential(
            userIdentifier: "new-user",
            displayName: "New User"
        ))

        XCTAssertEqual(model.state, .signedIn(displayName: "New User"))
        XCTAssertEqual(store.userIdentifier, "new-user")
    }

    func testNotFoundCompanionErrorMapsToNotFound() {
        // getCredentialState documents a companion error alongside .notFound;
        // state must win so a missing binding unbinds instead of failing.
        let mapped = IOSSystemAppleCredentialStateProvider.mapCredentialState(
            .notFound,
            error: ASAuthorizationError(.unknown)
        )
        XCTAssertEqual(try? mapped.get(), .notFound)
    }

    func testErrorWithNonNotFoundStateStillFails() {
        let mapped = IOSSystemAppleCredentialStateProvider.mapCredentialState(
            .revoked,
            error: ASAuthorizationError(.failed)
        )
        XCTAssertThrowsError(try mapped.get())
    }

    func testMirrorSelectsExperimentalKeyForExperimentalBundleId() {
        let info: [String: Any] = [
            "AmberAgentConfiguredEntitlements": ["com.apple.developer.applesignin"],
            "AmberAgentExperimentalConfiguredEntitlements": ["com.apple.security.application-groups"],
        ]
        XCTAssertFalse(IOSAppleSignInModel.currentTargetHasSignInWithAppleEntitlementMirror(
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: info
        ))
        XCTAssertTrue(IOSAppleSignInModel.currentTargetHasSignInWithAppleEntitlementMirror(
            bundleIdentifier: "app.amber.ios",
            infoDictionary: info
        ))
    }

    func testSystemCredentialRevokedClearsStoredBinding() async {
        let store = FakeAppleAccountStore()
        store.userIdentifier = "revoked-user"
        store.displayName = "Old Name"
        let provider = FakeAppleCredentialStateProvider()
        provider.result = .success(.revoked)
        let model = IOSAppleSignInModel(
            store: store,
            credentialStateProvider: provider,
            isConfigured: true,
            notificationCenter: NotificationCenter()
        )

        await model.systemCredentialRevoked()

        XCTAssertEqual(model.state, .revoked)
        XCTAssertNil(store.userIdentifier)
    }

    func testSystemCredentialRevokedWithoutBindingStaysLocalOnly() async {
        let store = FakeAppleAccountStore()
        let provider = FakeAppleCredentialStateProvider()
        let model = IOSAppleSignInModel(
            store: store,
            credentialStateProvider: provider,
            isConfigured: true,
            notificationCenter: NotificationCenter()
        )

        await model.systemCredentialRevoked()

        XCTAssertEqual(model.state, .localOnly)
        XCTAssertTrue(provider.checkedIdentifiers.isEmpty)
    }

    func testRevokedNotificationPostTriggersRecheck() async {
        let store = FakeAppleAccountStore()
        store.userIdentifier = "revoked-user"
        let provider = FakeAppleCredentialStateProvider()
        provider.result = .success(.revoked)
        let center = NotificationCenter()
        let model = IOSAppleSignInModel(
            store: store,
            credentialStateProvider: provider,
            isConfigured: true,
            notificationCenter: center
        )

        center.post(
            name: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil
        )

        for _ in 0..<50 where model.state != .revoked {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.state, .revoked)
        XCTAssertNil(store.userIdentifier)
    }
}
