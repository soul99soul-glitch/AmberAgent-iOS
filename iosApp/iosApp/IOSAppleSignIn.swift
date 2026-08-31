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
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                switch state {
                case .authorized:
                    continuation.resume(returning: .authorized)
                case .revoked:
                    continuation.resume(returning: .revoked)
                case .notFound, .transferred:
                    continuation.resume(returning: .notFound)
                @unknown default:
                    continuation.resume(returning: .notFound)
                }
            }
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

    init(
        store: any IOSAppleAccountStoring = IOSKeychainAppleAccountStore(),
        credentialStateProvider: any IOSAppleCredentialStateProviding = IOSSystemAppleCredentialStateProvider(),
        isConfigured: Bool? = nil
    ) {
        self.store = store
        self.credentialStateProvider = credentialStateProvider
        self.isConfigured = isConfigured ?? Self.currentTargetHasSignInWithAppleEntitlementMirror()
        if !self.isConfigured {
            state = .unavailable
        }
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
