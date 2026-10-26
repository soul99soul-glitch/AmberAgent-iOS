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
    }
}
