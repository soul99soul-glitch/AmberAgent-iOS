import AuthenticationServices
import Foundation
import Observation

struct IOSAppleAccountCredential: Equatable, Sendable {
    let userIdentifier: String
    let displayName: String?
}

enum IOSAppleAccountCredentialState: Equatable, Sendable {
    case authorized
    case revoked
    case notFound
}

@MainActor
protocol IOSAppleCredentialStateProviding: AnyObject {
    func credentialState(for userIdentifier: String) async throws -> IOSAppleAccountCredentialState
}

@MainActor
final class IOSSystemAppleCredentialStateProvider: IOSAppleCredentialStateProviding {
    private let provider = ASAuthorizationAppleIDProvider()

    func credentialState(for userIdentifier: String) async throws -> IOSAppleAccountCredentialState {
        try await withCheckedThrowingContinuation { continuation in
            provider.getCredentialState(forUserID: userIdentifier) { state, error in
                continuation.resume(with: Self.mapCredentialState(state, error: error))
            }
        }
    }

    /// Maps Apple's (state, error) callback pair onto our state. Per
    /// ASAuthorizationAppleIDProvider.h, a `.notFound` result always arrives
    /// with a companion error, so state wins there; any other state paired with
    /// an error is treated as a real failure.
    nonisolated static func mapCredentialState(
        _ state: ASAuthorizationAppleIDProvider.CredentialState,
        error: Error?
    ) -> Result<IOSAppleAccountCredentialState, Error> {
        if let error, state != .notFound {
            return .failure(error)
        }
        switch state {
        case .authorized:
            return .success(.authorized)
        case .revoked:
            return .success(.revoked)
        case .notFound, .transferred:
            return .success(.notFound)
        @unknown default:
            if let error { return .failure(error) }
            return .success(.notFound)
        }
    }
}

protocol IOSAppleAccountStoring: AnyObject {
    var userIdentifier: String? { get }
    var displayName: String? { get }
    func save(_ credential: IOSAppleAccountCredential) -> Bool
    func clear()
}

final class IOSKeychainAppleAccountStore: IOSAppleAccountStoring {
    private enum Key {
        static let userIdentifier = "apple-account.user-identifier"
        static let displayName = "apple-account.display-name"
    }

    var userIdentifier: String? { IOSCredentialSideTable.load(key: Key.userIdentifier) }
    var displayName: String? { IOSCredentialSideTable.load(key: Key.displayName) }

    func save(_ credential: IOSAppleAccountCredential) -> Bool {
        guard IOSCredentialSideTable.store(
            key: Key.userIdentifier,
            value: credential.userIdentifier
        ) else { return false }
        if let name = credential.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            _ = IOSCredentialSideTable.store(key: Key.displayName, value: name)
        }
        return true
    }

    func clear() {
        IOSCredentialSideTable.delete(key: Key.userIdentifier)
        IOSCredentialSideTable.delete(key: Key.displayName)
    }
}

@MainActor
@Observable
final class IOSAppleSignInModel {
    enum State: Equatable {
        case unavailable
        case localOnly
        case checking
        case signedIn(displayName: String)
        case revoked
        case failed(String)
    }

    private(set) var state: State = .localOnly

    @ObservationIgnored private let store: any IOSAppleAccountStoring
    @ObservationIgnored private let credentialStateProvider: any IOSAppleCredentialStateProviding
    @ObservationIgnored private let isConfigured: Bool
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var revocationObserver: NSObjectProtocol?

    init(
        store: any IOSAppleAccountStoring = IOSKeychainAppleAccountStore(),
        credentialStateProvider: any IOSAppleCredentialStateProviding = IOSSystemAppleCredentialStateProvider(),
        isConfigured: Bool? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.credentialStateProvider = credentialStateProvider
        self.notificationCenter = notificationCenter
        self.isConfigured = isConfigured ?? Self.currentTargetHasSignInWithAppleEntitlementMirror()
        if !self.isConfigured {
            state = .unavailable
        } else {
            // The system posts this when the user revokes the app's access in
            // Settings → Apple Account; re-check so the local binding clears
            // without waiting for the next manual refresh.
            revocationObserver = notificationCenter.addObserver(
                forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.systemCredentialRevoked()
                }
            }
        }
    }

    deinit {
        if let revocationObserver {
            notificationCenter.removeObserver(revocationObserver)
        }
    }

    /// Re-checks the stored binding after the system reports a revoked Apple
    /// credential. No-op when nothing is bound locally.
    func systemCredentialRevoked() async {
        guard store.userIdentifier != nil else { return }
        await refresh()
    }

    func refresh() async {
        guard isConfigured else {
            state = .unavailable
            return
        }
        guard let identifier = store.userIdentifier else {
            state = .localOnly
            return
        }
        state = .checking
        do {
            switch try await credentialStateProvider.credentialState(for: identifier) {
            case .authorized:
                state = .signedIn(displayName: store.displayName ?? "Apple 用户")
            case .revoked, .notFound:
                store.clear()
                state = .revoked
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func complete(_ credential: IOSAppleAccountCredential) {
        guard isConfigured else {
            state = .unavailable
            return
        }
        guard !credential.userIdentifier.isEmpty, store.save(credential) else {
            state = .failed("无法把 Apple 账户绑定保存到本机钥匙串。")
            return
        }
        state = .signedIn(displayName: credential.displayName ?? store.displayName ?? "Apple 用户")
    }

    func fail(_ error: Error) {
        let authorizationError = error as? ASAuthorizationError
        if authorizationError?.code == .canceled {
            state = store.userIdentifier == nil
                ? .localOnly
                : .signedIn(displayName: store.displayName ?? "Apple 用户")
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    func unlinkLocalAccount() {
        store.clear()
        state = .localOnly
    }

    static func currentTargetHasSignInWithAppleEntitlementMirror(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        let key = bundleIdentifier?.hasSuffix(".experimental-gpl") == true
            ? "AmberAgentExperimentalConfiguredEntitlements"
            : "AmberAgentConfiguredEntitlements"
        let configured = infoDictionary?[key] as? [String] ?? []
        return configured.contains("com.apple.developer.applesignin")
    }
}
