import Foundation

/// 成功路径的轻量记忆：同一个 App 上一次跑通的步骤序列，供下一轮参考。
///
/// 只存「做了什么」（动作与目标文字），不存 ref、坐标或截图 —— 那些每轮观测都会变，
/// 存下来只会误导下一次。匹配粒度故意做到 App 级：目标之间的相似度判断交给模型，
/// 这里不猜。
enum PhoneRecipeStore {
    static let key = "app.amber.ios.phoneControl.recipes.v1"
    private static let maximumSteps = 12

    static func save(
        bundleID: String,
        goal: String,
        steps: [String],
        defaults: UserDefaults = .standard
    ) {
        guard !bundleID.isEmpty, !steps.isEmpty else { return }
        var all = defaults.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        all[bundleID] = ["goal": goal, "steps": Array(steps.suffix(maximumSteps))]
        defaults.set(all, forKey: key)
    }

    static func lastPath(bundleID: String, defaults: UserDefaults = .standard) -> [String]? {
        guard !bundleID.isEmpty,
              let all = defaults.dictionary(forKey: key) as? [String: [String: Any]],
              let entry = all[bundleID],
              let steps = entry["steps"] as? [String], !steps.isEmpty else { return nil }
        return steps
    }
}
