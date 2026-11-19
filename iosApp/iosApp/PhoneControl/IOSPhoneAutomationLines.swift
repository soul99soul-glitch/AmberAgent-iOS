import Foundation
import Observation
import Shared
import SwiftUI

/// References existing conversation documents and runtime run IDs; owns no task execution or message copies.
@MainActor @Observable
final class IOSPhoneAutomationLines {
    static let shared = IOSPhoneAutomationLines(defaults: .standard)

    struct Run: Codable, Identifiable, Equatable {
        let id: String
        let startedAt: Date
    }
    struct Line: Codable, Identifiable, Equatable {
        let id: String
        let conversationID: String
        let title: String
        let isDedicated: Bool
        var runs: [Run] = []
    }

    private(set) var lines: [Line] = []
    private(set) var persistenceError: String?
    @ObservationIgnored private var pendingContinuationLineID: String?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "app.amber.ios.phoneAutomationLines.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            do { lines = try JSONDecoder().decode([Line].self, from: data) }
            catch { persistenceError = "无法读取手机自动化记录，请稍后重试。" }
        }
    }

    func savedLine(actionID: String) -> Line? {
        lines.first { $0.id == "saved:\(actionID.lowercased())" }
    }

    func isDedicated(conversationID: String) -> Bool {
        lines.contains { $0.isDedicated && $0.conversationID.caseInsensitiveCompare(conversationID) == .orderedSame }
    }

    func selectForContinuation(lineID: String) {
        pendingContinuationLineID = lines.first { $0.id == lineID }?.id
    }

    func cancelPendingContinuation() { pendingContinuationLineID = nil }

    func keepsContextForNextRequest(conversationID: String) -> Bool {
        isDedicated(conversationID: conversationID) || lines.contains {
            $0.id == pendingContinuationLineID && $0.conversationID == conversationID.lowercased()
        }
    }

    /// Saved lines own each user-requested round, including a failure before the first phone tool.
    /// A temporary line owns only the next explicitly selected Continue request.
    func beginUserRequest(conversationID: String?, runID: String) {
        let selectedID = pendingContinuationLineID
        pendingContinuationLineID = nil
        guard persistenceError == nil, let conversationID else { return }
        let key = conversationID.lowercased()
        let selected = lines.firstIndex { $0.id == selectedID && $0.conversationID == key }
        let dedicated = lines.firstIndex { $0.isDedicated && $0.conversationID == key }
        guard let index = selected ?? dedicated,
              !lines[index].runs.contains(where: { $0.id == runID }) else { return }
        lines[index].runs.append(Run(id: runID, startedAt: .now))
        persist()
    }

    @discardableResult
    func bindSavedTask(actionID: String, title: String, conversationID: String) -> Bool {
        guard persistenceError == nil else { return false }
        let id = "saved:\(actionID.lowercased())"
        lines.removeAll { $0.id == id }
        lines.append(Line(id: id, conversationID: conversationID.lowercased(), title: title, isDedicated: true))
        persist()
        return true
    }

    /// Called on an actual phone tool, not merely because tools were offered to the model.
    func recordRun(conversationID: String, runID: String, now: Date = .now) {
        guard persistenceError == nil, !lines.contains(where: { $0.runs.contains(where: { $0.id == runID }) }) else { return }
        let conversationID = conversationID.lowercased()
        // A saved action is an explicit reusable identity. A chat ID alone is not:
        // two unrelated phone goals can be issued in the same ordinary conversation.
        let dedicated = lines.firstIndex { $0.isDedicated && $0.conversationID == conversationID }
        let id = "run:\(runID)"
        if dedicated == nil, !lines.contains(where: { $0.id == id }) {
            lines.append(Line(id: id, conversationID: conversationID,
                              title: "临时手机任务", isDedicated: false))
        }
        guard let index = dedicated ?? lines.firstIndex(where: { $0.id == id }),
              !lines[index].runs.contains(where: { $0.id == runID }) else { return }
        lines[index].runs.append(Run(id: runID, startedAt: now))
        persist()
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(lines), forKey: Self.key) }
        catch { persistenceError = "无法保存手机自动化记录，请稍后重试。" }
    }
}

extension ChatViewModel {
    /// Keeps launch selection behind the same draft/import/active-run gates as normal conversation navigation.
    func preparePhoneAutomationConversation(
        actionID: String, title: String, lines: IOSPhoneAutomationLines = .shared,
        commitIf: () -> Bool = { true }
    ) async -> Bool {
        guard let store = conversationStore, commitIf(), lines.persistenceError == nil,
              !store.isImportingConversationDocuments else { return false }
        _ = await store.visibleSummariesForListing()
        guard commitIf() else { return false }
        if let line = lines.savedLine(actionID: actionID),
           let summary = store.summaries.first(where: { $0.id.toHexDashString().lowercased() == line.conversationID }) {
            guard prepareForConversationChange(to: summary.id) else { return false }
            return await store.selectConversationIfAvailable(id: summary.id, commitIf: commitIf)
        }
        // Do not reuse another automation's empty document: different saved IDs must stay separate.
        guard prepareForConversationChange(), await store.newConversation(commitIf: commitIf),
              commitIf(), let id = store.currentConversation?.id.toHexDashString() else { return false }
        return lines.bindSavedTask(actionID: actionID, title: title, conversationID: id)
    }
}

struct IOSPhoneAutomationLinesView: View {
    let conversationStore: IOSConversationStore
    var lines: IOSPhoneAutomationLines = .shared
    var inbox: IOSDeepLinkInbox = .shared
    @Environment(RouterPath.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            savedTaskHeader("手机自动化", backLabel: "返回导航") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button { router.navigate(to: .phoneSavedTasks) } label: {
                        Label("常用任务 · 新建与运行", systemImage: "play.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    Text("反复运行的自动化可保存为常用任务，每项任务保持自己的连续上下文。")
                        .font(.footnote).foregroundStyle(AmberTheme.muted)
                    if let error = lines.persistenceError { Text(error).foregroundStyle(AmberTheme.accent) }
                    if lines.lines.isEmpty {
                        Text("运行常用任务或在对话中使用手机控制后，记录会出现在这里。相同常用任务会接续原任务线；临时任务分别保留，不按应用名合并。")
                            .foregroundStyle(AmberTheme.muted)
                    }
                    ForEach(lines.lines.sorted { ($0.runs.last?.startedAt ?? .distantPast) > ($1.runs.last?.startedAt ?? .distantPast) }) { line in
                        let summary = conversationStore.allSummaries.first { $0.id.toHexDashString().lowercased() == line.conversationID }
                        Button {
                            open(line: line)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(line.title)
                                    .font(.headline).foregroundStyle(AmberTheme.foreground)
                                Text("\(line.runs.count) 次运行 · 查看原对话")
                                    .font(.subheadline).foregroundStyle(AmberTheme.muted)
                                if let date = line.runs.last?.startedAt {
                                    Text(date, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption).foregroundStyle(AmberTheme.muted)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(summary == nil)
                        if summary != nil {
                            Button {
                                lines.selectForContinuation(lineID: line.id)
                                open(line: line)
                            } label: {
                                Text("进入对话继续").frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                        if summary == nil {
                            Text("原会话已删除或暂时不可用").font(.caption).foregroundStyle(AmberTheme.muted)
                        } else if !line.runs.isEmpty {
                            DisclosureGroup {
                                ForEach(Array(line.runs.enumerated()).reversed(), id: \.element.id) { offset, run in
                                    Button { open(line: line, runID: run.id) } label: {
                                        HStack {
                                            Text("第 \(offset + 1) 轮")
                                            Spacer()
                                            Text(run.startedAt, format: .dateTime.month().day().hour().minute())
                                        }
                                        .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                                    }
                                }
                            } label: {
                                Text("运行记录 · \(line.runs.count) 次").frame(minHeight: 44)
                            }
                            .tint(AmberTheme.accent)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(AmberTheme.background.ignoresSafeArea())
        .foregroundStyle(AmberTheme.foreground)
        .tint(AmberTheme.accent)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { _ = await conversationStore.visibleSummariesForListing() }
    }

    private func open(line: IOSPhoneAutomationLines.Line, runID: String? = nil) {
        let destination: IOSAppDeepLink.Destination = runID.map {
            .agentActivity(.init(runId: $0, conversationId: line.conversationID, focus: .result))
        } ?? .conversation(id: line.conversationID)
        if let url = IOSAppDeepLink.url(for: destination) {
            MacGatewayStore.shared.setCloudMainDialogueSelected(false)
            router.phoneAutomationChatPresentationRevision &+= 1
            inbox.submit(url)
        }
    }
}
