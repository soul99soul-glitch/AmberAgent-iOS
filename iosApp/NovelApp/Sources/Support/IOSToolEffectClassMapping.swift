import Foundation

/// The standalone app never attaches a run ledger to `IOSAgentToolEngine`, so
/// effect classification is not consulted here. Amber's full table lives in
/// `IOSAgentRunLedger.swift`; this keeps its fail-safe default.
enum IOSToolEffectClassMapping {
    static func forToolName(_ toolName: String, input: String) -> IOSToolEffectClass {
        .sideEffect
    }
}
