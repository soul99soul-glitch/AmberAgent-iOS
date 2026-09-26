import Foundation
import Observation
import Shared

struct IOSMcpDiscoveredTool: Equatable, Identifiable {
    let serverName: String
    let tool: IOSMcpTool

    var id: String { "\(serverName)::\(tool.name)" }
}

enum IOSMcpManagerError: LocalizedError, Equatable {
    case ambiguousServerName(String)

    var errorDescription: String? {
        switch self {
        case .ambiguousServerName(let name):
            "MCP server name is ambiguous across configured sources: \(name)"
        }
    }
}

@MainActor
@Observable
final class IOSMcpManager {
    private struct SessionRecovery {
        let id: UUID
        let generation: UInt64
        let server: IOSMcpServerConfig
        let client: IOSMcpClienting
        let task: Task<Void, Error>
    }

    private let serverProvider: () -> [IOSMcpServerConfig]
    private let clientFactory: (IOSMcpServerConfig) -> IOSMcpClienting
    private let isEnabled: () -> Bool
    private let discoveredToolSink: (String, [IOSMcpTool]) -> [IOSMcpTool]?
    private var clientsByServer: [String: IOSMcpClienting] = [:]
    private var ambiguousServerNames: Set<String> = []
    private var sessionRecoveriesByServer: [String: SessionRecovery] = [:]
    private var sessionRecoveryGenerationByServer: [String: UInt64] = [:]
    private var syncChainTail: Task<Void, Never>?

    private(set) var servers: [IOSMcpServerConfig] = []
    private(set) var tools: [IOSMcpDiscoveredTool] = []
    private(set) var statusByServer: [String: IOSMcpConnectionStatus] = [:]

    init(
        serverProvider: @escaping () -> [IOSMcpServerConfig],
        isEnabled: @escaping () -> Bool = { true },
        discoveredToolSink: @escaping (String, [IOSMcpTool]) -> [IOSMcpTool]? = { _, _ in nil },
        clientFactory: @escaping (IOSMcpServerConfig) -> IOSMcpClienting = { _ in IOSMcpClient() }
    ) {
        self.serverProvider = serverProvider
        self.isEnabled = isEnabled
        self.discoveredToolSink = discoveredToolSink
        self.clientFactory = clientFactory
    }

    convenience init(
        sharedSettings: IOSSharedSettingsStore,
        configStore: IOSMcpConfigStore,
        isNetworkAllowed: @escaping () -> Bool = { true }
    ) {
        self.init(serverProvider: {
            sharedSettings.snapshot.mcpServers.compactMap(IOSMcpServerConfig.init) + configStore.servers
        }, isEnabled: {
            sharedSettings.isCapabilityGateEnabled(.mcp) && isNetworkAllowed()
        }, discoveredToolSink: { serverName, tools in
            configStore.mergeDiscoveredTools(named: serverName, tools: tools)
        })
    }

    func refreshServers() {
        invalidateAllSessionRecoveries(disconnectClients: true)
        let configuredServers = serverProvider()
        let serversByName = Dictionary(grouping: configuredServers, by: \.name)
        ambiguousServerNames = Set(serversByName.compactMap { name, candidates in
            guard let first = candidates.first else { return nil }
            return candidates.dropFirst().allSatisfy { $0 == first } ? nil : name
        })
        var seenServerNames = Set<String>()
        servers = configuredServers.filter {
            !ambiguousServerNames.contains($0.name) && seenServerNames.insert($0.name).inserted
        }
        for name in ambiguousServerNames {
            statusByServer[name] = .error(IOSMcpManagerError.ambiguousServerName(name).localizedDescription)
        }
        for server in servers where statusByServer[server.name] == nil {
            statusByServer[server.name] = .idle
        }
    }

    /// Chat runs start this without awaiting it. Syncs run in order on one
    /// chain, so an older config can never publish after a newer one, and
    /// tool calls wait for the chain so they never race session invalidation.
    func syncAll(enabledOverride: Bool? = nil) async {
        await enqueueSync {
            await self.performSyncAll(enabledOverride: enabledOverride)
        }
    }

    /// Publishes the persisted catalog once, without network, so a run that
    /// starts before the first sync still sees the configured MCP tools.
    func loadPersistedCatalogIfNeeded() {
        guard servers.isEmpty, syncChainTail == nil else { return }
        refreshServers()
        tools = servers.filter(\.enabled).flatMap { server in
            server.tools.map { IOSMcpDiscoveredTool(serverName: server.name, tool: $0) }
        }
    }

    private func enqueueSync(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = syncChainTail
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        syncChainTail = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if syncChainTail == task {
            syncChainTail = nil
        }
    }

    /// Waits for the sync chain without cancelling it: a cancelled tool call
    /// leaves at once while the sync keeps serving other callers.
    private static func waitForSync(_ task: Task<Void, Never>) async throws {
        let gate = IOSMcpSyncWaitGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                Task {
                    await task.value
                    gate.finish(.success(()))
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private func performSyncAll(enabledOverride: Bool?) async {
        guard enabledOverride ?? isEnabled() else {
            disconnectAll()
            servers = []
            tools = []
            statusByServer = [:]
            return
        }
        refreshServers()
        let currentServerNames = Set(servers.map(\.name))
        for staleServerName in Array(clientsByServer.keys) where !currentServerNames.contains(staleServerName) {
            clientsByServer[staleServerName]?.disconnect()
            clientsByServer.removeValue(forKey: staleServerName)
            if ambiguousServerNames.contains(staleServerName) {
                statusByServer[staleServerName] = .error(
                    IOSMcpManagerError.ambiguousServerName(staleServerName).localizedDescription
                )
            } else {
                statusByServer.removeValue(forKey: staleServerName)
            }
        }

        // Servers are independent, so one slow server must not serialize the
        // rest. The directory is published once, keeping the previous catalog
        // visible to readers instead of an empty or partial one mid-sync.
        let serverNames = servers.map(\.name)
        let syncTasks = serverNames.map { name in
            Task { @MainActor () -> [IOSMcpDiscoveredTool] in
                guard let server = self.servers.first(where: { $0.name == name }) else { return [] }
                return await self.sync(server: server)
            }
        }
        var refreshedTools: [IOSMcpDiscoveredTool] = []
        await withTaskCancellationHandler {
            for task in syncTasks {
                refreshedTools.append(contentsOf: await task.value)
            }
        } onCancel: {
            syncTasks.forEach { $0.cancel() }
        }
        tools = refreshedTools
    }

    /// Refreshes exactly one configured server. Management-tool tests must not
    /// contact every enabled MCP server as a side effect.
    func sync(serverName: String, enabledOverride: Bool? = nil) async {
        await enqueueSync {
            await self.performSync(serverName: serverName, enabledOverride: enabledOverride)
        }
    }

    private func performSync(serverName: String, enabledOverride: Bool?) async {
        guard enabledOverride ?? isEnabled() else {
            disconnectAll()
            servers = []
            tools = []
            statusByServer = [:]
            return
        }
        refreshServers()
        guard let server = servers.first(where: { $0.name == serverName }) else { return }
        let discovered = await sync(server: server)
        tools.removeAll { $0.serverName == serverName }
        tools.append(contentsOf: discovered)
    }

    func callTool(
        serverName: String,
        toolName: String,
        arguments: [String: Any],
        enabledOverride: Bool? = nil
    ) async throws -> String {
        guard enabledOverride ?? isEnabled() else {
            throw IOSMcpClientError.invalidResponse
        }
        if let syncChainTail {
            try await Self.waitForSync(syncChainTail)
        }
        if servers.isEmpty || clientsByServer[serverName] == nil {
            await syncAll(enabledOverride: enabledOverride)
        }
        if let recovery = sessionRecoveriesByServer[serverName] {
            try await recovery.task.value
        }
        guard !ambiguousServerNames.contains(serverName) else {
            throw IOSMcpManagerError.ambiguousServerName(serverName)
        }
        guard let server = servers.first(where: { $0.name == serverName }) else {
            throw IOSMcpClientError.serverNotFound(serverName)
        }
        guard server.enabled else {
            throw IOSMcpClientError.serverDisabled(serverName)
        }
        guard let knownTool = server.tools.first(where: { $0.name == toolName }) else {
            throw IOSMcpClientError.toolNotFound(server: serverName, tool: toolName)
        }
        guard knownTool.enabled else {
            throw IOSMcpClientError.toolDisabled(server: serverName, tool: toolName)
        }
        guard let client = clientsByServer[serverName] else {
            throw IOSMcpClientError.notConnected(serverName)
        }
        do {
            return try await client.callTool(name: toolName, arguments: arguments)
        } catch let error as IOSMcpClientError where error == .mcpSessionExpired {
            try await recoverExpiredSession(server: server, client: client)
            guard let refreshedServer = servers.first(where: { $0.name == serverName }) else {
                throw IOSMcpClientError.serverNotFound(serverName)
            }
            guard let refreshedTool = refreshedServer.tools.first(where: { $0.name == toolName }) else {
                throw IOSMcpClientError.toolNotFound(server: serverName, tool: toolName)
            }
            guard refreshedTool.enabled else {
                throw IOSMcpClientError.toolDisabled(server: serverName, tool: toolName)
            }
            guard refreshedTool.readOnlyHint == true else {
                throw error
            }
            do {
                return try await client.callTool(name: toolName, arguments: arguments)
            } catch let retryError as IOSMcpClientError where retryError == .mcpSessionExpired {
                client.disconnect()
                statusByServer[serverName] = .error(retryError.localizedDescription)
                throw retryError
            }
        }
    }

    func refreshFromCurrentSettings() {
        refreshServers()
        tools = servers.flatMap { server in
            server.tools.map { IOSMcpDiscoveredTool(serverName: server.name, tool: $0) }
        }
    }

    func disconnectAll() {
        invalidateAllSessionRecoveries(disconnectClients: false)
        clientsByServer.values.forEach { $0.disconnect() }
        clientsByServer.removeAll()
        for server in servers {
            statusByServer[server.name] = .idle
        }
        reconnectAttempts.removeAll()
    }

    // MARK: - Auto-reconnect (Android McpManager parity)
    //
    // Android McpManager auto-reconnects with exponential backoff (up to
    // MAX_RECONNECT_ATTEMPTS=5). iOS had no reconnect — a dropped connection
    // stayed in `.error` until the user manually re-synced. This retries failed
    // servers when they're next needed (callTool) and via syncAll.

    private static let maxReconnectAttempts = 5
    private static let baseReconnectDelaySeconds: UInt64 = 2
    private var reconnectAttempts: [String: Int] = [:]
    private var lastReconnectAttemptByServer: [String: Date] = [:]

    /// Attempts to reconnect servers currently in `.error`. Returns the names
    /// that were retried. Uses exponential backoff (2^n seconds) capped at
    /// maxReconnectAttempts per server; a successful connection resets the
    /// counter. Safe to call repeatedly — it respects the backoff window.
    @discardableResult
    func reconnectFailedServers() async -> [String] {
        guard isEnabled() else { return [] }
        let failed = statusByServer.filter { _, status in
            if case .error = status { return true }
            return false
        }.map(\.key)
        guard !failed.isEmpty else { return [] }

        let now = Date()
        var retried: [String] = []
        for serverName in failed {
            invalidateSessionRecovery(serverName: serverName, disconnectClient: true)
            let attempts = reconnectAttempts[serverName] ?? 0
            guard attempts < Self.maxReconnectAttempts else { continue }
            // Backoff: 2^n seconds since the last attempt. Skip if still within
            // the backoff window.
            let delay = Self.baseReconnectDelaySeconds * (1 << attempts)
            if let last = lastReconnectAttemptByServer[serverName],
               now.timeIntervalSince(last) < Double(delay) {
                continue
            }
            lastReconnectAttemptByServer[serverName] = now
            reconnectAttempts[serverName] = attempts + 1
            statusByServer[serverName] = .reconnecting

            guard let server = servers.first(where: { $0.name == serverName }), server.enabled else {
                statusByServer[serverName] = .error("server missing or disabled")
                continue
            }
            let client: IOSMcpClienting = clientsByServer[serverName] ?? clientFactory(server)
            clientsByServer[serverName] = client
            do {
                _ = try await client.connect(config: server)
                let listedTools = try await client.listTools()
                let merged = Self.applyingAuthoritativeSafetyAnnotations(
                    from: listedTools,
                    to: discoveredToolSink(server.name, listedTools) ?? Self.mergeDiscoveredTools(
                        discovered: listedTools,
                        existing: server.tools
                    )
                )
                if let index = servers.firstIndex(where: { $0.name == server.name }) {
                    servers[index] = server.withTools(merged)
                }
                tools.removeAll { $0.serverName == server.name }
                tools.append(contentsOf: merged.map { IOSMcpDiscoveredTool(serverName: server.name, tool: $0) })
                statusByServer[server.name] = .connected
                reconnectAttempts[server.name] = nil
                lastReconnectAttemptByServer[server.name] = nil
                retried.append(serverName)
            } catch {
                statusByServer[server.name] = .error(IOSWebMountRedactor.redactedText(error.localizedDescription))
            }
        }
        return retried
    }

    private static func mergeDiscoveredTools(discovered: [IOSMcpTool], existing: [IOSMcpTool]) -> [IOSMcpTool] {
        let existingByName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })
        return discovered.map { tool in
            guard let old = existingByName[tool.name] else { return tool }
            return IOSMcpTool(
                name: tool.name,
                description: tool.description ?? old.description,
                enabled: old.enabled,
                inputSchema: tool.inputSchema ?? old.inputSchema,
                readOnlyHint: tool.readOnlyHint
            )
        }
    }

    private static func applyingAuthoritativeSafetyAnnotations(
        from discovered: [IOSMcpTool],
        to merged: [IOSMcpTool]
    ) -> [IOSMcpTool] {
        let discoveredByName = Dictionary(uniqueKeysWithValues: discovered.map { ($0.name, $0) })
        return merged.map { tool in
            IOSMcpTool(
                name: tool.name,
                description: tool.description,
                enabled: tool.enabled,
                inputSchema: tool.inputSchema,
                readOnlyHint: discoveredByName[tool.name]?.readOnlyHint
            )
        }
    }

    private func recoverExpiredSession(
        server: IOSMcpServerConfig,
        client: IOSMcpClienting
    ) async throws {
        if let recovery = sessionRecoveriesByServer[server.name] {
            return try await recovery.task.value
        }

        let recoveryID = UUID()
        let generation = advanceSessionRecoveryGeneration(serverName: server.name)
        let task = Task { @MainActor [weak self] in
            guard let self else { throw IOSMcpClientError.invalidResponse }
            try self.validateSessionRecoveryOwnership(
                id: recoveryID,
                generation: generation,
                server: server,
                client: client
            )
            client.disconnect()
            self.statusByServer[server.name] = .reconnecting
            do {
                try self.validateSessionRecoveryOwnership(
                    id: recoveryID,
                    generation: generation,
                    server: server,
                    client: client
                )
                _ = try await client.connect(config: server)
                try self.validateSessionRecoveryOwnership(
                    id: recoveryID,
                    generation: generation,
                    server: server,
                    client: client
                )
                let listedTools = try await client.listTools()
                try self.validateSessionRecoveryOwnership(
                    id: recoveryID,
                    generation: generation,
                    server: server,
                    client: client
                )
                try self.validateSessionRecoveryOwnership(
                    id: recoveryID,
                    generation: generation,
                    server: server,
                    client: client
                )
                let mergedTools = Self.applyingAuthoritativeSafetyAnnotations(
                    from: listedTools,
                    to: self.discoveredToolSink(server.name, listedTools) ?? Self.mergeDiscoveredTools(
                        discovered: listedTools,
                        existing: server.tools
                    )
                )
                try self.validateSessionRecoveryOwnership(
                    id: recoveryID,
                    generation: generation,
                    server: server,
                    client: client
                )
                if let index = self.servers.firstIndex(where: { $0.name == server.name }) {
                    self.servers[index] = server.withTools(mergedTools)
                }
                self.tools.removeAll { $0.serverName == server.name }
                self.tools.append(contentsOf: mergedTools.map {
                    IOSMcpDiscoveredTool(serverName: server.name, tool: $0)
                })
                self.statusByServer[server.name] = .connected
            } catch {
                if self.isCurrentSessionRecovery(
                    id: recoveryID,
                    generation: generation,
                    server: server,
                    client: client
                ) {
                    self.statusByServer[server.name] = .error(
                        IOSWebMountRedactor.redactedText(error.localizedDescription)
                    )
                }
                throw error
            }
        }
        sessionRecoveriesByServer[server.name] = SessionRecovery(
            id: recoveryID,
            generation: generation,
            server: server,
            client: client,
            task: task
        )
        do {
            try await task.value
            if isRegisteredSessionRecovery(
                id: recoveryID,
                generation: generation,
                serverName: server.name
            ) {
                sessionRecoveriesByServer.removeValue(forKey: server.name)
            }
        } catch {
            if isRegisteredSessionRecovery(
                id: recoveryID,
                generation: generation,
                serverName: server.name
            ) {
                sessionRecoveriesByServer.removeValue(forKey: server.name)
            }
            throw error
        }
    }

    private func advanceSessionRecoveryGeneration(serverName: String) -> UInt64 {
        let generation = (sessionRecoveryGenerationByServer[serverName] ?? 0) &+ 1
        sessionRecoveryGenerationByServer[serverName] = generation
        return generation
    }

    private func invalidateAllSessionRecoveries(disconnectClients: Bool) {
        for serverName in Array(sessionRecoveriesByServer.keys) {
            invalidateSessionRecovery(serverName: serverName, disconnectClient: disconnectClients)
        }
    }

    private func invalidateSessionRecovery(serverName: String, disconnectClient: Bool) {
        _ = advanceSessionRecoveryGeneration(serverName: serverName)
        guard let recovery = sessionRecoveriesByServer.removeValue(forKey: serverName) else { return }
        recovery.task.cancel()
        guard disconnectClient,
              let currentClient = clientsByServer[serverName],
              currentClient === recovery.client else { return }
        currentClient.disconnect()
        clientsByServer.removeValue(forKey: serverName)
    }

    private func validateSessionRecoveryOwnership(
        id: UUID,
        generation: UInt64,
        server: IOSMcpServerConfig,
        client: IOSMcpClienting
    ) throws {
        try Task.checkCancellation()
        guard isCurrentSessionRecovery(
            id: id,
            generation: generation,
            server: server,
            client: client
        ) else {
            throw CancellationError()
        }
    }

    private func isCurrentSessionRecovery(
        id: UUID,
        generation: UInt64,
        server: IOSMcpServerConfig,
        client: IOSMcpClienting
    ) -> Bool {
        guard sessionRecoveryGenerationByServer[server.name] == generation,
              let recovery = sessionRecoveriesByServer[server.name],
              recovery.id == id,
              recovery.generation == generation,
              recovery.server == server,
              recovery.client === client,
              clientsByServer[server.name] === client,
              servers.first(where: { $0.name == server.name }) == server else {
            return false
        }
        return true
    }

    private func isRegisteredSessionRecovery(
        id: UUID,
        generation: UInt64,
        serverName: String
    ) -> Bool {
        guard sessionRecoveryGenerationByServer[serverName] == generation,
              let recovery = sessionRecoveriesByServer[serverName] else {
            return false
        }
        return recovery.id == id && recovery.generation == generation
    }

    /// Connects one server and returns its discovered tools; callers own
    /// publishing them into `tools`.
    private func sync(server: IOSMcpServerConfig) async -> [IOSMcpDiscoveredTool] {
        invalidateSessionRecovery(serverName: server.name, disconnectClient: true)
        guard server.enabled else {
            clientsByServer[server.name]?.disconnect()
            clientsByServer.removeValue(forKey: server.name)
            statusByServer[server.name] = .idle
            return []
        }

        statusByServer[server.name] = .connecting
        let client = clientsByServer[server.name] ?? clientFactory(server)
        clientsByServer[server.name] = client

        do {
            _ = try await client.connect(config: server)
            let listedTools = try await client.listTools()
            let mergedTools = Self.applyingAuthoritativeSafetyAnnotations(
                from: listedTools,
                to: discoveredToolSink(server.name, listedTools) ?? Self.mergeDiscoveredTools(
                    discovered: listedTools,
                    existing: server.tools
                )
            )
            if let index = servers.firstIndex(where: { $0.name == server.name }) {
                servers[index] = server.withTools(mergedTools)
            }
            statusByServer[server.name] = .connected
            return mergedTools.map { IOSMcpDiscoveredTool(serverName: server.name, tool: $0) }
        } catch {
            statusByServer[server.name] = .error(IOSWebMountRedactor.redactedText(error.localizedDescription))
            return []
        }
    }

    #if DEBUG
    /// Test accessor: clears the reconnect backoff window so a test can retry
    /// immediately without waiting for the exponential delay.
    func clearReconnectBackoffForTesting(serverName: String) {
        lastReconnectAttemptByServer[serverName] = nil
        reconnectAttempts[serverName] = nil
    }
    #endif
}

private final class IOSMcpSyncWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let ready: Result<Void, Error>? = lock.withLock {
            guard let outcome else {
                self.continuation = continuation
                return nil
            }
            return outcome
        }
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ result: Result<Void, Error>) {
        let waiting: CheckedContinuation<Void, Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
