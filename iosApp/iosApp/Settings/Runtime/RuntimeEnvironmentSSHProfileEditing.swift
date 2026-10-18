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
            let profile = try currentSSHProfile()
            let draftCredential = draftSSHCredential()
            let persistedProfileBeforeProbe = settingsStore.sshProfiles.first { $0.id == profile.id }
            sshStatus = .testing
            sshVerificationTask = Task {
                do {
                    let result = try await IOSTerminalRuntime.shared.testSSHConnection(profile: profile)
                    guard !Task.isCancelled else { return }
                    switch result.trustState {
                    case .trusted:
                        await verifySSHCredential(
                            profile: profile,
                            draftCredential: draftCredential,
                            persistedProfileBeforeVerification: persistedProfileBeforeProbe
                        )
                    case .needsTrust(let fingerprint):
                        // Probing is read-only. Keep both the in-memory candidate
                        // and the persisted snapshot until explicit trust + auth
                        // succeeds, so cancelling cannot delete old credentials.
                        guard settingsStore.sshProfiles.first(where: { $0.id == profile.id }) == persistedProfileBeforeProbe else {
                            throw IOSSSHError.invalidProfile("连接配置已变化，请重新检查主机指纹。")
                        }
                        sshProbeSnapshot = SSHProbeSnapshot(
                            candidate: profile,
                            persistedProfile: persistedProfileBeforeProbe,
                            fingerprint: fingerprint
                        )
                        sshStatus = .needsTrust(profileId: profile.id, fingerprint: fingerprint)
                    case .mismatch(let expected, let actual):
                        sshProbeSnapshot = nil
                        sshStatus = .failure("主机指纹不匹配。预期 \(expected)，实际 \(actual)。")
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    sshStatus = .failure(error.localizedDescription)
                }
            }
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    func trustSSHHost() {
        guard case .needsTrust(let profileId, _) = sshStatus,
              let snapshot = sshProbeSnapshot,
              snapshot.candidate.id == profileId else { return }
        do {
            let current = try currentSSHProfile()
            guard current == snapshot.candidate,
                  settingsStore.sshProfiles.first(where: { $0.id == profileId }) == snapshot.persistedProfile else {
                throw IOSSSHError.invalidProfile("连接配置已变化，请重新检查主机指纹。")
            }
            var trustedCandidate = snapshot.candidate
            trustedCandidate.knownHostSHA256 = snapshot.fingerprint
            trustedCandidate.knownHostHost = trustedCandidate.host
            trustedCandidate.knownHostPort = trustedCandidate.port
            trustedCandidate = try trustedCandidate.validated()
            // Keep the trusted pin on the in-memory candidate while auth runs;
            // SettingsStore is still untouched until authentication succeeds.
            sshProfileDraft = trustedCandidate
            sshPortDraft = String(trustedCandidate.port)
            let draftCredential = draftSSHCredential()
            sshStatus = .testing
            sshVerificationTask = Task {
                await verifySSHCredential(
                    profile: trustedCandidate,
                    draftCredential: draftCredential,
                    persistedProfileBeforeVerification: snapshot.persistedProfile
                )
            }
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    private func verifySSHCredential(
        profile: IOSSSHProfile,
        draftCredential: IOSSSHCredential?,
        persistedProfileBeforeVerification: IOSSSHProfile?
    ) async {
        guard !Task.isCancelled else { return }
        let savedProfileBefore = persistedProfileBeforeVerification
        guard sharedSettings.isCapabilityGateEnabled(.remoteRuntime) else {
            sshStatus = .failure(IOSCapabilityGate.remoteRuntime.disabledReason)
            return
        }
        do {
            let credential: IOSSSHCredential?
            if let draftCredential { credential = draftCredential }
            else { credential = try settingsStore.credentialForSSHProfile(profile) }
            guard let credential else {
                throw profile.authMethod == .password ? IOSSSHError.missingPassword : IOSSSHError.missingPrivateKey
            }
            let started = await IOSTerminalRuntime.shared.startJob(
                command: "echo amber-terminal-auth-check",
                runtime: .remoteSSH,
                experimentalEnabled: false,
                sshProfile: profile,
                sshCredential: credential,
                timeoutSeconds: 15
            )
            let finished = started.status == IOSTerminalJobStatus.running.rawValue
                ? await IOSTerminalRuntime.shared.waitJob(id: started.id, timeoutSeconds: 20) : started
            if Task.isCancelled { _ = IOSTerminalRuntime.shared.stopJob(id: started.id) }
            _ = IOSTerminalRuntime.shared.consumeTerminalJob(id: started.id)
            guard !Task.isCancelled else { return }
            guard finished?.status == IOSTerminalJobStatus.completed.rawValue && finished?.exitCode == 0 else {
                sshStatus = .failure(finished?.error ?? IOSSSHError.authenticationFailed.localizedDescription)
                return
            }
            // A late verification must not overwrite a newer saved target.
            guard try currentSSHProfile() == profile,
                  settingsStore.sshProfiles.first(where: { $0.id == profile.id }) == savedProfileBefore else {
                throw IOSSSHError.invalidProfile("连接配置已变化，请重新验证认证。")
            }
            try settingsStore.upsertSSHProfile(profile, credential: credential)
            sshPasswordDraft = ""
            sshPrivateKeyDraft = ""
            sshProbeSnapshot = nil
            sshStatus = .success("主机已信任，SSH 认证通过，凭证已安全保存。")
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
        let profile = try currentSSHProfile()
        try settingsStore.upsertSSHProfile(profile, credential: .privateKey(sshPrivateKeyDraft))
        sshProfileDraft = settingsStore.sshProfiles.first { $0.id == profile.id } ?? profile
        sshPrivateKeyDraft = ""
    }

    func generateSSHKey() {
        do {
            let key = try IOSSSHPrivateKey.generate()
            sshPrivateKeyDraft = key.privateKey
            sshPublicKey = key.publicKey
            sshStatus = .success("已生成专用密钥，请保存后将公钥添加到服务器。")
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
            let publicKey = try IOSSSHPrivateKey.publicKey(from: key)
            sshPrivateKeyDraft = key
            sshPublicKey = publicKey
            sshStatus = .success("私钥已读入，请保存。Amber 不会另存明文文件。")
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
            sshStatus = .success("公钥已复制。私钥如未保存，请点击保存私钥。")
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

    private func currentSSHPublicKey() throws -> String {
        if !sshPrivateKeyDraft.isEmpty {
            return try IOSSSHPrivateKey.publicKey(from: sshPrivateKeyDraft)
        }
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
            try settingsStore.clearSSHCredential(profileId: sshProfileDraft.id)
            clearSSHDrafts()
            sshStatus = .success("已清除本机保存的 SSH 凭证。")
        } catch { sshStatus = .failure(error.localizedDescription) }
    }

}
