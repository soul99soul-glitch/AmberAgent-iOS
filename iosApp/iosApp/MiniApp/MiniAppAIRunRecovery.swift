import Foundation

@MainActor
enum IOSMiniAppAIRunRecovery {
    static let interruptedSummary = "上次 AI 生成已中断，可重新运行。"

    static func reconcile() async {
        let durableRunStore = IOSDurableRunStore()
        guard let runs = try? await durableRunStore.recoverableRuns(
            descriptorIds: [IOSDurableRunStore.Descriptor.miniAppAI]
        ) else { return }
        for run in runs {
            guard let inputRef = run.inputSnapshotRef,
                  inputRef.hasPrefix("miniapp:"),
                  !String(inputRef.dropFirst("miniapp:".count)).isEmpty else { continue }
            let appId = String(inputRef.dropFirst("miniapp:".count))
            guard (try? await durableRunStore.transitionFromAnyActive(
                runId: run.runId,
                to: .interrupted,
                detail: "process_restarted"
            )) == true else { continue }
            try? IOSMiniAppRepository.shared.audit(
                appId: appId,
                method: "ai.generate",
                permission: IOSMiniAppPermission.aiGenerate.rawValue,
                summary: interruptedSummary,
                payload: run.runId
            )
        }
    }
}
