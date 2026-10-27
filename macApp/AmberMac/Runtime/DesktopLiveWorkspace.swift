import Foundation

@MainActor extension DesktopWorkspace {
    convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Amber", isDirectory: true)
        let settings = DesktopSettings()
        let notifications = DesktopNotifications(settings: settings)
        let files = DesktopWorkspaceFiles(directory: directory.appendingPathComponent("workspaces", isDirectory: true))
        let tasks = DesktopAgentTasks(directory: directory.appendingPathComponent("agent-runs", isDirectory: true), notifications: notifications)
        let knowledge = DesktopKnowledgeStore()
        let mcp = DesktopMCPManager(store: DesktopMCPStore())
        let webDAV = DesktopWebDAVManager()
        let searchSettings = DesktopSearchSettings()
        let imageGeneration = DesktopImageGeneration(settings: settings, files: files, enabled: true)
        let text = DesktopKMPProvider()
        let collaborations = DesktopCollaborations(settings: settings, provider: text,
            directory: directory.appendingPathComponent("collaborations", isDirectory: true), notifications: notifications)
        let provider = DesktopAgentProvider(text: text, tasks: tasks, files: files, knowledge: knowledge, mcp: mcp,
            collaborations: collaborations, searchSettings: searchSettings)
        let names = Set((DesktopToolRegistry.declarations + DesktopToolRegistry.knowledgeDeclarations + DesktopMCPManager.declarations).map(\.name))
        let recipes = DesktopRecipeRuns(store: DesktopRecipeStore(directory: directory, registeredTools: names), tasks: tasks) {
            try await provider.performRecipeTool(runID: $0, owner: $1, name: $2, argumentsJSON: $3)
        }
        self.init(settings: settings, storage: DesktopKMPConversationStorage(directory: directory.appendingPathComponent("conversations", isDirectory: true)),
            provider: provider, insights: DesktopConversationInsights(directory: directory.appendingPathComponent("conversation-insights", isDirectory: true)),
            files: files, agentTasks: tasks, knowledge: knowledge, mcp: mcp, collaborations: collaborations, recipes: recipes, webDAV: webDAV,
            notifications: notifications, storageUsageSources: DesktopStorageUsage.sources(
                amberRoot: directory, knowledgeDirectory: knowledge.directory),
            imageGeneration: imageGeneration, searchSettings: searchSettings,
            artifactShelf: DesktopArtifactShelf(fileURL: directory.appendingPathComponent("artifact-shelf.json")))
        let scheduler = DesktopScheduler(store: DesktopScheduleStore(directory: directory.appendingPathComponent("schedules", isDirectory: true)),
            runner: { [weak self] task, slot in
                guard let self else {
                    return DesktopScheduleRunRecord(scheduledFor: slot, startedAt: Date(), finishedAt: Date(), status: .failed, error: "应用正在退出。")
                }
                return await self.runScheduled(task, scheduledFor: slot)
            })
        scheduler.onRunFinished = { task, record in
            Task { await notifications.notifySchedule(taskName: task.name, record: record) }
        }
        scheduler.startObservingSystem()
        self.scheduler = scheduler
        let gateway = DesktopGateway()
        self.gateway = gateway
        let reporter = DesktopGatewayReporter { gateway.isEnabled }
        gatewayReporter = reporter
        tasks.onUnattendedApproval = { reporter.approval(conversationID: $0, $1) }
    }
}
