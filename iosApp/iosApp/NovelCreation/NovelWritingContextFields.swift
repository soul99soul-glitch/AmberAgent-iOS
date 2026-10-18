import Observation
import SwiftUI

@MainActor
@Observable
final class NovelWritingContextFieldState {
    var planPlacement: String
    var planGoal: String
    var planMustHappen: String
    var planMustNotHappen: String
    var planEndingHook: String
    var planVisibleFacts: String
    var upcomingArcBeats: String

    @ObservationIgnored private(set) var planFieldsDirty = false
    @ObservationIgnored private(set) var arcFieldsDirty = false
    @ObservationIgnored private(set) var planEditRevision = 0
    @ObservationIgnored private(set) var arcEditRevision = 0
    @ObservationIgnored private var isReloadingPlanFields = false
    @ObservationIgnored private var isReloadingArcFields = false
    @ObservationIgnored let fieldBank = NovelIMEFieldBank()

    init(plan: NovelChapterPlanRecord?, arc: NovelUpcomingArcRecord?, retainedDraft: NovelChapterPlanDraft? = nil) {
        planPlacement = retainedDraft?.outlinePlacement ?? plan?.outlinePlacement ?? ""
        planGoal = retainedDraft?.goalAndConflict ?? plan?.goalAndConflict ?? ""
        planMustHappen = (retainedDraft?.mustHappen ?? plan?.mustHappen ?? []).joined(separator: "\n")
        planMustNotHappen = (retainedDraft?.mustNotHappen ?? plan?.mustNotHappen ?? []).joined(separator: "\n")
        planEndingHook = retainedDraft?.endingHook ?? plan?.endingHook ?? ""
        planVisibleFacts = (retainedDraft?.visibleFacts ?? plan?.visibleFacts ?? []).joined(separator: "\n")
        upcomingArcBeats = arc?.beats.joined(separator: "\n") ?? ""
        planFieldsDirty = retainedDraft != nil
    }

    func reloadPlan(_ plan: NovelChapterPlanRecord?) {
        isReloadingPlanFields = true
        planPlacement = plan?.outlinePlacement ?? ""
        planGoal = plan?.goalAndConflict ?? ""
        planMustHappen = plan?.mustHappen.joined(separator: "\n") ?? ""
        planMustNotHappen = plan?.mustNotHappen.joined(separator: "\n") ?? ""
        planEndingHook = plan?.endingHook ?? ""
        planVisibleFacts = plan?.visibleFacts.joined(separator: "\n") ?? ""
        planFieldsDirty = false
        isReloadingPlanFields = false
    }

    func reloadArc(_ arc: NovelUpcomingArcRecord?) {
        isReloadingArcFields = true
        upcomingArcBeats = arc?.beats.joined(separator: "\n") ?? ""
        arcFieldsDirty = false
        isReloadingArcFields = false
    }

    func markPlanClean(ifUnchangedSince revision: Int) {
        guard planEditRevision == revision else { return }
        planFieldsDirty = false
    }

    func markArcClean(ifUnchangedSince revision: Int) {
        guard arcEditRevision == revision else { return }
        arcFieldsDirty = false
    }

    func markPlanEdited() {
        if !isReloadingPlanFields {
            planEditRevision += 1
            planFieldsDirty = true
        }
    }

    func markArcEdited() {
        if !isReloadingArcFields {
            arcEditRevision += 1
            arcFieldsDirty = true
        }
    }
}

@MainActor
final class NovelGhostwriteReadinessIssuesCache {
    private struct Key: Equatable {
        let projectRevision: Int64
        let branchID: NovelBranchID
    }

    private var key: Key?
    private var cachedIssues: [NovelGhostwriteReadinessIssue] = []

    func issues(for workspace: NovelCreationViewModel) -> [NovelGhostwriteReadinessIssue] {
        guard let project = workspace.projectSnapshot,
              let branchID = workspace.selectedBranchID else { return [.branchNeedsSync] }
        let nextKey = Key(projectRevision: project.project.revision, branchID: branchID)
        if key == nextKey { return cachedIssues }

        let issues = workspace.ghostwriteReadinessIssues(requireChapterPlan: false)
        key = nextKey
        cachedIssues = issues
        return issues
    }
}

struct NovelWritingContextFieldRow: View {
    let title: String
    @Bindable var fields: NovelWritingContextFieldState
    let field: Field
    let placeholder: String
    let isEnabled: Bool
    let minHeight: CGFloat

    enum Field: Equatable {
        case goal
        case mustHappen
        case mustNotHappen
        case endingHook
        case visibleFacts
        case upcomingArc
    }

    private var textBinding: Binding<String> {
        let source: Binding<String>
        switch field {
        case .goal: source = $fields.planGoal
        case .mustHappen: source = $fields.planMustHappen
        case .mustNotHappen: source = $fields.planMustNotHappen
        case .endingHook: source = $fields.planEndingHook
        case .visibleFacts: source = $fields.planVisibleFacts
        case .upcomingArc: source = $fields.upcomingArcBeats
        }
        return Binding(
            get: { source.wrappedValue },
            set: { newValue in
                source.wrappedValue = newValue
                if field == .upcomingArc {
                    fields.markArcEdited()
                } else {
                    fields.markPlanEdited()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(AmberTheme.muted)
            NovelIMETextEditor(
                text: textBinding,
                placeholder: IOSAppLocalization.string(placeholder, defaultValue: placeholder),
                isEnabled: isEnabled,
                minHeight: minHeight,
                bank: fields.fieldBank
            )
            .frame(minHeight: minHeight)
        }
    }
}

struct NovelWritingContextPlacementFieldRow: View {
    @Bindable var fields: NovelWritingContextFieldState
    let isEnabled: Bool

    private var textBinding: Binding<String> {
        let source = $fields.planPlacement
        return Binding(
            get: { source.wrappedValue },
            set: { newValue in
                source.wrappedValue = newValue
                fields.markPlanEdited()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("与总纲的位置").font(.footnote).foregroundStyle(AmberTheme.muted)
            NovelIMETextField(
                text: textBinding,
                placeholder: IOSAppLocalization.string("例如：第 3 章", defaultValue: "例如：第 3 章"),
                isEnabled: isEnabled,
                bank: fields.fieldBank
            )
            .frame(minHeight: 36)
        }
    }
}
