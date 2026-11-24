import Combine
import SwiftStreamingMarkdown
import UIKit

@MainActor
final class IOSMemoryPressureCoordinator {
    private let observer: AnyCancellable

    init(
        conversationStore: IOSConversationStore,
        sessionStore: IOSWebMountSessionStore,
        notificationCenter: NotificationCenter = .default,
        activeMarkdownMessageIDs: @escaping @MainActor () -> Set<String>
    ) {
        observer = notificationCenter.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { _ in
                Task { @MainActor in
                    ChatStableStreamingMarkdownView.clearMemoryCache(preservingMessageIDs: activeMarkdownMessageIDs())
                    ParagraphUIViewCache.clearRecycledViews()
                    AmberMarkdownAstCache.shared.clearMemoryCache()
                    AmberPersonaStore.loadedShared?.clearReferenceImageCache()
                    IOSWidgetPreviewPool.shared.handleMemoryWarning()
                    sessionStore.reclaimIdleWebViews()
                    await ChatDataImageLoader.shared.clearMemoryCache()
                    await ChatMediaImageLoader.shared.clearMemoryCache()
                    await conversationStore.clearMemoryCache()
                }
            }
    }
}
