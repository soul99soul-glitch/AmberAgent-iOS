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

    private var sortedDedicatedLines: [IOSPhoneAutomationLines.Line] {
        lines.lines
            .filter(\.isDedicated)
            .sorted { ($0.runs.last?.startedAt ?? .distantPast) > ($1.runs.last?.startedAt ?? .distantPast) }
    }

    private var sortedTemporaryLines: [IOSPhoneAutomationLines.Line] {
        lines.lines
            .filter { !$0.isDedicated }
            .sorted { ($0.runs.last?.startedAt ?? .distantPast) > ($1.runs.last?.startedAt ?? .distantPast) }
    }

    var body: some View {
        let dedicated = sortedDedicatedLines
        let temporary = sortedTemporaryLines
        let availableConversationIDs = Set(
            conversationStore.allSummaries.map { $0.id.toHexDashString().lowercased() }
        )

        VStack(spacing: 0) {
            savedTaskHeader("手机自动化", backLabel: "返回导航") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    savedTasksEntryCard

                    if let error = lines.persistenceError {
                        persistenceErrorCard(error)
                            .padding(.top, 14)
                    }

                    if dedicated.isEmpty && temporary.isEmpty {
                        emptyStateCard
                            .padding(.top, 18)
                    } else {
                        if !dedicated.isEmpty {
                            sectionHeader("常用任务线")
                            VStack(spacing: 12) {
                                ForEach(dedicated) { line in
                                    lineCard(line, isAvailable: availableConversationIDs.contains(line.conversationID))
                                }
                            }
                        }

                        if !temporary.isEmpty {
                            sectionHeader("临时任务")
                            VStack(spacing: 12) {
                                ForEach(temporary) { line in
                                    lineCard(line, isAvailable: availableConversationIDs.contains(line.conversationID))
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .background(AmberTheme.background.ignoresSafeArea())
        .foregroundStyle(AmberTheme.foreground)
        .tint(AmberTheme.accent)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { _ = await conversationStore.visibleSummariesForListing() }
    }

    private var savedTasksEntryCard: some View {
        AmberFormGroup {
            Button {
                router.navigate(to: .phoneSavedTasks)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(
                            AmberTheme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("常用任务")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("新建、编辑与运行，保持独立连续上下文")
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.muted2)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
        }
    }

    private func persistenceErrorCard(_ message: String) -> some View {
        AmberFormGroup {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.accentRed)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }

    private var emptyStateCard: some View {
        AmberFormGroup {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 36, height: 36)
                    .background(
                        AmberTheme.surface2,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("还没有自动化记录")
                        .font(.headline)
                        .foregroundStyle(AmberTheme.foreground)
                    Text("运行常用任务或在对话中使用手机控制后，记录会出现在这里。相同常用任务会接续原任务线；临时任务分别保留，不按应用名合并。")
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(AmberTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func lineCard(_ line: IOSPhoneAutomationLines.Line, isAvailable: Bool) -> some View {
        PhoneAutomationLineCardView(
            line: line,
            isConversationAvailable: isAvailable,
            onOpenConversation: { open(line: line) },
            onContinueConversation: {
                lines.selectForContinuation(lineID: line.id)
                open(line: line)
            },
            onOpenRun: { runID in open(line: line, runID: runID) }
        )
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

private struct PhoneAutomationLineCardView: View {
    private static let initialVisibleRunLimit = 10

    let line: IOSPhoneAutomationLines.Line
    let isConversationAvailable: Bool
    let onOpenConversation: () -> Void
    let onContinueConversation: () -> Void
    let onOpenRun: (String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRunsExpanded = false
    @State private var showingAllRuns = false

    var body: some View {
        AmberFormGroup {
            headerButton
            actionOrStatusRow
            if isConversationAvailable && !line.runs.isEmpty {
                cardHairline
                runHistorySection
            }
        }
    }

    private var headerButton: some View {
        Button(action: onOpenConversation) {
            HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
                leadingIconPlate

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: line.title)
                            .font(.headline)
                            .foregroundStyle(AmberTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        runCountPill
                    }
                } else {
                    Text(verbatim: line.title)
                        .font(.headline)
                        .foregroundStyle(AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    runCountPill

                    if isConversationAvailable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AmberTheme.muted2)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, isConversationAvailable ? 6 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isConversationAvailable)
    }

    private var leadingIconPlate: some View {
        Image(systemName: line.isDedicated ? "bolt.fill" : "iphone.gen3")
            .font(.system(size: line.isDedicated ? 15 : 16, weight: line.isDedicated ? .semibold : .medium))
            .foregroundStyle(line.isDedicated ? AmberTheme.accent : AmberTheme.foreground2)
            .frame(width: 36, height: 36)
            .background(
                line.isDedicated ? AmberTheme.accent.opacity(0.12) : AmberTheme.surface2,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var runCountPill: some View {
        Text("\(line.runs.count) 次")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(line.isDedicated ? AmberTheme.accent : AmberTheme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                line.isDedicated ? AmberTheme.accent.opacity(0.10) : AmberTheme.surface2,
                in: Capsule(style: .continuous)
            )
            .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var actionOrStatusRow: some View {
        if isConversationAvailable {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    lastRunTimestampView
                    continueButton(fillsWidth: true)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    lastRunTimestampView
                        .frame(maxWidth: .infinity, alignment: .leading)
                    continueButton(fillsWidth: false)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if line.runs.last?.startedAt != nil {
                    lastRunTimestampView
                }
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted2)
                        .accessibilityHidden(true)
                    Text("原会话已删除或暂时不可用")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var lastRunTimestampView: some View {
        if let date = line.runs.last?.startedAt {
            Text(date, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("尚未运行")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func continueButton(fillsWidth: Bool) -> some View {
        Button(action: onContinueConversation) {
            HStack(spacing: 5) {
                Text("进入对话继续")
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(line.isDedicated ? AmberTheme.accentInk : AmberTheme.accent)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                line.isDedicated ? AmberTheme.accent : AmberTheme.accent.opacity(0.12),
                in: Capsule(style: .continuous)
            )
            .overlay {
                if !line.isDedicated {
                    Capsule(style: .continuous)
                        .stroke(AmberTheme.accent.opacity(0.24), lineWidth: 0.7)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .selection))
        .accessibilityLabel("进入对话继续")
    }

    private var runHistorySection: some View {
        let reversedRuns = Array(line.runs.enumerated().reversed())
        let hasMoreRuns = reversedRuns.count > Self.initialVisibleRunLimit
        let displayedRuns = showingAllRuns ? reversedRuns : Array(reversedRuns.prefix(Self.initialVisibleRunLimit))

        return VStack(spacing: 0) {
            Button {
                if reduceMotion {
                    isRunsExpanded.toggle()
                } else {
                    withAnimation(.snappy(duration: 0.22)) {
                        isRunsExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AmberTheme.muted)
                        .accessibilityHidden(true)
                    Text("运行记录 · \(line.runs.count) 次")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted2)
                        .rotationEffect(.degrees(isRunsExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("运行记录 · \(line.runs.count) 次")
            .accessibilityValue(isRunsExpanded ? "已展开" : "已折叠")

            if isRunsExpanded {
                VStack(spacing: 0) {
                    ForEach(displayedRuns, id: \.element.id) { offset, run in
                        insetHairline
                        Button {
                            onOpenRun(run.id)
                        } label: {
                            runRowContent(round: offset + 1, startedAt: run.startedAt)
                        }
                        .buttonStyle(.plain)
                    }

                    if hasMoreRuns {
                        insetHairline
                        Button {
                            if reduceMotion {
                                showingAllRuns.toggle()
                            } else {
                                withAnimation(.snappy(duration: 0.22)) {
                                    showingAllRuns.toggle()
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(showingAllRuns ? "收起较早记录" : "查看全部 \(line.runs.count) 次")
                                    .font(.footnote.weight(.medium))
                                Image(systemName: showingAllRuns ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(showingAllRuns ? AmberTheme.muted : AmberTheme.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showingAllRuns ? "收起较早记录" : "查看全部 \(line.runs.count) 次")
                    }
                }
                .background(AmberTheme.surface2.opacity(0.28))
            }
        }
    }

    @ViewBuilder
    private func runRowContent(round: Int, startedAt: Date) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    Text("第 \(round) 轮")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(startedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    Text("第 \(round) 轮")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground)
                    Spacer(minLength: 8)
                    Text(startedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(AmberTheme.muted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted2)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var cardHairline: some View {
        Rectangle()
            .fill(AmberTheme.borderSoft)
            .frame(height: 0.5)
    }

    private var insetHairline: some View {
        Rectangle()
            .fill(AmberTheme.borderSoft)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}
