import Foundation

/// Tool source for the novel discussion agent. Amber's `ChatToolRuntime` and the
/// standalone Novel app each provide one. The creation is back-filled weakly by
/// `NovelCreationComposition` so host ↔ creation never form a strong cycle.
@MainActor
protocol NovelDiscussionToolHost: AnyObject, Sendable {
    var novelProjectCreation: DefaultNovelCreation? { get set }
    func novelDiscussionToolExecutors(
        projectContext: NovelProjectToolRunContext?
    ) -> [String: any IOSToolExecutor]
}
