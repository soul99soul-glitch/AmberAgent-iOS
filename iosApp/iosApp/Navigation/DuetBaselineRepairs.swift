import Foundation
import Shared

/// Restores helper bridges referenced across the Duet / Argon 3+1 navigation and task stream files.
typealias ChatSubAgentAvatarIdentity = String

extension IOSSubAgentActivityStatus {
    init(_ status: IOSAdvancedTaskStatus) {
        switch status {
        case .running:
            self = .running
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        }
    }
}

extension IOSSubAgentActivityItem {
    var subtitle: String {
        statusTitle
    }
}

enum RouterDestination: Hashable {
    case search
    case novelCreation
    case board
    case council
    case miniApps
    case webMount
    case macTasks
    case account
    case settings

    var route: Route {
        switch self {
        case .search:
            return .search(initialQuery: "")
        case .novelCreation:
            return .novelCreation
        case .board:
            return .board
        case .council:
            return .council
        case .miniApps:
            return .miniApps
        case .webMount:
            return .webMount
        case .macTasks:
            return .macTasks
        case .account:
            return .account
        case .settings:
            return .settings
        }
    }
}
