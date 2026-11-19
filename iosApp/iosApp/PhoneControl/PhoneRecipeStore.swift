import Foundation

/// 成功路径的轻量记忆（v2）：同一个 App 最多保留 5 条最近常用目标与步骤，仅供模型参考。
///
/// 硬规则：只作提示词参考，不保存 ref/截图/像素坐标，不提供自动多步回放/执行能力。
/// 存储前自动经过凭据脱敏与敏感界面（密码/OTP/支付等）过滤。
struct PhoneRecipeEntry: Codable, Equatable, Sendable {
    let bundleID: String
    let goal: String
    let steps: [String]
    let successCount: Int
    let lastUsedAtEpochMs: Int64
    var needsReverify: Bool
}

enum PhoneRecipeStore {
    static let legacyKey = "app.amber.ios.phoneControl.recipes.v1"
    static let key = "app.amber.ios.phoneControl.recipes.v2"
    static let maxRecipesPerApp = 5
    private static let maximumSteps = 12
    private static let maximumGoalLength = 160
    private static let maximumStepLength = 160

    private static let sensitiveKeywords = [
        "password", "passcode", "pincode", "pin code", "otp", "one-time",
        "verification code", "2fa", "authenticator", "keychain", "biometric",
        "payment", "checkout", "credit card", "debit card", "wallet", "apple pay",
        "密码", "口令", "验证码", "支付", "付款", "转账", "银行卡", "门禁", "生物识别", "钥匙串"
    ]

    static func isSensitiveContext(bundleID: String, goal: String, steps: [String]) -> Bool {
        let combined = ([bundleID, goal] + steps).joined(separator: "\n").lowercased()
        return sensitiveKeywords.contains { combined.contains($0) }
    }

    static func save(
        bundleID: String,
        goal: String,
        steps: [String],
        isSensitive: Bool = false,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let cleanBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleID.isEmpty, !steps.isEmpty else { return }
        guard !isSensitive, !isSensitiveContext(bundleID: cleanBundleID, goal: goal, steps: steps) else {
            return
        }

        let sanitizedGoal = sanitizeText(goal, maxLength: maximumGoalLength)
        let sanitizedSteps = Array(
            steps.suffix(maximumSteps)
                .map { sanitizeText($0, maxLength: maximumStepLength) }
                .filter { !$0.isEmpty }
        )
        guard !sanitizedSteps.isEmpty else { return }

        var all = loadAllV2(defaults: defaults)
        var list = all[cleanBundleID] ?? []
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let normalizedGoal = normalizeGoal(sanitizedGoal)

        if let index = list.firstIndex(where: { normalizeGoal($0.goal) == normalizedGoal }) {
            let existing = list[index]
            let updated = PhoneRecipeEntry(
                bundleID: cleanBundleID,
                goal: sanitizedGoal.isEmpty ? existing.goal : sanitizedGoal,
                steps: sanitizedSteps,
                successCount: existing.successCount + 1,
                lastUsedAtEpochMs: nowMs,
                needsReverify: false
            )
            list[index] = updated
        } else {
            let entry = PhoneRecipeEntry(
                bundleID: cleanBundleID,
                goal: sanitizedGoal.isEmpty ? "default" : sanitizedGoal,
                steps: sanitizedSteps,
                successCount: 1,
                lastUsedAtEpochMs: nowMs,
                needsReverify: false
            )
            list.append(entry)
        }

        list.sort { lhs, rhs in
            if lhs.lastUsedAtEpochMs != rhs.lastUsedAtEpochMs {
                return lhs.lastUsedAtEpochMs > rhs.lastUsedAtEpochMs
            }
            return lhs.successCount > rhs.successCount
        }
        all[cleanBundleID] = Array(list.prefix(maxRecipesPerApp))
        persistV2(all, defaults: defaults)
    }

    static func candidates(
        bundleID: String,
        goal: String? = nil,
        limit: Int = 3,
        defaults: UserDefaults = .standard
    ) -> [PhoneRecipeEntry] {
        let cleanBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleID.isEmpty, limit > 0 else { return [] }
        let entries = loadAllV2(defaults: defaults)[cleanBundleID] ?? []
        guard !entries.isEmpty else { return [] }

        let targetNormalized = goal.map(normalizeGoal) ?? ""
        let sorted = entries.sorted { lhs, rhs in
            if !targetNormalized.isEmpty {
                let lhsMatch = normalizeGoal(lhs.goal) == targetNormalized
                let rhsMatch = normalizeGoal(rhs.goal) == targetNormalized
                if lhsMatch != rhsMatch { return lhsMatch }
            }
            if lhs.needsReverify != rhs.needsReverify {
                return !lhs.needsReverify && rhs.needsReverify
            }
            if lhs.lastUsedAtEpochMs != rhs.lastUsedAtEpochMs {
                return lhs.lastUsedAtEpochMs > rhs.lastUsedAtEpochMs
            }
            return lhs.successCount > rhs.successCount
        }
        return Array(sorted.prefix(min(limit, maxRecipesPerApp)))
    }

    static func markNeedsReverify(
        bundleID: String,
        goal: String,
        defaults: UserDefaults = .standard
    ) {
        let cleanBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleID.isEmpty else { return }
        var all = loadAllV2(defaults: defaults)
        guard var list = all[cleanBundleID], !list.isEmpty else { return }
        let target = normalizeGoal(goal)
        var changed = false
        for index in list.indices {
            if target.isEmpty || normalizeGoal(list[index].goal) == target {
                if !list[index].needsReverify {
                    list[index].needsReverify = true
                    changed = true
                }
            }
        }
        if changed {
            all[cleanBundleID] = list
            persistV2(all, defaults: defaults)
        }
    }

    static func lastPath(bundleID: String, defaults: UserDefaults = .standard) -> [String]? {
        candidates(bundleID: bundleID, goal: nil, limit: 1, defaults: defaults).first?.steps
    }

    private static func loadAllV2(defaults: UserDefaults) -> [String: [PhoneRecipeEntry]] {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [PhoneRecipeEntry]].self, from: data) {
            return decoded
        }
        // 自动无损迁移 v1 -> v2
        guard let legacy = defaults.dictionary(forKey: legacyKey) as? [String: [String: Any]],
              !legacy.isEmpty else {
            return [:]
        }
        var migrated: [String: [PhoneRecipeEntry]] = [:]
        for (bundleID, payload) in legacy {
            let cleanID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty,
                  let rawSteps = payload["steps"] as? [String],
                  !rawSteps.isEmpty else { continue }
            let rawGoal = (payload["goal"] as? String) ?? "default"
            guard !isSensitiveContext(bundleID: cleanID, goal: rawGoal, steps: rawSteps) else { continue }
            let cleanGoal = sanitizeText(rawGoal, maxLength: maximumGoalLength)
            let cleanSteps = Array(
                rawSteps.suffix(maximumSteps)
                    .map { sanitizeText($0, maxLength: maximumStepLength) }
                    .filter { !$0.isEmpty }
            )
            guard !cleanSteps.isEmpty else { continue }
            migrated[cleanID] = [
                PhoneRecipeEntry(
                    bundleID: cleanID,
                    goal: cleanGoal.isEmpty ? "default" : cleanGoal,
                    steps: cleanSteps,
                    successCount: 1,
                    lastUsedAtEpochMs: 0,
                    needsReverify: false
                )
            ]
        }
        if !migrated.isEmpty {
            persistV2(migrated, defaults: defaults)
        }
        return migrated
    }

    private static func persistV2(_ map: [String: [PhoneRecipeEntry]], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }

    private static func sanitizeText(_ text: String, maxLength: Int) -> String {
        let redacted = IOSContextCompactionFidelity.redactCredentials(text)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(maxLength))
    }

    private static func normalizeGoal(_ goal: String) -> String {
        goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
