import Foundation

/// Per-run Jev numbers shown in the composer context panel.
struct IOSJevRunSummary: Equatable {
    var decisions: Int
    var memorySelected: Int?
    var memoryInjectionHits: Int?
    var hiddenCharacters: Int?
    var selectedModelId: String?
    var firstVisibleDeltaMs: Int?
    var modelSteps: Int?
    var cacheHitRatio: Double?
}
