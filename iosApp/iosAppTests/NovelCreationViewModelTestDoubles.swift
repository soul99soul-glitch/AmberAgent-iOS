import XCTest
@testable import iosApp

actor NovelPlanSaveCompletionGate {
    private var isSuspended = false
    private var suspensionWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        suspensionWaiter?.resume()
        suspensionWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { suspensionWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

actor BranchSnapshotBlockingNovelCreation: NovelCreation {
    private let base: any NovelCreation
    private let blockedBranchID: NovelBranchID
    private var didRequestBranchSnapshot = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var branchWaiter: CheckedContinuation<Void, Never>?
    private var nextProjectSnapshotGate: NovelPlanSaveCompletionGate?

    init(base: any NovelCreation, blockedBranchID: NovelBranchID) {
        self.base = base
        self.blockedBranchID = blockedBranchID
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        if case .project = scope, let gate = nextProjectSnapshotGate {
            nextProjectSnapshotGate = nil
            await gate.suspend()
        }
        if case .branch(_, let branchID) = scope, branchID == blockedBranchID {
            didRequestBranchSnapshot = true
            requestWaiter?.resume()
            requestWaiter = nil
            await withCheckedContinuation { continuation in
                branchWaiter = continuation
            }
        }
        return try await base.snapshot(scope)
    }

    func blockNextProjectSnapshot(using gate: NovelPlanSaveCompletionGate) {
        nextProjectSnapshotGate = gate
    }

    func waitUntilBranchSnapshotRequested() async {
        if didRequestBranchSnapshot { return }
        await withCheckedContinuation { continuation in
            requestWaiter = continuation
        }
    }

    func resumeBranchSnapshot() {
        branchWaiter?.resume()
        branchWaiter = nil
    }

    func perform(_ action: NovelAction) async throws -> NovelOutcome {
        try await base.perform(action)
    }

    func start(_ request: NovelRunRequest) async throws -> NovelRun {
        try await base.start(request)
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

actor OrderedProjectListNovelCreation: NovelCreation {
    private let base: any NovelCreation
    private var requestCount = 0
    private var requestedOrdinals: Set<Int> = []
    private var requestWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedOrdinals: Set<Int> = []

    init(base: any NovelCreation) {
        self.base = base
    }

    func waitUntilProjectListRequest(_ ordinal: Int) async {
        if requestedOrdinals.contains(ordinal) { return }
        await withCheckedContinuation { continuation in
            requestWaiters[ordinal] = continuation
        }
    }

    func releaseProjectListRequest(_ ordinal: Int) {
        releasedOrdinals.insert(ordinal)
        releaseWaiters.removeValue(forKey: ordinal)?.resume()
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        if case .projects = scope {
            requestCount += 1
            let ordinal = requestCount
            requestedOrdinals.insert(ordinal)
            requestWaiters.removeValue(forKey: ordinal)?.resume()
            if !releasedOrdinals.contains(ordinal) {
                await withCheckedContinuation { continuation in
                    releaseWaiters[ordinal] = continuation
                }
            }
        }
        return try await base.snapshot(scope)
    }

    func perform(_ action: NovelAction) async throws -> NovelOutcome {
        try await base.perform(action)
    }

    func start(_ request: NovelRunRequest) async throws -> NovelRun {
        try await base.start(request)
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

actor SnapshotFailureNovelCreation: NovelCreation {
    private let base: any NovelCreation
    private var remainingProjectSnapshotFailures = 0
    private var remainingProjectListSnapshotFailures = 0
    private(set) var projectSnapshotFailureCount = 0
    private(set) var projectListSnapshotFailureCount = 0
    private(set) var projectImportPreviewSnapshotCount = 0
    private(set) var backgroundInterruptionProjectIDs: [NovelProjectID] = []
    private var shouldGateNextProjectListSnapshot = false
    private(set) var didRequestGatedProjectListSnapshot = false
    private var projectListRequestWaiter: CheckedContinuation<Void, Never>?
    private var projectListReleaseWaiter: CheckedContinuation<Void, Never>?

    init(base: any NovelCreation) {
        self.base = base
    }

    func failNextProjectSnapshots(_ count: Int) {
        remainingProjectSnapshotFailures = count
    }

    func failNextProjectListSnapshots(_ count: Int) {
        remainingProjectListSnapshotFailures = count
    }

    func gateNextProjectListSnapshot() {
        shouldGateNextProjectListSnapshot = true
    }

    func waitUntilProjectListSnapshotRequested() async {
        if didRequestGatedProjectListSnapshot { return }
        await withCheckedContinuation { continuation in
            projectListRequestWaiter = continuation
        }
    }

    func releaseProjectListSnapshot() {
        shouldGateNextProjectListSnapshot = false
        projectListReleaseWaiter?.resume()
        projectListReleaseWaiter = nil
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        if case .projects = scope, shouldGateNextProjectListSnapshot {
            didRequestGatedProjectListSnapshot = true
            projectListRequestWaiter?.resume()
            projectListRequestWaiter = nil
            await withCheckedContinuation { continuation in
                projectListReleaseWaiter = continuation
            }
        }
        if case .projects = scope, remainingProjectListSnapshotFailures > 0 {
            remainingProjectListSnapshotFailures -= 1
            projectListSnapshotFailureCount += 1
            throw NovelError.repositoryFailure("Injected project list snapshot failure.")
        }
        if case .project = scope, remainingProjectSnapshotFailures > 0 {
            remainingProjectSnapshotFailures -= 1
            projectSnapshotFailureCount += 1
            throw NovelError.repositoryFailure("Injected project snapshot failure.")
        }
        if case .projectImportPreview = scope {
            projectImportPreviewSnapshotCount += 1
        }
        return try await base.snapshot(scope)
    }

    func perform(_ action: NovelAction) async throws -> NovelOutcome {
        try await base.perform(action)
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
        backgroundInterruptionProjectIDs.append(projectID)
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
