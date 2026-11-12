import Foundation

/// Memoizes `AmberUnifiedTaskBuilder.Groups` across 120Hz `3+1` pill scrub and inline panel gestures.
/// Every store property read during `InputSnapshot` capture remains synchronously observed by SwiftUI's
/// `@Observable` tracking, while Swift's CoW collection `==` short-circuits unchanged buffers in O(1).
@MainActor
final class AmberUnifiedTaskProjectionCache {
    static let shared = AmberUnifiedTaskProjectionCache()

    private struct Key: Hashable {
        let gatewayID: ObjectIdentifier
        let subAgentID: ObjectIdentifier
        let taskStoreID: ObjectIdentifier
        let wakeStoreID: ObjectIdentifier
        let hubStoreID: ObjectIdentifier
        let filterHubId: String?
    }

    private struct InputSnapshot: Equatable {
        let connection: MacGatewayConnection?
        let cloudTasks: [MacGatewayCloudTaskRecord]
        let busyCloudTaskIds: Set<String>
        let cloudDialogueEvents: [MacGatewayCloudDialogueEvent]
        let cloudDialogueProgressByWorkItem: [String: MacGatewayCloudDialogueWorkItemProgress]
        let cloudDialogueFirstSeenAtByEventId: [String: Date]
        let boardItems: [MacGatewayBoardItem]
        let schedules: [MacGatewaySchedule]?
        let subAgentItems: [IOSSubAgentActivity]
        let subAgentBackingTasks: [IOSAdvancedTaskRecord]
        let advancedTasks: [IOSAdvancedTaskRecord]
        let wakeTasks: [IOSWakeTask]
        let hubs: [AmberHubItem]
        let filterHubId: String?
    }

    private struct Entry {
        let snapshot: InputSnapshot
        let groups: AmberUnifiedTaskBuilder.Groups
    }

    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []
    private let maxEntries = 16

    func groups(
        gateway: MacGatewayStore,
        subAgentStore: IOSSubAgentActivityStore,
        taskStore: IOSAdvancedTaskStore = .shared,
        wakeStore: IOSWakeTaskStore = .shared,
        hubStore: AmberHubStore,
        filterHubId: String? = nil
    ) -> AmberUnifiedTaskBuilder.Groups {
        let normalizedFilter = filterHubId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveFilter = (normalizedFilter?.isEmpty == true) ? nil : normalizedFilter
        let key = Key(
            gatewayID: ObjectIdentifier(gateway),
            subAgentID: ObjectIdentifier(subAgentStore),
            taskStoreID: ObjectIdentifier(taskStore),
            wakeStoreID: ObjectIdentifier(wakeStore),
            hubStoreID: ObjectIdentifier(hubStore),
            filterHubId: effectiveFilter
        )
        let snapshot = InputSnapshot(
            connection: gateway.connection,
            cloudTasks: gateway.cloudTasks,
            busyCloudTaskIds: gateway.busyCloudTaskIds,
            cloudDialogueEvents: gateway.cloudDialogueEvents,
            cloudDialogueProgressByWorkItem: gateway.cloudDialogueProgressByWorkItem,
            cloudDialogueFirstSeenAtByEventId: gateway.cloudDialogueFirstSeenAtByEventId,
            boardItems: gateway.boardItems,
            schedules: gateway.schedules,
            subAgentItems: subAgentStore.items,
            subAgentBackingTasks: subAgentStore.backingTaskRecords,
            advancedTasks: taskStore.tasks,
            wakeTasks: wakeStore.tasks,
            hubs: hubStore.hubs,
            filterHubId: effectiveFilter
        )
        if let existing = entries[key], existing.snapshot == snapshot {
            return existing.groups
        }
        let built = AmberUnifiedTaskBuilder.buildTasks(
            gateway: gateway,
            subAgentStore: subAgentStore,
            taskStore: taskStore,
            wakeStore: wakeStore,
            hubStore: hubStore,
            filterHubId: effectiveFilter
        )
        if entries[key] == nil {
            insertionOrder.append(key)
            if insertionOrder.count > maxEntries, let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = Entry(snapshot: snapshot, groups: built)
        return built
    }
}
