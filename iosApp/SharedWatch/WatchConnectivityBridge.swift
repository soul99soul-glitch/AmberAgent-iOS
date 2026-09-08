import Foundation
import WatchConnectivity
#if os(iOS)
import UIKit
#endif

protocol WatchConnectivityTransporting: AnyObject {
    var isSupported: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isReachable: Bool { get }
    var isSessionActivated: Bool { get }
    var hasContentPending: Bool { get }
    var receivedApplicationContext: [String: Any] { get }
    func hasPendingNote(id: String) -> Bool
    func activate()
    func updateApplicationContext(_ context: [String: Any]) throws
    func transferUserInfo(_ userInfo: [String: Any]) -> String
    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    )
}

extension WatchConnectivityTransporting {
    var isSessionActivated: Bool { true }
    var hasContentPending: Bool { false }
    var receivedApplicationContext: [String: Any] { [:] }
    func hasPendingNote(id: String) -> Bool { false }
}

/// Holds the iPhone's short background execution window across the MainActor hop
/// used by a cold WCSession action. The expiration callback and normal completion
/// can race, so ending the task is deliberately idempotent.
final class WatchInboundBackgroundLifetime: @unchecked Sendable {
#if os(iOS)
    typealias BeginBackgroundTask = (String, @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    typealias EndBackgroundTask = (UIBackgroundTaskIdentifier) -> Void

    private let name: String
    private let beginBackgroundTask: BeginBackgroundTask
    private let endBackgroundTask: EndBackgroundTask
    private let lock = NSLock()
    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var didBegin = false
    private var didEnd = false

    init(
        name: String = "AmberWatchInbound",
        beginBackgroundTask: @escaping BeginBackgroundTask,
        endBackgroundTask: @escaping EndBackgroundTask
    ) {
        self.name = name
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
    }

    func begin() {
        let shouldBegin = lock.withLock {
            guard !didBegin else { return false }
            didBegin = true
            return true
        }
        guard shouldBegin else { return }

        // The expiration callback is allowed to race this call's return. If it
        // fires synchronously in a test or during teardown, `didEnd` below makes
        // sure the identifier is ended exactly once after it becomes known.
        let identifier = beginBackgroundTask(name) { [weak self] in
            self?.end()
        }
        let shouldEnd = lock.withLock {
            taskIdentifier = identifier
            return didEnd
        }
        if shouldEnd, identifier != .invalid {
            endBackgroundTask(identifier)
        }
    }

    func end() {
        let identifier: UIBackgroundTaskIdentifier? = lock.withLock {
            guard !didEnd else { return nil }
            didEnd = true
            guard taskIdentifier != .invalid else { return nil }
            return taskIdentifier
        }
        if let identifier {
            endBackgroundTask(identifier)
        }
    }
#else
    init() {}
    func begin() {}
    func end() {}
#endif
}

/// Small injectable factory so lifecycle tests can record UIKit begin/end calls
/// without making the WC transport or the Watch target depend on UIKit.
final class WatchInboundBackgroundLifetimeFactory: @unchecked Sendable {
#if os(iOS)
    private let beginBackgroundTask: WatchInboundBackgroundLifetime.BeginBackgroundTask
    private let endBackgroundTask: WatchInboundBackgroundLifetime.EndBackgroundTask

    init(
        beginBackgroundTask: @escaping WatchInboundBackgroundLifetime.BeginBackgroundTask,
        endBackgroundTask: @escaping WatchInboundBackgroundLifetime.EndBackgroundTask
    ) {
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
    }

    @MainActor convenience init() {
        // Resolve the actor-isolated singleton while constructing the bridge.
        // UIKit explicitly allows begin/endBackgroundTask from any thread.
        let application = UIApplication.shared
        self.init(
            beginBackgroundTask: { name, expiration in
                application.beginBackgroundTask(withName: name, expirationHandler: expiration)
            },
            endBackgroundTask: { identifier in application.endBackgroundTask(identifier) }
        )
    }

    func make(name: String) -> WatchInboundBackgroundLifetime {
        WatchInboundBackgroundLifetime(
            name: name,
            beginBackgroundTask: beginBackgroundTask,
            endBackgroundTask: endBackgroundTask
        )
    }
#else
    init() {}
    func make(name: String) -> WatchInboundBackgroundLifetime {
        WatchInboundBackgroundLifetime()
    }
#endif
}

#if os(iOS) || os(watchOS)
final class SystemWatchConnectivityTransport: NSObject, WatchConnectivityTransporting {
    private let session: WCSession

    init(session: WCSession = .default) {
        self.session = session
        super.init()
    }

    var isSupported: Bool { WCSession.isSupported() }
    var isPaired: Bool {
        #if os(iOS)
        session.isPaired
        #else
        true
        #endif
    }
    var isWatchAppInstalled: Bool {
        #if os(iOS)
        session.isWatchAppInstalled
        #else
        true
        #endif
    }
    var isReachable: Bool { session.isReachable }
    var isSessionActivated: Bool { session.activationState == .activated }
    var hasContentPending: Bool { session.hasContentPending }
    var receivedApplicationContext: [String: Any] { session.receivedApplicationContext }

    func hasPendingNote(id: String) -> Bool {
        session.outstandingUserInfoTransfers.contains { transfer in
            guard let data = transfer.userInfo[WatchConnectivityPayloadKey.action] as? Data,
                  let request = try? WatchTaskCodec.decodeAction(data) else { return false }
            return request.action == .saveNote && request.requestId == id
        }
    }

    func activate() {
        guard isSupported else { return }
        session.activate()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }

    func transferUserInfo(_ userInfo: [String: Any]) -> String {
        session.transferUserInfo(userInfo).description
    }

    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {
        session.sendMessage(message, replyHandler: replyHandler, errorHandler: errorHandler)
    }

    var underlyingSession: WCSession { session }
}
#endif

@MainActor
protocol WatchTaskActionHandling: AnyObject {
    func handleWatchAction(_ request: WatchTaskActionRequest) async -> WatchTaskActionResult
    func refreshWatchSnapshot() async
}

extension WatchTaskActionHandling {
    func refreshWatchSnapshot() async {}
}

/// Decoded on the WCSession queue so MainActor only receives Sendable values.
private enum WatchInboundEnvelope: Sendable {
    case snapshot(WatchTaskSnapshot)
    case action(WatchTaskActionRequest)
    case actionResult(WatchTaskActionResult)
    case requestSnapshot
    case incompatible
    case ignored
}

@MainActor
final class WatchConnectivityBridge: NSObject {
    static let shared = WatchConnectivityBridge()

    private(set) var latestSnapshot: WatchTaskSnapshot = .idle
    private var transport: WatchConnectivityTransporting?
    private weak var actionHandler: WatchTaskActionHandling?
    private var lastPushedSnapshot: WatchTaskSnapshot?
    private var isActivated = false
    private let actionTimeoutNanoseconds: UInt64
    private var actionTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var pendingNoteTransfers: Set<String> = []
    private nonisolated let inboundWrites = WatchInboundWrites()
    private nonisolated let inboundLifetimeFactory: WatchInboundBackgroundLifetimeFactory
    private let defaults: UserDefaults?
    private static let snapshotKey = "amber.watch.snapshot.v3"
    private static let sequenceKey = "amber.watch.sequence.v3"

    var onSnapshotUpdated: ((WatchTaskSnapshot) -> Void)?
    var onActionResult: ((WatchTaskActionResult) -> Void)?
    var onReachabilityChanged: ((Bool) -> Void)?
    var onConnectionError: ((String) -> Void)?
    private(set) var connectionError: String?
    var isCompanionReachable: Bool {
        transport?.isReachable == true && transport?.isSessionActivated == true
    }

    var backgroundDeliveryIsDrained: Bool {
        transport?.isSessionActivated == true && transport?.hasContentPending == false && inboundWrites.isEmpty
    }

    override init() {
        actionTimeoutNanoseconds = 12_000_000_000
        inboundLifetimeFactory = WatchInboundBackgroundLifetimeFactory()
        defaults = .standard
        super.init()
        #if os(watchOS)
        restoreSnapshot()
        #endif
    }

    init(
        actionTimeoutNanoseconds: UInt64,
        defaults: UserDefaults? = nil,
        inboundLifetimeFactory: WatchInboundBackgroundLifetimeFactory = WatchInboundBackgroundLifetimeFactory()
    ) {
        self.actionTimeoutNanoseconds = actionTimeoutNanoseconds
        self.inboundLifetimeFactory = inboundLifetimeFactory
        self.defaults = defaults
        super.init()
        restoreSnapshot()
    }

    private func restoreSnapshot() {
        guard let data = defaults?.data(forKey: Self.snapshotKey),
              let snapshot = try? WatchTaskCodec.decodeSnapshot(data) else { return }
        latestSnapshot = snapshot
    }

    /// Removes only the receiving device's cached projection; never sends a command to iPhone.
    func clearLocalSnapshotCache() {
        defaults?.removeObject(forKey: Self.snapshotKey)
        latestSnapshot = .idle
        onSnapshotUpdated?(.idle)
    }

    func configure(
        transport: WatchConnectivityTransporting? = nil,
        actionHandler: WatchTaskActionHandling? = nil
    ) {
        #if os(iOS) || os(watchOS)
        if let transport {
            self.transport = transport
        } else if self.transport == nil {
            let system = SystemWatchConnectivityTransport()
            self.transport = system
            system.underlyingSession.delegate = self
        }
        #endif
        if let actionHandler {
            self.actionHandler = actionHandler
        }
        activateIfNeeded()
    }

    /// Installs WCSession's delegate during app launch so watchOS messages can
    /// wake the process before SwiftUI has constructed AppShell.
    func startReceiving(actionHandler: WatchTaskActionHandling? = nil) {
        configure(actionHandler: actionHandler)
    }

    func activateIfNeeded() {
        guard let transport, transport.isSupported, !isActivated else { return }
        transport.activate()
        isActivated = true
    }

    func publish(_ snapshot: WatchTaskSnapshot) {
        var snapshot = snapshot
        if snapshot != latestSnapshot || snapshot.sequence == nil {
            let savedSequence = (defaults?.object(forKey: Self.sequenceKey) as? NSNumber)?.int64Value ?? 0
            snapshot.sequence = max(
                max(savedSequence, latestSnapshot.sequence ?? 0) + 1,
                Int64(Date().timeIntervalSince1970 * 1_000_000)
            )
            defaults?.set(snapshot.sequence, forKey: Self.sequenceKey)
        }
        latestSnapshot = snapshot
        guard let transport, transport.isSupported else { return }
        activateIfNeeded()
        guard transport.isSessionActivated, transport.isPaired, transport.isWatchAppInstalled else { return }
        guard lastPushedSnapshot != snapshot else { return }

        do {
            let message = try WatchTaskCodec.snapshotMessage(for: snapshot)
            try transport.updateApplicationContext(message)
            lastPushedSnapshot = snapshot
            connectionError = nil
            if transport.isReachable {
                transport.sendMessage(message, replyHandler: nil, errorHandler: nil)
            }
        } catch {
            reportConnectionError("同步到手表失败，将在连接恢复后重试")
        }
    }

    func clear(languageCode: String? = nil) {
        var idle = WatchTaskSnapshot.idle
        idle.languageCode = languageCode
        idle.library = latestSnapshot.library
        idle.updatedAt = Date()
        publish(idle)
    }

    @discardableResult
    func requestSnapshotFromPhone() -> Bool {
        guard let transport, transport.isSupported else { return false }
        activateIfNeeded()
        // Only request when reachable; otherwise keep local/applicationContext snapshot.
        guard isCompanionReachable else { return false }
        let message = WatchTaskCodec.requestSnapshotMessage()
        transport.sendMessage(message, replyHandler: { [weak self] reply in
            let envelope = Self.decodeEnvelope(reply)
            Task { @MainActor in
                self?.apply(envelope)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.reportConnectionError("无法连接 iPhone，请稍后重试")
            }
        })
        return true
    }

    func sendAction(_ request: WatchTaskActionRequest) {
        guard let transport, transport.isSupported else {
            reportActionFailure(request, message: "无法连接 iPhone，请稍后重试")
            return
        }
        activateIfNeeded()
        guard isCompanionReachable else {
            // Interactive commands must not arrive minutes later after Watch has
            // already reported failure; snapshots still use queued delivery.
            reportActionFailure(request, message: "无法连接 iPhone，请稍后重试")
            return
        }
        scheduleActionTimeout(for: request)
        do {
            let message = try WatchTaskCodec.actionMessage(for: request)
            transport.sendMessage(message, replyHandler: { [weak self] reply in
                let envelope = Self.decodeEnvelope(reply)
                Task { @MainActor in
                    self?.apply(envelope)
                }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.reportActionFailure(request, message: "发送到 iPhone 失败，请稍后重试", deliveryUnknown: true)
                }
            })
        } catch {
            reportActionFailure(request, message: "发送到 iPhone 失败，请稍后重试")
        }
    }

    /// Only passive notes may be queued. The caller retains the original until the phone's durable ACK.
    func sendNote(_ request: WatchTaskActionRequest) {
        guard request.action == .saveNote else {
            reportActionFailure(request, message: "这项操作需要连接 iPhone")
            return
        }
        guard let transport, transport.isSupported else {
            reportActionFailure(request, message: "无法连接 iPhone，请稍后重试")
            return
        }
        activateIfNeeded()
        guard transport.isSessionActivated else {
            reportActionFailure(request, message: "设备连接尚未就绪，请稍后重试")
            return
        }
        if isCompanionReachable {
            sendAction(request)
        } else if !pendingNoteTransfers.contains(request.requestId), !transport.hasPendingNote(id: request.requestId) {
            do {
                let message = try WatchTaskCodec.actionMessage(for: request)
                _ = transport.transferUserInfo(message)
                pendingNoteTransfers.insert(request.requestId)
            } catch {
                reportActionFailure(request, message: "笔记尚未同步，请稍后重试")
            }
        }
    }

    private func scheduleActionTimeout(for request: WatchTaskActionRequest) {
        actionTimeoutTasks[request.requestId]?.cancel()
        actionTimeoutTasks[request.requestId] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.actionTimeoutNanoseconds ?? 0)
            } catch {
                return
            }
            guard let self else { return }
            self.reportActionFailure(request, message: "iPhone 响应超时，请重试", deliveryUnknown: true)
        }
    }

    private func reportActionFailure(_ request: WatchTaskActionRequest, message: String, deliveryUnknown: Bool = false) {
        actionTimeoutTasks.removeValue(forKey: request.requestId)?.cancel()
        onActionResult?(WatchTaskActionResult(
            requestId: request.requestId,
            runId: request.runId,
            accepted: false,
            message: WatchTaskLocalization.string(
                message,
                defaultValue: message,
                languageCode: latestSnapshot.languageCode
            ),
            snapshot: latestSnapshot,
            deliveryUnknown: deliveryUnknown
        ))
    }

    private func reportConnectionError(_ message: String) {
        connectionError = message
        onConnectionError?(message)
    }

    private nonisolated func makeInboundLifetime(for envelope: WatchInboundEnvelope) -> WatchInboundBackgroundLifetime? {
#if os(iOS)
        let name: String
        switch envelope {
        case .action(let request): name = "AmberWatchInbound-\(request.requestId)"
        case .requestSnapshot: name = "AmberWatchSnapshot"
        default: return nil
        }
        let lifetime = inboundLifetimeFactory.make(name: name)
        lifetime.begin()
        return lifetime
#else
        return nil
#endif
    }

    fileprivate func apply(
        _ envelope: WatchInboundEnvelope,
        inboundLifetime: WatchInboundBackgroundLifetime? = nil
    ) {
        switch envelope {
        case .snapshot(let snapshot):
            applySnapshotIfNewer(snapshot)
        case .action(let request):
            #if os(iOS)
            let lifetime = inboundLifetime
                ?? inboundLifetimeFactory.make(name: "AmberWatchInbound-\(request.requestId)")
            lifetime.begin()
            Task { @MainActor [weak self, lifetime] in
                defer { lifetime.end() }
                guard let self else { return }
                let result = await self.actionHandler?.handleWatchAction(request)
                    ?? WatchTaskActionResult(
                        requestId: request.requestId,
                        runId: request.runId,
                        accepted: false,
                        message: WatchTaskLocalization.string(
                            "iPhone 当前无法处理手表操作",
                            defaultValue: "iPhone 当前无法处理手表操作",
                            languageCode: self.latestSnapshot.languageCode
                        ),
                        snapshot: self.latestSnapshot
                    )
                self.reply(with: result, reliably: request.action == .saveNote)
            }
            #endif
        case .actionResult(let result):
            actionTimeoutTasks.removeValue(forKey: result.requestId)?.cancel()
            pendingNoteTransfers.remove(result.requestId)
            if let snapshot = result.snapshot {
                applySnapshotIfNewer(snapshot)
            }
            onActionResult?(result)
        case .requestSnapshot:
            #if os(iOS)
            let lifetime = inboundLifetime ?? inboundLifetimeFactory.make(name: "AmberWatchSnapshot")
            lifetime.begin()
            Task { @MainActor [weak self, lifetime] in
                defer { lifetime.end() }
                // The owner publishes only after a successful refresh. Do not
                // manufacture an idle revision when cold attachment times out.
                await self?.actionHandler?.refreshWatchSnapshot()
            }
            #endif
        case .incompatible:
            reportConnectionError("请将 iPhone 和 Apple Watch 上的 Amber 更新到相同版本")
        case .ignored:
            break
        }
    }

    private func applySnapshotIfNewer(_ snapshot: WatchTaskSnapshot) {
        guard WatchSnapshotOrdering.accepts(snapshot, after: latestSnapshot) else { return }
        latestSnapshot = snapshot
        connectionError = nil
        if let data = try? WatchTaskCodec.encodeSnapshot(snapshot) {
            defaults?.set(data, forKey: Self.snapshotKey)
        }
        onSnapshotUpdated?(snapshot)
    }

    #if os(iOS)
    private func reply(with result: WatchTaskActionResult, reliably: Bool) {
        guard let transport, transport.isSupported, transport.isSessionActivated else { return }
        do {
            let message = try WatchTaskCodec.resultMessage(for: resultForDelivery(result))
            if reliably {
                // An offline note requires a durable application ACK even if reachability changes mid-send.
                _ = transport.transferUserInfo(message)
            } else if transport.isReachable {
                transport.sendMessage(message, replyHandler: nil, errorHandler: nil)
            } else {
                _ = transport.transferUserInfo(message)
            }
        } catch {
            // Ignore reply transport failures.
        }
    }

    private func resultForDelivery(_ result: WatchTaskActionResult) -> WatchTaskActionResult {
        var result = result
        // Handlers publish through the phone owner. Replaying an old command must never republish its old snapshot.
        result.snapshot = latestSnapshot
        return result
    }
    #endif

    nonisolated fileprivate static func decodeEnvelope(_ message: [String: Any]) -> WatchInboundEnvelope {
        guard message[WatchConnectivityPayloadKey.protocolVersion] as? Int == WatchConnectivityPayloadKey.currentProtocolVersion else {
            return message.isEmpty ? .ignored : .incompatible
        }
        guard let type = message[WatchConnectivityPayloadKey.type] as? String else {
            return .ignored
        }
        switch type {
        case WatchConnectivityPayloadKey.typeSnapshot:
            guard let data = message[WatchConnectivityPayloadKey.snapshot] as? Data,
                  let snapshot = try? WatchTaskCodec.decodeSnapshot(data) else {
                return .ignored
            }
            return .snapshot(snapshot)
        case WatchConnectivityPayloadKey.typeAction:
            guard let data = message[WatchConnectivityPayloadKey.action] as? Data,
                  let request = try? WatchTaskCodec.decodeAction(data) else {
                return .ignored
            }
            return .action(request)
        case WatchConnectivityPayloadKey.typeActionResult:
            guard let data = message[WatchConnectivityPayloadKey.result] as? Data,
                  let result = try? WatchTaskCodec.decodeResult(data) else {
                return .ignored
            }
            return .actionResult(result)
        case WatchConnectivityPayloadKey.typeRequestSnapshot:
            return .requestSnapshot
        default:
            return .ignored
        }
    }
}

#if os(iOS) || os(watchOS)
extension WatchConnectivityBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let activated = activationState == .activated
        let restored = Self.decodeEnvelope(session.receivedApplicationContext)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isActivated = activated
            guard activated else {
                self.reportConnectionError("设备连接尚未就绪，请稍后重试")
                return
            }
            self.connectionError = nil
            #if os(watchOS)
            self.apply(restored)
            self.requestSnapshotFromPhone()
            #else
            self.lastPushedSnapshot = nil
            self.publish(self.latestSnapshot)
            #endif
            self.onReachabilityChanged?(self.isCompanionReachable)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.isActivated = false }
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onReachabilityChanged?(reachable)
            guard reachable else { return }
            #if os(watchOS)
            self.requestSnapshotFromPhone()
            #else
            self.lastPushedSnapshot = nil
            await self.actionHandler?.refreshWatchSnapshot()
            self.publish(self.latestSnapshot)
            #endif
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        let envelope = Self.decodeEnvelope(message)
        let lifetime = makeInboundLifetime(for: envelope)
        Task { @MainActor [weak self, lifetime] in
            guard let self else {
                lifetime?.end()
                return
            }
            self.apply(envelope, inboundLifetime: lifetime)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let envelope = Self.decodeEnvelope(message)
        let lifetime = makeInboundLifetime(for: envelope)
        let reply = UnsafeReplyHandler(replyHandler)
        Task { @MainActor [weak self, lifetime] in
            guard let self else {
                reply.respond([:])
                lifetime?.end()
                return
            }
            defer { lifetime?.end() }
            #if os(iOS)
            switch envelope {
            case .action(let request):
                let result = await self.actionHandler?.handleWatchAction(request)
                    ?? WatchTaskActionResult(
                        requestId: request.requestId, runId: request.runId,
                        accepted: false, message: "iPhone 当前无法处理手表操作", snapshot: self.latestSnapshot
                    )
                reply.respond((try? WatchTaskCodec.resultMessage(for: self.resultForDelivery(result))) ?? [:])
                return
            case .requestSnapshot:
                await self.actionHandler?.refreshWatchSnapshot()
                reply.respond((try? WatchTaskCodec.snapshotMessage(for: self.latestSnapshot)) ?? [:])
                return
            case .incompatible:
                // Send our version back; newer peers can show an upgrade error instead of silently ignoring an empty reply.
                reply.respond(WatchTaskCodec.requestSnapshotMessage())
                return
            default:
                break
            }
            #endif
            self.apply(envelope)
            reply.respond([:])
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let envelope = Self.decodeEnvelope(applicationContext)
        let lifetime = makeInboundLifetime(for: envelope)
        inboundWrites.begin()
        Task { @MainActor [weak self, lifetime] in
            defer { self?.inboundWrites.end() }
            guard let self else {
                lifetime?.end()
                return
            }
            self.apply(envelope, inboundLifetime: lifetime)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        let envelope = Self.decodeEnvelope(userInfo)
        let lifetime = makeInboundLifetime(for: envelope)
        inboundWrites.begin()
        Task { @MainActor [weak self, lifetime] in
            defer { self?.inboundWrites.end() }
            guard let self else {
                lifetime?.end()
                return
            }
            self.apply(envelope, inboundLifetime: lifetime)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        guard case .action(let request) = Self.decodeEnvelope(userInfoTransfer.userInfo),
              request.action == .saveNote else { return }
        let failed = error != nil
        Task { @MainActor [weak self] in
            self?.pendingNoteTransfers.remove(request.requestId)
            if failed {
                self?.reportActionFailure(request, message: "笔记尚未同步，请稍后重试", deliveryUnknown: true)
            }
        }
    }
}

/// WCSession callbacks return before their MainActor persistence work finishes.
private final class WatchInboundWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isEmpty: Bool { lock.withLock { count == 0 } }
    func begin() { lock.withLock { count += 1 } }
    func end() { lock.withLock { count -= 1 } }
}

/// Tiny wrapper so escaping WCSession reply handlers can be invoked after a MainActor hop.
private final class UnsafeReplyHandler: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func respond(_ payload: [String: Any]) {
        handler(payload)
    }
}
#endif
