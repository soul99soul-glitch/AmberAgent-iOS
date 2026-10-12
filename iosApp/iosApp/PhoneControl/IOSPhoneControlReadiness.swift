import AmberPhoneControl
import Foundation

/// The controller consumes the same session operations in production and ownership tests.
protocol IOSPhoneControlSessionServing: Sendable {
    func start(runID: UUID, configuration: PhoneControlLaunchConfiguration) async throws -> PhoneRunnerStatus
    func runner(runID: UUID) async throws -> PhoneRunnerClient
    func stop(runID: UUID) async
    func launchStatus(runID: UUID) async throws -> PhoneControlLaunchStatus?
    func cachedApplications(runID: UUID) async throws -> [PhoneControlInstalledApp]
}

extension PhoneControlSession: IOSPhoneControlSessionServing {}

struct IOSPhoneControlReadinessReport: Equatable {
    enum Stage: Equatable {
        case configuration, connection, runner, observation, cleanup

        var title: String {
            switch self {
            case .configuration: "配置"
            case .connection: "本地连接"
            case .runner: "开发会话与 runner"
            case .observation: "读取界面"
            case .cleanup: "关闭临时连接"
            }
        }
    }

    let startedAt: Date
    var completedAt: Date?
    var stage: Stage = .configuration
    /// An authenticated, ready runner proves the development connection also succeeded.
    var connectionVerifiedAt: Date?
    var uiReadAt: Date?
    var observedBundleID: String?
    var nodeCount: Int?
    var failureStage: Stage?
    var failureMessage: String?
    var wasCancelled = false
    var cleanupComplete = false
}
