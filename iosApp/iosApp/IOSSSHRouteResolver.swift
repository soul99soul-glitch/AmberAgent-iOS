import Foundation

enum IOSSSHRouteError: Error, LocalizedError, Equatable, Sendable {
    case profileNotFound(id: String)
    case jumpProfileNotFound(id: String, referencedBy: String)
    case jumpCycle(path: [String])
    case jumpChainTooLong(maxJumpHosts: Int, actualJumpHosts: Int)
    case inUseAsJump(profileId: String, dependentProfileIds: [String])
    case keyInUse(keyId: String, dependentProfileIds: [String])
    case keyNotFound(keyId: String)

    var status: String {
        switch self {
        case .profileNotFound:
            return "profile_not_found"
        case .jumpProfileNotFound:
            return "jump_profile_not_found"
        case .jumpCycle:
            return "jump_cycle"
        case .jumpChainTooLong:
            return "jump_chain_too_long"
        case .inUseAsJump:
            return "in_use_as_jump"
        case .keyInUse:
            return "key_in_use"
        case .keyNotFound:
            return "key_not_found"
        }
    }

    func toToolFields() -> [String: Any] {
        switch self {
        case .profileNotFound(let id): return ["profile_id": id]
        case .jumpProfileNotFound(let id, let owner): return ["profile_id": id, "referenced_by": owner]
        case .jumpCycle(let path): return ["path": path]
        case .jumpChainTooLong(let max, let actual): return ["max_jump_hosts": max, "actual_jump_hosts": actual]
        case .inUseAsJump(let id, let dependents): return ["profile_id": id, "used_by_profile_ids": dependents]
        case .keyInUse(let id, let dependents): return ["key_id": id, "used_by_profile_ids": dependents]
        case .keyNotFound(let id): return ["key_id": id]
        }
    }

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            return "找不到 ID 为「\(id)」的 SSH Profile。"
        case .jumpProfileNotFound(let id, let referencedBy):
            return "Profile「\(referencedBy)」引用的跳板机 Profile「\(id)」不存在。"
        case .jumpCycle(let path):
            return "检测到跳板机环路：\(path.joined(separator: " -> "))。"
        case .jumpChainTooLong(let maxJumpHosts, let actualJumpHosts):
            return "跳板链深度为 \(actualJumpHosts)，超过最大允许跳板数（\(maxJumpHosts) 跳）。"
        case .inUseAsJump(let profileId, let dependentProfileIds):
            return "Profile「\(profileId)」正被以下 Profile 作为跳板机引用，无法删除：\(dependentProfileIds.joined(separator: ", "))。"
        case .keyInUse(let keyId, let dependentProfileIds):
            return "密钥「\(keyId)」正被以下 SSH Profile 引用，无法删除：\(dependentProfileIds.joined(separator: ", "))。"
        case .keyNotFound(let keyId):
            return "找不到 ID 为「\(keyId)」的本机 SSH 密钥。"
        }
    }
}

enum IOSSSHRouteResolver {
    static let maxJumpHosts = 3
    static let maxTotalHops = maxJumpHosts + 1

    /// Resolves the ordered connection route `[hop1, hop2, ..., target]` for `targetProfileId`.
    /// For a direct profile (`jumpProfileId == nil`), returns `[target]`.
    static func resolveRoute(
        targetProfileId: String,
        profiles: [IOSSSHProfile]
    ) throws -> [IOSSSHProfile] {
        let byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        guard let target = byId[targetProfileId] else {
            throw IOSSSHRouteError.profileNotFound(id: targetProfileId)
        }
        return try resolveRoute(target: target, profilesById: byId)
    }

    /// Resolves the ordered connection route `[hop1, hop2, ..., target]` for `target`.
    static func resolveRoute(
        target: IOSSSHProfile,
        profiles: [IOSSSHProfile]
    ) throws -> [IOSSSHProfile] {
        var byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        byId[target.id] = target
        return try resolveRoute(target: target, profilesById: byId)
    }

    private static func resolveRoute(
        target: IOSSSHProfile,
        profilesById: [String: IOSSSHProfile]
    ) throws -> [IOSSSHProfile] {
        var reversedChain: [IOSSSHProfile] = [target]
        var visitedOrder: [String] = [target.id]
        var current = target

        while let nextJumpId = current.jumpProfileId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nextJumpId.isEmpty {
            if visitedOrder.contains(nextJumpId) {
                var cyclePath = visitedOrder
                cyclePath.append(nextJumpId)
                // Present the cycle in configuration pointer order (e.g. A -> B -> A)
                throw IOSSSHRouteError.jumpCycle(path: cyclePath)
            }
            guard let jumpProfile = profilesById[nextJumpId] else {
                throw IOSSSHRouteError.jumpProfileNotFound(id: nextJumpId, referencedBy: current.id)
            }
            reversedChain.append(jumpProfile)
            visitedOrder.append(nextJumpId)
            current = jumpProfile
        }

        let jumpCount = reversedChain.count - 1
        if jumpCount > maxJumpHosts {
            throw IOSSSHRouteError.jumpChainTooLong(
                maxJumpHosts: maxJumpHosts,
                actualJumpHosts: jumpCount
            )
        }

        return reversedChain.reversed()
    }

    /// Validates both the candidate profile's own route and all reverse-dependent
    /// profiles in `existingProfiles` whose routes pass through `candidate.id`.
    /// Returns the candidate's resolved route `[hop1, ..., candidate]`.
    @discardableResult
    static func validateUpsert(
        candidate: IOSSSHProfile,
        existingProfiles: [IOSSSHProfile]
    ) throws -> [IOSSSHProfile] {
        var updatedProfiles = existingProfiles
        if let index = updatedProfiles.firstIndex(where: { $0.id == candidate.id }) {
            updatedProfiles[index] = candidate
        } else {
            updatedProfiles.append(candidate)
        }
        let byId = Dictionary(uniqueKeysWithValues: updatedProfiles.map { ($0.id, $0) })

        let candidateRoute = try resolveRoute(target: candidate, profilesById: byId)

        // Check every other profile that directly or transitively references candidate.id
        for profile in updatedProfiles where profile.id != candidate.id {
            if referencesProfile(target: profile, candidateId: candidate.id, profilesById: byId) {
                _ = try resolveRoute(target: profile, profilesById: byId)
            }
        }

        return candidateRoute
    }

    private static func referencesProfile(
        target: IOSSSHProfile,
        candidateId: String,
        profilesById: [String: IOSSSHProfile]
    ) -> Bool {
        var seen: Set<String> = [target.id]
        var current = target
        while let jumpId = current.jumpProfileId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jumpId.isEmpty {
            if jumpId == candidateId {
                return true
            }
            if !seen.insert(jumpId).inserted {
                break
            }
            guard let next = profilesById[jumpId] else {
                break
            }
            current = next
        }
        return false
    }

    /// Returns all profile IDs that directly reference `profileId` as `jumpProfileId`.
    static func dependentProfileIds(
        referencingJumpProfileId profileId: String,
        in profiles: [IOSSSHProfile]
    ) -> [String] {
        profiles
            .filter { $0.id != profileId && $0.jumpProfileId == profileId }
            .map(\.id)
            .sorted()
    }

    /// Rejects deleting `profileId` if any other profile references it as `jumpProfileId`.
    static func validateDeleteProfile(
        id: String,
        existingProfiles: [IOSSSHProfile]
    ) throws {
        let dependents = dependentProfileIds(referencingJumpProfileId: id, in: existingProfiles)
        if !dependents.isEmpty {
            throw IOSSSHRouteError.inUseAsJump(profileId: id, dependentProfileIds: dependents)
        }
    }

    /// Returns all profile IDs that reference `keyId`.
    static func dependentProfileIds(
        referencingKeyId keyId: String,
        in profiles: [IOSSSHProfile]
    ) -> [String] {
        profiles
            .filter { $0.keyId == keyId }
            .map(\.id)
            .sorted()
    }

    /// Rejects deleting `keyId` if any profile references it via `keyId`.
    static func validateDeleteKey(
        keyId: String,
        existingProfiles: [IOSSSHProfile]
    ) throws {
        let dependents = dependentProfileIds(referencingKeyId: keyId, in: existingProfiles)
        if !dependents.isEmpty {
            throw IOSSSHRouteError.keyInUse(keyId: keyId, dependentProfileIds: dependents)
        }
    }
}
