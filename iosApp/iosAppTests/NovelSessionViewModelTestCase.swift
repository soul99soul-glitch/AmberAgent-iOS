import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
class NovelSessionViewModelTestCase: XCTestCase {
    struct NovelSessionLayoutHarness: View {
        let workspace: NovelCreationViewModel
        let session: NovelSessionViewModel
        let settings: any IOSSettingsSnapshotSource

        @State private var inputText = ""
        @State private var injectionOverrides = NovelInjectionOverrides.none
        @State private var inputBudgetTokens = 16_000
        @State private var composerInputController = ComposerInputController()

        var body: some View {
            NovelSessionView(
                workspace: workspace,
                viewModel: session,
                sharedSettings: settings,
                inputText: $inputText,
                injectionOverrides: $injectionOverrides,
                inputBudgetTokens: $inputBudgetTokens,
                composerInputController: composerInputController,
                onOpenModel: {},
                onOpenCollection: { _ in },
                onOpenManualRewrite: { _ in },
                onFork: { _ in },
                onOpenSettingProposals: { _ in },
                onAcceptSettingProposal: { _ in },
                onArchiveDiscussion: {}
            )
        }
    }

    struct Harness {
        let repository: any NovelProjectPersisting
        let adapter: ScriptedNovelModelAdapter
        let workspace: NovelCreationViewModel
        let session: NovelSessionViewModel
        let projectID: NovelProjectID
        let snapshotGate: NovelSessionSnapshotFailingCreation?
        let attachGate: NovelSessionAttachBlockingCreation?
        let performReturnGate: NovelSessionPerformReturnBlockingCreation?
    }

    func makeWindow(rootViewController: UIViewController) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        }
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    func makeHarness(
        repository: (any NovelProjectPersisting)? = nil,
        document: NovelProjectDocumentV1? = nil,
        scripts: [NovelModelScript],
        resolutionFailure: NovelModelFailure? = nil,
        usesSnapshotGate: Bool = false,
        usesAttachGate: Bool = false,
        usesPerformReturnGate: Bool = false,
        terminalQuietDelay: TimeInterval = 0
    ) async throws -> Harness {
        let document = try document ?? NovelTestFixtures.document()
        let repository = repository ?? InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "session-provider",
                ownerProviderID: "session-owner",
                modelID: "session-model",
                wireModelID: "session-wire",
                displayName: "Session Model",
                contextWindowTokens: 128_000
            ),
            resolutionFailure: resolutionFailure,
            scripts: scripts
        )
        let baseCreation = DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter,
            now: { Date(timeIntervalSince1970: 1_700_800_000) }
        )
        let snapshotGate = usesSnapshotGate
            ? NovelSessionSnapshotFailingCreation(base: baseCreation)
            : nil
        let attachGate = usesAttachGate
            ? NovelSessionAttachBlockingCreation(base: baseCreation)
            : nil
        let performReturnGate = usesPerformReturnGate
            ? NovelSessionPerformReturnBlockingCreation(base: baseCreation)
            : nil
        let creation: any NovelCreation
        if let snapshotGate {
            creation = snapshotGate
        } else if let attachGate {
            creation = attachGate
        } else if let performReturnGate {
            creation = performReturnGate
        } else {
            creation = baseCreation
        }
        let workspace = NovelCreationViewModel(creation: creation)
        await workspace.loadProjects(selecting: document.project.id)
        // 默认 0 静窗 = 完成即退役的快路径,保持既有用例的「完成即清空 tail」契约;
        // 验证延迟退役的新用例显式注入 >0 的静窗。
        let session = NovelSessionViewModel(workspace: workspace, terminalQuietDelay: terminalQuietDelay)
        await session.bindToCurrentSelection()
        return Harness(
            repository: repository,
            adapter: adapter,
            workspace: workspace,
            session: session,
            projectID: document.project.id,
            snapshotGate: snapshotGate,
            attachGate: attachGate,
            performReturnGate: performReturnGate
        )
    }

    func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    /// CADisplayLink 逐帧采样主线程帧间隔（与 Chat perf 探针同款）。display link
    /// 回调被主线程阻塞多久，gap 就记录多久——直接量化「逐 chunk 直上 UI」的掉帧。
    final class DisplayLinkGapProbe: NSObject {
        private var displayLink: CADisplayLink?
        private var previousTimestamp: CFTimeInterval?
        private(set) var gaps: [TimeInterval] = []

        func start() {
            let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            previousTimestamp = nil
        }

        @objc private func tick(_ displayLink: CADisplayLink) {
            defer { previousTimestamp = displayLink.timestamp }
            guard let previousTimestamp else { return }
            gaps.append(displayLink.timestamp - previousTimestamp)
        }
    }

    func documentWithChapter(
        content: String = "Mara crossed the hall. The gate stayed closed."
    ) throws -> (
        document: NovelProjectDocumentV1,
        chapterID: NovelChapterID
    ) {
        var document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let branch = document.branches[0]
        let chapterID = NovelChapterID()
        let versionID = NovelChapterVersionID()
        document.chapters.append(NovelChapterRecord(id: chapterID, createdAt: document.project.updatedAt))
        document.chapterVersions.append(NovelChapterVersionRecord(
            id: versionID,
            chapterID: chapterID,
            kind: .collected,
            title: "第一章",
            content: content,
            factCompatibilityID: UUID(),
            sourceCandidateID: nil,
            createdAt: document.project.updatedAt,
            operationID: document.appliedOperations[0].operationID
        ))
        let selection = NovelChapterSelection(chapterID: chapterID, versionID: versionID)
        let checkpointIndex = try XCTUnwrap(document.checkpoints.firstIndex {
            $0.id == branch.headCheckpointID
        })
        let checkpoint = document.checkpoints[checkpointIndex]
        document.checkpoints[checkpointIndex] = NovelBranchCheckpointRecord(
            id: checkpoint.id,
            kind: checkpoint.kind,
            createdOnBranchID: checkpoint.createdOnBranchID,
            parentCheckpointID: checkpoint.parentCheckpointID,
            chapterSelections: [selection],
            stateSnapshotID: checkpoint.stateSnapshotID,
            sessionCursor: checkpoint.sessionCursor,
            branchOverrideRevisionIDs: checkpoint.branchOverrideRevisionIDs,
            sourceCandidateID: checkpoint.sourceCandidateID,
            baseHeadRevision: checkpoint.baseHeadRevision,
            operationID: checkpoint.operationID,
            createdAt: checkpoint.createdAt
        )
        document.branches[0].workingChapterSelections = [selection]
        try NovelDocumentValidator.validate(document)
        return (document, chapterID)
    }

    func persistedManualSync(
        status: NovelPendingOperationStatus
    ) throws -> (
        document: NovelProjectDocumentV1,
        pendingID: NovelPendingOperationID
    ) {
        let fixture = try documentWithChapter()
        let branch = fixture.document.branches[0]
        let edit = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: fixture.document.project.revision,
                expectedConfigRevision: fixture.document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: fixture.document.project.id,
            branchID: branch.id,
            chapterID: fixture.chapterID,
            versionID: NovelChapterVersionID(),
            title: "第一章",
            content: "Mara opened the archive.",
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        let edited = try NovelReducer.apply(.saveManualEdit(edit), to: fixture.document).document
        let editedBranch = edited.branches[0]
        let sync = NovelSyncManualEditsCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: edited.project.revision,
                expectedConfigRevision: edited.project.configRevision,
                expectedBranchHeadRevision: editedBranch.headRevision
            ),
            projectID: edited.project.id,
            branchID: editedBranch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: editedBranch.workingRevision
        )
        var prepared = try NovelFactTransactionReducer.prepareManualSync(
            sync,
            payloadSHA256: sync.canonicalPayloadSHA256(),
            in: edited
        ).document
        if status == .retryable {
            prepared = try NovelFactTransactionReducer.markRetryable(
                pendingID: sync.pendingID,
                message: "上一次状态同步超时",
                in: prepared
            )
        }
        return (prepared, sync.pendingID)
    }

    func overlayRetryableManualSync(
        on document: NovelProjectDocumentV1
    ) throws -> NovelProjectDocumentV1 {
        let branch = document.branches[0]
        let selection = try XCTUnwrap(branch.workingChapterSelections.first)
        let version = try XCTUnwrap(document.chapterVersions.first {
            $0.id == selection.versionID
        })
        let edit = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: document.project.revision,
                expectedConfigRevision: document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: document.project.id,
            branchID: branch.id,
            chapterID: selection.chapterID,
            versionID: NovelChapterVersionID(),
            title: version.title,
            content: version.content + "\nShe waited for the archivist.",
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        let edited = try NovelReducer.apply(.saveManualEdit(edit), to: document).document
        let editedBranch = edited.branches[0]
        let sync = NovelSyncManualEditsCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: edited.project.revision,
                expectedConfigRevision: edited.project.configRevision,
                expectedBranchHeadRevision: editedBranch.headRevision
            ),
            projectID: edited.project.id,
            branchID: editedBranch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: editedBranch.workingRevision
        )
        let prepared = try NovelFactTransactionReducer.prepareManualSync(
            sync,
            payloadSHA256: sync.canonicalPayloadSHA256(),
            in: edited
        ).document
        return try NovelFactTransactionReducer.markRetryable(
            pendingID: sync.pendingID,
            message: "上一次状态同步超时",
            in: prepared
        )
    }

    func assertPersistedManualSyncResumes(
        status: NovelPendingOperationStatus
    ) async throws {
        let fixture = try persistedManualSync(status: status)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .complete,
            ])]
        )

        try? await Task.sleep(for: .milliseconds(100))
        let requestsBeforeAppearance = await harness.adapter.requests
        XCTAssertEqual(requestsBeforeAppearance.count, 0)

        harness.workspace.scheduleAutomaticStateSyncIfNeeded()

        let syncCompleted = await eventually {
            guard let loaded = try? await harness.repository.loadProject(id: harness.projectID) else {
                return false
            }
            return loaded.document.pendingOperations.isEmpty &&
                loaded.document.branches[0].syncStatus == .synchronized &&
                harness.workspace.projectSnapshot?.pendingOperations.isEmpty == true &&
                harness.workspace.branchSnapshot?.branch.syncStatus == .synchronized &&
                !harness.workspace.isPerforming
        }
        XCTAssertTrue(syncCompleted)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
    }

    func documentWithMaterials() throws -> (
        document: NovelProjectDocumentV1,
        materialIDs: [NovelMaterialID]
    ) {
        var document = try NovelTestFixtures.document()
        let materialIDs = [NovelMaterialID(), NovelMaterialID()]
        for (index, materialID) in materialIDs.enumerated() {
            document = try NovelReducer.apply(
                NovelTestFixtures.materialAction(
                    document: document,
                    materialID: materialID,
                    revisionID: NovelMaterialRevisionID(),
                    title: "资料 \(index + 1)",
                    content: "设定内容 \(index + 1)"
                ),
                to: document
            ).document
        }
        return (document, materialIDs)
    }

    func documentWithUnresolvedCharacterMention(
        _ mention: String
    ) throws -> NovelProjectDocumentV1 {
        var document = try NovelTestFixtures.document()
        let baseState = document.stateSnapshots[0]
        let event = NovelStoryEventRecord(
            id: NovelEventID(),
            sequence: 0,
            kind: "character.appearance",
            summary: "\(mention)短暂出现。",
            entityReferences: [mention],
            createdAt: baseState.createdAt
        )
        document.events.append(event)
        document.stateSnapshots[0] = NovelStateSnapshotRecord(
            id: baseState.id,
            eventIDs: [event.id],
            summary: event.summary,
            branchOutline: event.summary,
            unresolvedEntityNames: [mention],
            createdAt: baseState.createdAt
        )
        try NovelDocumentValidator.validate(document)
        return document
    }

    func quickStartDocument() throws -> NovelProjectDocumentV1 {
        try NovelReducer.createProject(NovelCreateProjectCommand(
            context: NovelTestFixtures.context(operationID: NovelOperationID()),
            projectID: NovelProjectID(),
            branchID: NovelBranchID(),
            sessionID: NovelSessionID(),
            initialStateSnapshotID: NovelStateSnapshotID(),
            initialCheckpointID: NovelCheckpointID(),
            name: "快速开始",
            branchName: "主线",
            creationMode: .quickStart,
            quickStartSeed: NovelQuickStartSeed(genre: "悬疑", coreIdea: "记忆可以作证")
        ), now: Date(timeIntervalSince1970: 1_700_000_000)).document
    }

    var quickStartSuggestionsJSON: String {
        """
        {
          "schemaVersion": 1,
          "overview": "一座会保存证词记忆的城市。",
          "world": {"title": "记忆城", "content": "记忆可以被封存并出庭作证。"},
          "characters": {"title": "人物", "content": "调查员林遥追查一段伪造记忆。"},
          "masterOutline": {"title": "总纲", "content": "林遥逐步发现城市证词系统被篡改。"},
          "writingRequirements": {"title": "写作要求", "content": "克制、悬疑，保持线索公平。"}
        }
        """
    }

    var validDeltaJSON: String {
        """
        {
          "schemaVersion": 1,
          "stateSummary": "Mara entered the archive.",
          "events": [{
            "id": "archive-opened",
            "kind": "discovery",
            "summary": "Mara entered the archive.",
            "entityReferences": ["Mara"],
            "evidence": "Mara opened the archive."
          }],
          "characterChanges": [],
          "relationshipChanges": [],
          "foreshadowingChanges": [],
          "unresolvedEntityNames": ["Mara"],
          "branchOutlinePatch": "Mara investigates the archive.",
          "settingProposals": []
        }
        """
    }

    var validRevisionDeltaJSON: String {
        """
        {
          "schemaVersion": 1,
          "stateSummary": "第二段的矛盾已经改掉。",
          "events": [{
            "id": "event-fixed",
            "kind": "discovery",
            "summary": "矛盾已改。",
            "entityReferences": [],
            "evidence": "第二段已经改掉了那个矛盾。"
          }],
          "characterChanges": [],
          "relationshipChanges": [],
          "foreshadowingChanges": [],
          "unresolvedEntityNames": [],
          "branchOutlinePatch": "矛盾已改。",
          "settingProposals": []
        }
        """
    }

    var validRebuildJSON: String {
        """
        {
          "schemaVersion": 1,
          "stateSummary": "Mara entered the archive.",
          "branchOutline": "Mara investigates the archive.",
          "events": [{
            "id": "archive-opened",
            "kind": "discovery",
            "summary": "Mara entered the archive.",
            "entityReferences": ["Mara"],
            "evidence": "Mara opened the archive."
          }],
          "characterStates": [],
          "relationships": [],
          "foreshadowing": [],
          "unresolvedEntityNames": ["Mara"],
          "settingProposals": []
        }
        """
    }

    var compatibleDriftJSON: String {
        """
        {"schemaVersion":1,"compatible":true,"differences":[]}
        """
    }

    var incompatibleDriftJSON: String {
        """
        {
          "schemaVersion": 1,
          "compatible": false,
          "differences": [{
            "id": "gate-opened",
            "category": "event",
            "summary": "The gate opened.",
            "sourceEvidence": "The gate stayed closed.",
            "candidateEvidence": "Mara opened the gate."
          }]
        }
        """
    }
}

actor NovelSessionSnapshotFailingCreation: NovelCreation {
    private let base: any NovelCreation
    private var remainingSnapshotFailures = 0
    private var remainingBranchSnapshotFailures = 0
    private var remainingProjectSnapshotFailures = 0
    private var shouldBlockNextSnapshot = false
    private var blockedSnapshotContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextProjectSnapshot = false
    private var blockedProjectSnapshotContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextPerform = false
    private var blockedPerformContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockInterruptReturn = false
    private var blockedInterruptContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextBindingRestore = false
    private var blockedBindingRestoreContinuation: CheckedContinuation<Void, Never>?

    init(base: any NovelCreation) {
        self.base = base
    }

    func blockNextBindingRestore() {
        shouldBlockNextBindingRestore = true
    }

    func bindingRestoreIsBlocked() -> Bool {
        blockedBindingRestoreContinuation != nil
    }

    func resumeBlockedBindingRestore() {
        let continuation = blockedBindingRestoreContinuation
        blockedBindingRestoreContinuation = nil
        continuation?.resume()
    }

    // Binding restores this sidecar after warming the transcript. Holding that
    // await lets the accepted Quick Start finish before binding returns.
    func loadGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelGhostwriteBatchProgressRecord? {
        if shouldBlockNextBindingRestore {
            shouldBlockNextBindingRestore = false
            await withCheckedContinuation { blockedBindingRestoreContinuation = $0 }
        }
        return try await base.loadGhostwriteBatchProgress(projectID: projectID, branchID: branchID)
    }

    func failNextSnapshots(_ count: Int) {
        remainingSnapshotFailures = count
    }

    func failNextBranchSnapshots(_ count: Int) {
        remainingBranchSnapshotFailures = count
    }

    func failNextProjectSnapshots(_ count: Int) {
        remainingProjectSnapshotFailures = count
    }

    func blockNextSnapshot() {
        shouldBlockNextSnapshot = true
    }

    func snapshotIsBlocked() -> Bool {
        blockedSnapshotContinuation != nil
    }

    func resumeBlockedSnapshot() {
        let continuation = blockedSnapshotContinuation
        blockedSnapshotContinuation = nil
        continuation?.resume()
    }

    func blockNextProjectSnapshot() {
        shouldBlockNextProjectSnapshot = true
    }

    func projectSnapshotIsBlocked() -> Bool {
        blockedProjectSnapshotContinuation != nil
    }

    func resumeBlockedProjectSnapshot() {
        let continuation = blockedProjectSnapshotContinuation
        blockedProjectSnapshotContinuation = nil
        continuation?.resume()
    }

    func blockNextPerform() {
        shouldBlockNextPerform = true
    }

    func performIsBlocked() -> Bool {
        blockedPerformContinuation != nil
    }

    func resumeBlockedPerform() {
        let continuation = blockedPerformContinuation
        blockedPerformContinuation = nil
        continuation?.resume()
    }

    func blockInterruptReturn() {
        shouldBlockInterruptReturn = true
    }

    func interruptReturnIsBlocked() -> Bool {
        blockedInterruptContinuation != nil
    }

    func resumeBlockedInterruptReturn() {
        let continuation = blockedInterruptContinuation
        blockedInterruptContinuation = nil
        continuation?.resume()
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        if shouldBlockNextSnapshot {
            shouldBlockNextSnapshot = false
            await withCheckedContinuation { continuation in
                blockedSnapshotContinuation = continuation
            }
        }
        if case .project = scope, shouldBlockNextProjectSnapshot {
            shouldBlockNextProjectSnapshot = false
            await withCheckedContinuation { continuation in
                blockedProjectSnapshotContinuation = continuation
            }
        }
        if case .branch = scope, remainingBranchSnapshotFailures > 0 {
            remainingBranchSnapshotFailures -= 1
            throw NovelError.repositoryFailure("Injected branch snapshot refresh failure.")
        }
        if case .project = scope, remainingProjectSnapshotFailures > 0 {
            remainingProjectSnapshotFailures -= 1
            throw NovelError.repositoryFailure("Injected project snapshot refresh failure.")
        }
        if remainingSnapshotFailures > 0 {
            remainingSnapshotFailures -= 1
            throw NovelError.repositoryFailure("Injected snapshot refresh failure.")
        }
        return try await base.snapshot(scope)
    }

    func perform(_ action: NovelAction) async throws -> NovelOutcome {
        if shouldBlockNextPerform {
            shouldBlockNextPerform = false
            await withCheckedContinuation { continuation in
                blockedPerformContinuation = continuation
            }
        }
        return try await base.perform(action)
    }

    func start(_ request: NovelRunRequest) async throws -> NovelRun {
        try await base.start(request)
    }

    func interruptRun(_ command: NovelCancelRunCommand) async throws {
        try await base.interruptRun(command)
        if shouldBlockInterruptReturn {
            shouldBlockInterruptReturn = false
            await withCheckedContinuation { continuation in
                blockedInterruptContinuation = continuation
            }
        }
    }

    func interruptForBackground(
        projectID: NovelProjectID,
        deadline: Date,
        runID: NovelRunID?
    ) async {
        await base.interruptForBackground(
            projectID: projectID,
            deadline: deadline,
            runID: runID
        )
    }

    func cancelInFlightBackgroundMutations(projectID: NovelProjectID) async {
        await base.cancelInFlightBackgroundMutations(projectID: projectID)
    }

    func retryPendingTerminal(runID: NovelRunID) async throws {
        try await base.retryPendingTerminal(runID: runID)
    }
}

actor NovelSessionAttachBlockingCreation: NovelCreation {
    private let base: any NovelCreation
    private var shouldBlockNextStart = false
    private var shouldFailNextStart = false
    private var blockedStartContinuation: CheckedContinuation<Void, Never>?

    init(base: any NovelCreation) {
        self.base = base
    }

    func blockNextStart() {
        shouldBlockNextStart = true
    }

    func failNextStart() {
        shouldFailNextStart = true
    }

    func startIsBlocked() -> Bool {
        blockedStartContinuation != nil
    }

    func resumeBlockedStart() {
        let continuation = blockedStartContinuation
        blockedStartContinuation = nil
        continuation?.resume()
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        try await base.snapshot(scope)
    }

    func perform(_ action: NovelAction) async throws -> NovelOutcome {
        try await base.perform(action)
    }

    func start(_ request: NovelRunRequest) async throws -> NovelRun {
        if shouldFailNextStart {
            shouldFailNextStart = false
            throw NovelError.repositoryFailure("Injected active-run subscription failure.")
        }
        if shouldBlockNextStart {
            shouldBlockNextStart = false
            await withCheckedContinuation { continuation in
                blockedStartContinuation = continuation
            }
        }
        return try await base.start(request)
    }

    func interruptRun(_ command: NovelCancelRunCommand) async throws {
        try await base.interruptRun(command)
    }

    func interruptForBackground(
        projectID: NovelProjectID,
        deadline: Date,
        runID: NovelRunID?
    ) async {
        await base.interruptForBackground(
            projectID: projectID,
            deadline: deadline,
            runID: runID
        )
    }

    func cancelInFlightBackgroundMutations(projectID: NovelProjectID) async {
        await base.cancelInFlightBackgroundMutations(projectID: projectID)
    }

    func retryPendingTerminal(runID: NovelRunID) async throws {
        try await base.retryPendingTerminal(runID: runID)
    }
}

actor NovelSessionPerformReturnBlockingCreation: NovelCreation {
    private let base: any NovelCreation
    private var shouldBlockNextAdoptionReturn = false
    private var adoptionReturnIsBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var returnContinuation: CheckedContinuation<Void, Never>?

    init(base: any NovelCreation) {
        self.base = base
    }

    func blockNextAdoptionReturn() {
        shouldBlockNextAdoptionReturn = true
    }

    func waitUntilAdoptionReturnBlocked() async {
        guard !adoptionReturnIsBlocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func resumeAdoptionReturn() {
        adoptionReturnIsBlocked = false
        let continuation = returnContinuation
        returnContinuation = nil
        continuation?.resume()
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        try await base.snapshot(scope)
    }

    func perform(_ action: NovelAction) async throws -> NovelOutcome {
        let outcome = try await base.perform(action)
        guard shouldBlockNextAdoptionReturn,
              case .adoptPolishCandidate = action else { return outcome }
        shouldBlockNextAdoptionReturn = false
        adoptionReturnIsBlocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { returnContinuation = $0 }
        return outcome
    }

    func start(_ request: NovelRunRequest) async throws -> NovelRun {
        try await base.start(request)
    }

    func interruptRun(_ command: NovelCancelRunCommand) async throws {
        try await base.interruptRun(command)
    }

    func interruptForBackground(
        projectID: NovelProjectID,
        deadline: Date,
        runID: NovelRunID?
    ) async {
        await base.interruptForBackground(
            projectID: projectID,
            deadline: deadline,
            runID: runID
        )
    }

    func cancelInFlightBackgroundMutations(projectID: NovelProjectID) async {
        await base.cancelInFlightBackgroundMutations(projectID: projectID)
    }

    func retryPendingTerminal(runID: NovelRunID) async throws {
        try await base.retryPendingTerminal(runID: runID)
    }
}

actor NovelSessionFailingRepository: NovelProjectPersisting {
    private let base = InMemoryNovelProjectRepository()
    private var remainingCommitFailures = 0
    private var shouldBlockNextCommit = false
    private var blockedCommitContinuation: CheckedContinuation<Void, Never>?

    func failNextCommits(_ count: Int) {
        remainingCommitFailures = count
    }

    func blockNextCommit() {
        shouldBlockNextCommit = true
    }

    func commitIsBlocked() -> Bool {
        blockedCommitContinuation != nil
    }

    func resumeBlockedCommit() {
        let continuation = blockedCommitContinuation
        blockedCommitContinuation = nil
        continuation?.resume()
    }

    func listProjects() async throws -> [NovelProjectSummary] {
        try await base.listProjects()
    }

    func loadProject(id: NovelProjectID) async throws -> NovelLoadedProject {
        try await base.loadProject(id: id)
    }

    func createProject(_ document: NovelProjectDocumentV1) async throws -> NovelLoadedProject {
        try await base.createProject(document)
    }

    func commitProject(
        _ document: NovelProjectDocumentV1,
        expectedRevision: Int64,
        authorization: NovelRepositoryCommitAuthorization?
    ) async throws -> NovelLoadedProject {
        if shouldBlockNextCommit {
            shouldBlockNextCommit = false
            await withCheckedContinuation { continuation in
                blockedCommitContinuation = continuation
            }
        }
        if remainingCommitFailures > 0 {
            remainingCommitFailures -= 1
            throw NovelError.repositoryFailure("Injected session terminal failure.")
        }
        return try await base.commitProject(
            document,
            expectedRevision: expectedRevision,
            authorization: authorization
        )
    }

    func restorePreviousProject(
        id: NovelProjectID,
        expectedDocumentSHA256: String
    ) async throws -> NovelLoadedProject {
        try await base.restorePreviousProject(
            id: id,
            expectedDocumentSHA256: expectedDocumentSHA256
        )
    }

    func listRecoverySidecars() async throws -> [NovelRecoverySidecarV1] {
        try await base.listRecoverySidecars()
    }

    func writeRecoverySidecar(_ sidecar: NovelRecoverySidecarV1) async throws {
        try await base.writeRecoverySidecar(sidecar)
    }

    func removeRecoverySidecar(projectID: NovelProjectID, runID: NovelRunID) async throws {
        try await base.removeRecoverySidecar(projectID: projectID, runID: runID)
    }
}
