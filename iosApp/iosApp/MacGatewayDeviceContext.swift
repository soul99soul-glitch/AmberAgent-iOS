import EventKit
import Foundation
import UIKit
import os

extension MacGatewayStore {
    private static let deviceContextLogger = Logger(subsystem: "app.amber.agent", category: "DeviceContext")
    static let deviceContextForegroundThrottleSeconds: TimeInterval = 600

    enum DeviceContextSyncTrigger: Sendable {
        case foreground
        case toggleChanged
        case manual
    }

    var anyDeviceContextSharingEnabled: Bool {
        shareCalendarUpcomingEnabled || shareRemindersDueEnabled || shareWorkspaceArtifactsEnabled
    }

    func setShareCalendarUpcoming(_ enabled: Bool) {
        shareCalendarUpcomingEnabled = enabled
        defaults.set(enabled, forKey: Self.shareCalendarUpcomingKey)
        Task { await handleDeviceContextToggleChanged(turnedOff: !enabled) }
    }

    func setShareRemindersDue(_ enabled: Bool) {
        shareRemindersDueEnabled = enabled
        defaults.set(enabled, forKey: Self.shareRemindersDueKey)
        Task { await handleDeviceContextToggleChanged(turnedOff: !enabled) }
    }

    func setShareWorkspaceArtifacts(_ enabled: Bool) {
        shareWorkspaceArtifactsEnabled = enabled
        defaults.set(enabled, forKey: Self.shareWorkspaceArtifactsKey)
        Task { await handleDeviceContextToggleChanged(turnedOff: !enabled) }
    }

    func handleForegroundBecameActive() async {
        guard connection != nil else { return }
        await flushPendingDeviceContextDeleteIfNeeded()
        await syncDeviceContextIfNeeded(trigger: .foreground)
    }

    func syncDeviceContextOnRefresh() async {
        guard connection != nil else { return }
        await flushPendingDeviceContextDeleteIfNeeded()
        guard anyDeviceContextSharingEnabled else { return }
        await refreshDeviceContextMetadata()
    }

    func refreshDeviceContextMetadata() async {
        guard let client else { return }
        do {
            deviceContextMetadata = try await client.getDeviceContextSnapshotMetadata()
        } catch {
            if forgetIfRevoked(error, for: client) { return }
        }
    }

    func flushPendingDeviceContextDeleteIfNeeded() async {
        guard pendingDeviceContextRemoteDelete else { return }
        await deleteRemoteDeviceContextWithQueue()
    }

    func handleDeviceContextToggleChanged(turnedOff: Bool, now: Date = Date()) async {
        if !anyDeviceContextSharingEnabled {
            if turnedOff {
                await deleteRemoteDeviceContextWithQueue()
            }
            return
        }
        await syncDeviceContextIfNeeded(trigger: .toggleChanged, now: now)
    }

    func deleteRemoteDeviceContextWithQueue() async {
        // Remote PUT and DELETE must keep user intent order across suspension points.
        let previous = deviceContextMutationTask
        let operation = Task { @MainActor in
            await previous?.value
            await performDeviceContextDelete()
        }
        deviceContextMutationTask = operation
        await operation.value
    }

    private func performDeviceContextDelete() async {
        lastDeviceContextPushAt = nil
        guard let client else {
            markPendingDeviceContextDelete()
            return
        }
        do {
            try await client.deleteDeviceContextSnapshot()
            guard self.client === client else { return }
            pendingDeviceContextRemoteDelete = false
            defaults.set(false, forKey: Self.pendingDeviceContextDeleteKey)
            deviceContextMetadata = IOSDeviceContextSnapshotMetadata(
                status: "not_shared",
                deviceId: connection?.deviceId,
                capturedAtEpochMs: nil,
                ttlSeconds: nil,
                expiresAtEpochMs: nil,
                domains: []
            )
        } catch {
            guard self.client === client else { return }
            if forgetIfRevoked(error, for: client) { return }
            markPendingDeviceContextDelete()
        }
    }

    private func markPendingDeviceContextDelete() {
        pendingDeviceContextRemoteDelete = true
        defaults.set(true, forKey: Self.pendingDeviceContextDeleteKey)
    }

    @discardableResult
    func syncDeviceContextIfNeeded(
        trigger: DeviceContextSyncTrigger,
        now: Date = Date(),
        calendarOverride: [IOSDeviceContextSnapshotPayload.CalendarItem]? = nil,
        remindersOverride: [IOSDeviceContextSnapshotPayload.ReminderItem]? = nil,
        artifactsOverride: [IOSWorkspaceArtifactRecord]? = nil
    ) async -> Bool {
        let previous = deviceContextMutationTask
        let operation = Task { @MainActor in
            await previous?.value
            return await performDeviceContextSync(trigger: trigger, now: now,
                calendarOverride: calendarOverride, remindersOverride: remindersOverride,
                artifactsOverride: artifactsOverride)
        }
        deviceContextMutationTask = Task { _ = await operation.value }
        return await operation.value
    }

    private func performDeviceContextSync(
        trigger: DeviceContextSyncTrigger,
        now: Date,
        calendarOverride: [IOSDeviceContextSnapshotPayload.CalendarItem]?,
        remindersOverride: [IOSDeviceContextSnapshotPayload.ReminderItem]?,
        artifactsOverride: [IOSWorkspaceArtifactRecord]?
    ) async -> Bool {
        guard anyDeviceContextSharingEnabled,
              UIApplication.shared.applicationState == .active else {
            return false
        }
        if trigger == .foreground,
           let lastPush = lastDeviceContextPushAt,
           now.timeIntervalSince(lastPush) < Self.deviceContextForegroundThrottleSeconds {
            return false
        }
        guard let client, let connection else { return false }

        isSyncingDeviceContext = true
        defer { isSyncingDeviceContext = false }

        let fetched = await Self.fetchAuthorizedEventKitItems(
            includeCalendar: shareCalendarUpcomingEnabled && calendarOverride == nil,
            includeReminders: shareRemindersDueEnabled && remindersOverride == nil,
            now: now
        )
        guard UIApplication.shared.applicationState == .active, self.client === client else { return false }
        let calendarItems = shareCalendarUpcomingEnabled ? (calendarOverride ?? fetched.calendar) : nil
        let reminderItems = shareRemindersDueEnabled ? (remindersOverride ?? fetched.reminders) : nil
        let artifactRecords = shareWorkspaceArtifactsEnabled
            ? (artifactsOverride ?? IOSWorkspaceStore.shared.artifacts)
            : nil

        let payload = Self.assembleDeviceContextSnapshot(
            deviceId: connection.deviceId,
            calendarItems: calendarItems,
            reminderItems: reminderItems,
            artifactRecords: artifactRecords,
            now: now
        )
        do {
            let meta = try await client.putDeviceContextSnapshot(payload)
            guard self.client === client else { return false }
            deviceContextMetadata = meta
            lastDeviceContextPushAt = now
            pendingDeviceContextRemoteDelete = false
            defaults.set(false, forKey: Self.pendingDeviceContextDeleteKey)
            if trigger == .manual {
                notice = Notice(text: localized("已刷新云端本机只读快照"), isError: false)
            }
            return true
        } catch {
            guard self.client === client else { return false }
            if !forgetIfRevoked(error, for: client), trigger == .manual {
                notice = Notice(text: error.localizedDescription, isError: true)
            }
            Self.deviceContextLogger.warning("Device context push failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated static func assembleDeviceContextSnapshot(
        deviceId: String?,
        calendarItems: [IOSDeviceContextSnapshotPayload.CalendarItem]?,
        reminderItems: [IOSDeviceContextSnapshotPayload.ReminderItem]?,
        artifactRecords: [IOSWorkspaceArtifactRecord]?,
        ttlSeconds: Int64 = 43_200,
        now: Date = Date()
    ) -> IOSDeviceContextSnapshotPayload {
        let truncatedCal = calendarItems.map { items in
            IOSDeviceContextSnapshotPayload.CalendarDomain(
                items: items.prefix(20).map { item in
                    IOSDeviceContextSnapshotPayload.CalendarItem(
                        title: truncatedRedacted(item.title, maxLength: 120),
                        startMs: item.startMs,
                        endMs: item.endMs,
                        allDay: item.allDay
                    )
                }
            )
        }
        let truncatedRem = reminderItems.map { items in
            IOSDeviceContextSnapshotPayload.RemindersDomain(
                items: items.prefix(20).map { item in
                    IOSDeviceContextSnapshotPayload.ReminderItem(
                        title: truncatedRedacted(item.title, maxLength: 120),
                        dueMs: item.dueMs,
                        priority: item.priority
                    )
                }
            )
        }
        let truncatedArt = artifactRecords.map { records in
            IOSDeviceContextSnapshotPayload.WorkspaceArtifactsDomain(
                items: records
                    .sorted { $0.updatedAtMillis > $1.updatedAtMillis }
                    .prefix(10)
                    .map { rec in
                        IOSDeviceContextSnapshotPayload.WorkspaceArtifactItem(
                            id: truncatedRedacted(rec.id, maxLength: 128),
                            title: truncatedRedacted(rec.title, maxLength: 120),
                            type: truncatedRedacted(rec.type.rawValue, maxLength: 40),
                            updatedAtMs: rec.updatedAtMillis,
                            summary: truncatedRedacted(rec.summary, maxLength: 60)
                        )
                    }
            )
        }
        return IOSDeviceContextSnapshotPayload(
            deviceId: deviceId,
            capturedAtEpochMs: Int64(now.timeIntervalSince1970 * 1_000),
            ttlSeconds: min(max(ttlSeconds, 900), 86_400),
            domains: IOSDeviceContextSnapshotPayload.Domains(
                calendarUpcoming: truncatedCal,
                remindersDue: truncatedRem,
                workspaceArtifacts: truncatedArt
            )
        )
    }

    nonisolated private static func truncatedRedacted(_ raw: String, maxLength: Int) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = IOSContextCompactionFidelity.redactCredentials(singleLine)
        return String(redacted.prefix(maxLength))
    }

    private static func fetchAuthorizedEventKitItems(
        includeCalendar: Bool,
        includeReminders: Bool,
        now: Date
    ) async -> (
        calendar: [IOSDeviceContextSnapshotPayload.CalendarItem]?,
        reminders: [IOSDeviceContextSnapshotPayload.ReminderItem]?
    ) {
        var calendarResult: [IOSDeviceContextSnapshotPayload.CalendarItem]? = nil
        var remindersResult: [IOSDeviceContextSnapshotPayload.ReminderItem]? = nil
        let store = EKEventStore()

        if includeCalendar, EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let end = now.addingTimeInterval(48 * 3600)
            let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
            let events = store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
                .prefix(20)
            calendarResult = events.map { ev in
                IOSDeviceContextSnapshotPayload.CalendarItem(
                    title: truncatedRedacted(ev.title ?? "", maxLength: 120),
                    startMs: Int64(ev.startDate.timeIntervalSince1970 * 1_000),
                    endMs: Int64(ev.endDate.timeIntervalSince1970 * 1_000),
                    allDay: ev.isAllDay
                )
            }
        }

        if includeReminders, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: now.addingTimeInterval(7 * 86_400), calendars: nil)
            remindersResult = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { result in
                    let mapped = (result ?? []).prefix(20).map { rem in
                        let dueMs = rem.dueDateComponents?.date.map { Int64($0.timeIntervalSince1970 * 1_000) }
                        return IOSDeviceContextSnapshotPayload.ReminderItem(
                            title: truncatedRedacted(rem.title ?? "", maxLength: 120),
                            dueMs: dueMs,
                            priority: rem.priority > 0 ? rem.priority : nil
                        )
                    }
                    continuation.resume(returning: mapped)
                }
            }
        }

        return (calendarResult, remindersResult)
    }
}
