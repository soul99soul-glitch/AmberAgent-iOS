// Amber-only glue: the chat tool runtime serves the novel discussion agent.
// Kept outside NovelCreation/ so the standalone Novel app does not link it.
extension ChatToolRuntime: NovelDiscussionToolHost {}
