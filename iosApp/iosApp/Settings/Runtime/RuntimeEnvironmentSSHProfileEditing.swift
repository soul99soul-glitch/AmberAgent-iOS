import SwiftUI
import UIKit

extension RuntimeEnvironmentView {
    var sshHostBinding: Binding<String> {
        Binding(
            get: { sshProfileDraft.host },
            set: { newValue in updateSSHConnectionDraft { sshProfileDraft.host = newValue } }
        )
    }

    var sshPortBinding: Binding<String> {
        Binding(
            get: { sshPortDraft },
            set: { newValue in updateSSHConnectionDraft { sshPortDraft = newValue } }
        )
    }

    var sshUsernameBinding: Binding<String> {
        Binding(
            get: { sshProfileDraft.username },
            set: { newValue in updateSSHConnectionDraft { sshProfileDraft.username = newValue } }
        )
    }

    var sshAuthMethodBinding: Binding<IOSSSHAuthMethod> {
        Binding(
            get: { sshProfileDraft.authMethod },
            set: { newValue in updateSSHConnectionDraft { sshProfileDraft.authMethod = newValue } }
        )
    }

    private func updateSSHConnectionDraft(_ update: () -> Void) {
        update()
        invalidateSSHVerificationState()
    }

    private func invalidateSSHVerificationState() {
        sshVerificationTask?.cancel()
        sshVerificationTask = nil
        sshProbeSnapshot = nil
        switch sshStatus {
        case .testing, .needsTrust, .success:
            sshStatus = .idle
        case .idle, .failure:
            break
        }
    }

    private func currentSSHProfile() throws -> IOSSSHProfile {
        var draft = sshProfileDraft
        draft.port = Int(sshPortDraft) ?? 0
        return try draft.validated()
    }

    private func draftSSHCredential() -> IOSSSHCredential? {
        switch sshProfileDraft.authMethod {
        case .password: sshPasswordDraft.isEmpty ? nil : .password(sshPasswordDraft)
        case .privateKey: sshPrivateKeyDraft.isEmpty ? nil : .privateKey(sshPrivateKeyDraft)
        }
    }

    func saveSSHProfile() {
        do {
            if sshProfileDraft.authMethod == .privateKey, !sshPrivateKeyDraft.isEmpty { try persistSSHKeyDraft() }
            let profile = try currentSSHProfile()
            try settingsStore.upsertSSHProfile(profile, credential: draftSSHCredential())
            sshProfileDraft = settingsStore.sshProfiles.first { $0.id == profile.id } ?? profile
            sshPasswordDraft = ""
            sshPrivateKeyDraft = ""
            sshStatus = .success("连接配置已保存。请检查主机指纹并验证认证。")
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    func loadSSHProfile(_ profile: IOSSSHProfile) {
        clearSSHDrafts()
        sshProfileDraft = profile
        sshPortDraft = String(profile.port)
        sshStatus = .idle
    }

    func testSSHConnection() {
        guard sharedSettings.isCapabilityGateEnabled(.remoteRuntime) else {
            sshStatus = .failure(IOSCapabilityGate.remoteRuntime.disabledReason)
            return
        }
        do {
            if sshProfileDraft.authMethod == .privateKey, !sshPrivateKeyDraft.isEmpty { try persistSSHKeyDraft() }
            let target = try currentSSHProfile()
            let route = try settingsStore.resolveSSHRoute(for: target)
            let persisted = settingsStore.sshProfiles
            var credentials: [String: IOSSSHCredential] = [:]
            // A probe only authenticates the already trusted prefix.
            for hop in route.dropLast() {
                guard hop.knownHostSHA256 != nil else { break }
                credentials[hop.id] = try settingsStore.credentialForSSHProfile(hop)
            }
            sshStatus = .testing
            sshVerificationTask = Task {
                do {
                    let results = try await IOSTerminalRuntime.shared.testSSHRoute(route: route, credentials: credentials)
                    guard !Task.isCancelled else { return }
                    guard try currentSSHProfile() == target, settingsStore.sshProfiles == persisted,
                          let last = results.last,
                          let hop = route.first(where: { $0.id == last.profileId }) else {
                        throw IOSSSHError.invalidProfile("连接配置已变化，请重新检查指纹。")
                    }
                    switch last.trustState {
                    case .trusted:
                        guard last.hopIndex == route.count else { throw IOSSSHError.credentialUnavailable }
                        await verifySSHCredential(profile: target, persistedProfiles: persisted)
                    case .needsTrust, .mismatch:
                        sshProbeSnapshot = SSHProbeSnapshot(
                            candidate: hop, persistedProfile: persisted.first { $0.id == hop.id },
                            fingerprint: last.fingerprint, target: target, route: route,
                            hopIndex: last.hopIndex, replacesFingerprint: hop.knownHostSHA256 != nil
                        )
                        sshStatus = .needsTrust(profileId: hop.id, fingerprint: last.fingerprint)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    sshStatus = .failure(error.localizedDescription)
                }
            }
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    func trustSSHHost() {
        guard let snapshot = sshProbeSnapshot else { return }
        do {
            guard try currentSSHProfile() == snapshot.target,
                  try settingsStore.resolveSSHRoute(for: snapshot.target) == snapshot.route,
                  settingsStore.sshProfiles.first(where: { $0.id == snapshot.candidate.id }) == snapshot.persistedProfile else {
                throw IOSSSHError.invalidProfile("连接配置已变化，请重新检查指纹。")
            }
            var trusted = snapshot.candidate
            trusted.knownHostSHA256 = snapshot.fingerprint
            trusted.knownHostHost = trusted.host
            trusted.knownHostPort = trusted.port
            trusted.knownHostViaJump = trusted.jumpProfileId
            if trusted.id == sshProfileDraft.id {
                // Do not write credentials or a new endpoint until the target authenticates.
                sshProfileDraft = trusted
            } else {
                try settingsStore.upsertSSHProfile(trusted, credential: nil)
            }
            sshProbeSnapshot = nil
            testSSHConnection()
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    private func verifySSHCredential(profile: IOSSSHProfile, persistedProfiles: [IOSSSHProfile]) async {
        do {
            let route = try settingsStore.resolveSSHRoute(for: profile)
            var credentials: [String: IOSSSHCredential] = [:]
            for hop in route {
                if hop.id == profile.id, let draft = draftSSHCredential() { credentials[hop.id] = draft }
                else { credentials[hop.id] = try settingsStore.credentialForSSHProfile(hop) }
            }
            let started = await IOSTerminalRuntime.shared.startJob(
                command: "echo amber-terminal-auth-check", runtime: .remoteSSH,
                experimentalEnabled: false, sshProfile: profile,
                sshCredential: credentials[profile.id], sshRoute: route,
                sshRouteCredentials: credentials, timeoutSeconds: 15
            )
            let finished = started.status == IOSTerminalJobStatus.running.rawValue
                ? await IOSTerminalRuntime.shared.waitJob(id: started.id, timeoutSeconds: 20) : started
            if Task.isCancelled { _ = IOSTerminalRuntime.shared.stopJob(id: started.id) }
            _ = IOSTerminalRuntime.shared.consumeTerminalJob(id: started.id)
            guard !Task.isCancelled else { return }
            guard finished?.status == IOSTerminalJobStatus.completed.rawValue, finished?.exitCode == 0 else {
                throw IOSSSHError.commandFailed(finished?.error ?? IOSSSHError.authenticationFailed.localizedDescription)
            }
            guard try currentSSHProfile() == profile, settingsStore.sshProfiles == persistedProfiles else {
                throw IOSSSHError.invalidProfile("连接配置已变化，请重新验证认证。")
            }
            // Key-id credentials already belong to the key store and must not be copied into the legacy store.
            try settingsStore.upsertSSHProfile(profile, credential: profile.keyId == nil ? credentials[profile.id] : nil)
            sshPasswordDraft = ""
            sshPrivateKeyDraft = ""
            sshPassphraseDraft = ""
            sshProbeSnapshot = nil
            sshStatus = .success("整条路由已信任，SSH 认证通过，配置已保存。")
        } catch {
            guard !Task.isCancelled else { return }
            sshStatus = .failure(error.localizedDescription)
        }
    }

    func saveSSHKeyDraft() {
        do {
            if sshPrivateKeyDraft.isEmpty {
                saveSSHProfile()
            } else {
                try persistSSHKeyDraft()
                sshStatus = .success("私钥已保存到本机钥匙串。")
            }
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    private func persistSSHKeyDraft() throws {
        let key = try settingsStore.importSSHKey(
            name: settingsStore.uniqueSSHKeyName(base: "\(sshProfileDraft.displayName)-imported"),
            privateKey: sshPrivateKeyDraft, passphrase: sshPassphraseDraft.isEmpty ? nil : sshPassphraseDraft
        )
        sshProfileDraft.authMethod = .privateKey
        sshProfileDraft.keyId = key.id
        sshPrivateKeyDraft = ""
        sshPassphraseDraft = ""
        sshPublicKey = key.publicKeyOpenSSH
    }

    func generateSSHKey() {
        do {
            let key = try settingsStore.generateSSHKey(
                name: settingsStore.uniqueSSHKeyName(base: "\(sshProfileDraft.displayName)-key"),
                type: sshKeyGenerationType, requireUserPresence: sshKeyRequireUserPresence
            )
            sshProfileDraft.authMethod = .privateKey
            sshProfileDraft.keyId = key.id
            sshPrivateKeyDraft = ""
            sshPassphraseDraft = ""
            sshPublicKey = key.publicKeyOpenSSH
            sshStatus = .success("密钥已保存。请复制公钥交给服务器管理员，并保存 Profile。")
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    func deleteSavedSSHKey(_ key: IOSSSHKeyMetadata) {
        do {
            try settingsStore.deleteSSHKey(id: key.id)
            if sshProfileDraft.keyId == key.id { sshProfileDraft.keyId = nil; sshPublicKey = "" }
            sshStatus = .success("已删除密钥「\(key.name)」。")
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    func importSSHPrivateKey(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536, let key = String(data: data, encoding: .utf8) else {
                throw IOSSSHError.invalidPrivateKey
            }
            sshPrivateKeyDraft = key
            sshPublicKey = ""
            sshStatus = .success("私钥已读入；如已加密，请填写口令后导入。")
        } catch let error as IOSSSHError { sshStatus = .failure(error.localizedDescription) }
        catch { sshStatus = .failure("无法读取私钥文件，请重新选择。") }
    }

    func showSSHPublicKey() {
        do {
            sshPublicKey = try currentSSHPublicKey()
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    func copySSHPublicKey() {
        do {
            if !sshPrivateKeyDraft.isEmpty {
                try persistSSHKeyDraft()
            }
            sshPublicKey = try currentSSHPublicKey()
            UIPasteboard.general.string = sshPublicKey
            sshStatus = .success("公钥已复制，请添加到服务器的 authorized_keys。")
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    private func currentSSHPublicKey() throws -> String {
        if !sshPrivateKeyDraft.isEmpty {
            return try IOSSSHPrivateKey.publicKey(from: sshPrivateKeyDraft, passphrase: sshPassphraseDraft.isEmpty ? nil : sshPassphraseDraft)
        }
        if let id = sshProfileDraft.keyId, let key = settingsStore.sshKey(id: id) { return key.publicKeyOpenSSH }
        let profile = try currentSSHProfile()
        guard case .privateKey(let key) = try settingsStore.credentialForSSHProfile(profile) else {
            throw IOSSSHError.missingPrivateKey
        }
        return try IOSSSHPrivateKey.publicKey(from: key)
    }

    func clearSSHDrafts() {
        sshVerificationTask?.cancel()
        sshVerificationTask = nil
        sshPasswordDraft = ""
        sshPrivateKeyDraft = ""
        sshPassphraseDraft = ""
        sshPublicKey = ""
        showsSSHPublicKey = false
        sshProbeSnapshot = nil
        sshStatus = .idle
    }

    func cancelSSHProbe() {
        sshVerificationTask?.cancel()
        sshVerificationTask = nil
        sshProbeSnapshot = nil
        sshStatus = .idle
    }

    func resetSSHProfileDraft() {
        clearSSHDrafts()
        sshProfileDraft = IOSSSHProfile()
        sshPortDraft = "22"
    }

    func clearSSHCredential() {
        do {
            let hadKeyBinding = sshProfileDraft.keyId != nil
            try settingsStore.clearSSHCredential(profileId: sshProfileDraft.id)
            sshProfileDraft.keyId = nil
            clearSSHDrafts()
            sshStatus = .success(hadKeyBinding ? "已解除当前 Profile 的密钥绑定；本机密钥保留。" : "已清除本机保存的 SSH 凭证。")
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

}
