import SwiftUI
import UIKit

extension RuntimeEnvironmentView {
    var sshJumpProfileBinding: Binding<String> {
        Binding(
            get: { sshProfileDraft.jumpProfileId ?? "" },
            set: { newValue in
                let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                sshProfileDraft.jumpProfileId = normalized.isEmpty ? nil : normalized
                sshVerificationTask?.cancel()
                sshVerificationTask = nil
                sshProbeSnapshot = nil
                sshStatus = .idle
            }
        )
    }

    var availableJumpProfiles: [IOSSSHProfile] {
        settingsStore.sshProfiles.filter { candidate in
            guard candidate.id != sshProfileDraft.id else { return false }
            var preview = settingsStore.sshProfiles
            var draft = sshProfileDraft
            draft.jumpProfileId = candidate.id
            if let idx = preview.firstIndex(where: { $0.id == draft.id }) {
                preview[idx] = draft
            } else {
                preview.append(draft)
            }
            return (try? IOSSSHRouteResolver.resolveRoute(targetProfileId: draft.id, profiles: preview)) != nil
        }
    }

    var currentJumpRoutePreview: String {
        guard let jumpId = sshProfileDraft.jumpProfileId, !jumpId.isEmpty else {
            return "直连（不使用跳板）"
        }
        var preview = settingsStore.sshProfiles
        if let idx = preview.firstIndex(where: { $0.id == sshProfileDraft.id }) {
            preview[idx] = sshProfileDraft
        } else {
            preview.append(sshProfileDraft)
        }
        if let route = try? IOSSSHRouteResolver.resolveRoute(targetProfileId: sshProfileDraft.id, profiles: preview) {
            return route.enumerated().map { idx, hop in
                "\(idx + 1). \(hop.displayName)"
            }.joined(separator: " → ")
        }
        if let jump = settingsStore.sshProfiles.first(where: { $0.id == jumpId }) {
            return "\(jump.displayName) → \(sshProfileDraft.displayName)"
        }
        return "跳板配置异常"
    }

    @ViewBuilder
    var sshJumpHostRow: some View {
        Menu {
            Button("无（直连）") {
                sshJumpProfileBinding.wrappedValue = ""
            }
            ForEach(availableJumpProfiles) { candidate in
                Button("\(candidate.displayName)（\(candidate.username)@\(candidate.host):\(candidate.port)）") {
                    sshJumpProfileBinding.wrappedValue = candidate.id
                }
            }
        } label: {
            RuntimeValueRow(
                title: "跳板机（ProxyJump）",
                subtitle: currentJumpRoutePreview,
                value: sshProfileDraft.jumpProfileId.flatMap { id in
                    settingsStore.sshProfiles.first(where: { $0.id == id })?.displayName
                } ?? "直连",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    var sshKeyManagementSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "本机 SSH 密钥")

            AmberFormGroup {
                RuntimeActionRow(title: "生成新密钥（推荐）", color: AmberTheme.accent) {
                    generateSSHKey()
                }
                RuntimeDivider()
                RuntimeActionRow(
                    title: sshPrivateKeyDraft.isEmpty ? "复制公钥" : "保存并复制公钥",
                    color: AmberTheme.accent
                ) {
                    copySSHPublicKey()
                }
            }

            if !settingsStore.sshKeys.isEmpty {
                AmberSectionLabel(text: "已保存密钥")
                    .padding(.top, 10)
                AmberFormGroup {
                    ForEach(Array(settingsStore.sshKeys.enumerated()), id: \.element.id) { index, keyMeta in
                        sshSavedKeyRow(keyMeta)
                        if index < settingsStore.sshKeys.count - 1 {
                            RuntimeDivider()
                        }
                    }
                }
            }

            AmberSectionLabel(text: "导入已有私钥")
                .padding(.top, 10)
            AmberFormGroup {
                RuntimeSecureFieldRow(
                    title: "私钥",
                    text: Binding(
                        get: { sshPrivateKeyDraft },
                        set: { newValue in
                            sshPrivateKeyDraft = newValue
                            sshPublicKey = ""
                        }
                    ),
                    placeholder: "粘贴 OpenSSH / PEM 私钥或从文件导入"
                )
                RuntimeDivider()
                RuntimeSecureFieldRow(
                    title: "解密口令",
                    text: $sshPassphraseDraft,
                    placeholder: "无口令可留空（仅导入时解密，不落盘）"
                )
                RuntimeDivider()
                RuntimeActionRow(title: "从文件导入私钥", color: AmberTheme.accent) {
                    showsSSHKeyImporter = true
                }
                if !sshPrivateKeyDraft.isEmpty {
                    RuntimeDivider()
                    RuntimeActionRow(title: "导入并绑定到当前 Profile", color: AmberTheme.accent) {
                        saveSSHKeyDraft()
                    }
                }
            }

            AmberFormGroup {
                DisclosureGroup(isExpanded: $showsSSHPublicKey) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("生成算法", selection: $sshKeyGenerationType) {
                            ForEach(IOSSSHKeyType.allCases) { keyType in
                                Text(keyType.displayName).tag(keyType)
                            }
                        }
                        .pickerStyle(.menu)

                        Toggle("每次签名需生物识别 / 设备密码验证", isOn: $sshKeyRequireUserPresence)
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.foreground)

                        if !sshPublicKey.isEmpty {
                            Text(sshPublicKey)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AmberTheme.foreground2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    AmberTheme.surface2,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(AmberTheme.accent)
                        Text("高级选项与完整公钥")
                            .font(.body.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground)
                        Spacer()
                        Text(sshKeyGenerationType.displayName)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted2)
                    }
                    .frame(minHeight: 52)
                    .padding(.horizontal, 14)
                }
            }
            .padding(.top, 10)

            if case .success(let message) = sshStatus {
                Text(message).font(.footnote).foregroundStyle(AmberTheme.accentGreen)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else if case .failure(let message) = sshStatus {
                Text(message).font(.footnote).foregroundStyle(AmberTheme.accentRed)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }

            Text("私钥仅保存在此设备，设备解锁时可用，不随备份或同步导出。生成或导入后请复制公钥并添加到目标服务器的 ~/.ssh/authorized_keys。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 7)
        }
        .onAppear { showsSSHPublicKey = false }
        .onChange(of: showsSSHPublicKey) { _, expanded in
            if expanded, sshPublicKey.isEmpty {
                showSSHPublicKey()
            }
        }
    }

    @ViewBuilder
    private func sshSavedKeyRow(_ keyMeta: IOSSSHKeyMetadata) -> some View {
        let isSelected = sshProfileDraft.keyId == keyMeta.id
        HStack(spacing: 12) {
            Button {
                sshProfileDraft.keyId = keyMeta.id
                sshProfileDraft.authMethod = .privateKey
                sshPublicKey = keyMeta.publicKeyOpenSSH
                sshStatus = .success("已选择密钥「\(keyMeta.name)」，请保存 SSH Profile。")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "key.fill")
                        .foregroundStyle(isSelected ? AmberTheme.accentGreen : AmberTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(keyMeta.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground)
                        Text("\(keyMeta.algorithm) · \(keyMeta.fingerprintSHA256)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(AmberTheme.muted2)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                UIPasteboard.general.string = keyMeta.publicKeyOpenSSH
                sshPublicKey = keyMeta.publicKeyOpenSSH
                sshStatus = .success("已复制「\(keyMeta.name)」的公钥。")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制 \(keyMeta.name) 公钥")

            Button {
                deleteSavedSSHKey(keyMeta)
            } label: {
                Image(systemName: "trash")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除 \(keyMeta.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
