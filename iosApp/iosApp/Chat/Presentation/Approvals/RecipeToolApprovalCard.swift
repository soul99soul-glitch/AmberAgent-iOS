import SwiftUI

// MARK: - Wave B2: Recipe 审批卡（mutation step / recipe_import）

/// 复用现有审批卡的视觉结构（amberGlass + 图标 + 摘要块 + 拒绝/批准胶囊），
/// 展示 recipe 专属内容：step 卡显示步骤/工具/参数与 effect class；import 卡
/// 显示 manifest 摘要、权限包络、base/candidate 短哈希、步骤列表（长列表进
/// 可滚动区，§14.2）与「批准后从下一模型轮生效」文案。
struct RecipeToolApprovalCard: View {
    let request: RecipeToolApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void
    @State private var showsFullRecipeSteps = false
    @State private var showsCapabilityScopes = false
    @State private var showsFileHashes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentAmber)
                    .frame(width: 30, height: 30)
                    .background(AmberTheme.accentAmber.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)

                    Text(request.reason)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(request.recipeName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(2)
                Text("v\(request.recipeVersion)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch request.payload {
            case .step(let payload):
                recipeStepPayload(payload)
            case .pluginInvocation(let payload):
                pluginInvocationPayload(payload)
            case .recipeImport(let payload):
                recipeImportPayload(payload)
            }

            HStack(spacing: 8) {
                Spacer()

                Button(action: onDeny) {
                    Label("拒绝", systemImage: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AmberTheme.surface2.opacity(0.86), in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel("拒绝工作流操作")

                Button(action: onApprove) {
                    Label("批准", systemImage: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(AmberTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .chatApprovalHitTarget()
                .accessibilityLabel("批准工作流操作")
            }
        }
        .padding(12)
        .amberGlass(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accentAmber.opacity(0.34), lineWidth: 0.7)
        }
    }

    private func recipeStepPayload(_ payload: RecipeStepApprovalPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("步骤 \(payload.stepId)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(effectClassTitle(payload.effectClass))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(payload.effectClass == .sideEffect ? AmberTheme.accentAmber : AmberTheme.accentGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (payload.effectClass == .sideEffect ? AmberTheme.accentAmber : AmberTheme.accentGreen).opacity(0.12),
                        in: Capsule()
                    )
            }

            Text("工具：\(payload.tool)")
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(AmberTheme.muted)
                .textSelection(.enabled)
                .lineLimit(2)

            Text(payload.argumentsPreview.isEmpty ? "（无参数）" : payload.argumentsPreview)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func pluginInvocationPayload(_ payload: PluginInvocationApprovalPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(payload.toolId)
                    .font(.footnote.monospaced().weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(effectClassTitle(payload.effectClass))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(payload.effectClass == .sideEffect ? AmberTheme.accentAmber : AmberTheme.accentGreen)
            }
            Text(payload.handler)
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted)
            if !payload.capabilities.isEmpty {
                Text(payload.capabilities.joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(payload.argumentsPreview.isEmpty ? "（无参数）" : payload.argumentsPreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func recipeImportPayload(_ payload: RecipeImportApprovalPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(payload.artifactKindTitle) \(payload.displayName ?? request.recipeName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(payload.mutationKind == .new ? "新建" : "更新")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(payload.mutationKind == .new ? AmberTheme.accentGreen : AmberTheme.accentAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (payload.mutationKind == .new ? AmberTheme.accentGreen : AmberTheme.accentAmber).opacity(0.12),
                        in: Capsule()
                    )
            }

            if payload.displayName != nil {
                Text(request.recipeName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AmberTheme.muted)
                    .textSelection(.enabled)
            }

            Text(payload.description)
                .font(.caption)
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let trustSummary = payload.trustSummary {
                Label(
                    trustSummary,
                    systemImage: trustSummary.contains("未签名")
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.seal.fill"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(trustSummary.contains("未签名")
                    ? AmberTheme.accentAmber : AmberTheme.accentGreen)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }

            Label(localizedPermissionSummary(payload), systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(payload.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue
                    ? AmberTheme.accentAmber : AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("包哈希  \(shortHash(payload.baseHash) ?? "无") → \(shortHash(payload.candidateHash) ?? payload.candidateHash)")
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(AmberTheme.muted)
                .textSelection(.enabled)

            if !payload.inputsSummary.isEmpty {
                Text("输入：\(payload.inputsSummary)")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !payload.stepsSummary.isEmpty {
                DisclosureGroup(isExpanded: $showsFullRecipeSteps) {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(payload.stepsSummary.enumerated()), id: \.offset) { index, row in
                                Text("\(index + 1). \(row)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(AmberTheme.foreground2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: 180)
                } label: {
                    Label(payload.artifactKindTitle == "插件"
                        ? "工具列表（\(payload.stepsSummary.count) 个）"
                        : "步骤列表（\(payload.stepsSummary.count) 步）", systemImage: "list.number")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentCyan)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .tint(AmberTheme.accentCyan)
            }

            if !payload.capabilityScopes.isEmpty {
                DisclosureGroup(isExpanded: $showsCapabilityScopes) {
                    payloadRows(payload.capabilityScopes)
                } label: {
                    Label("能力范围（\(payload.capabilityScopes.count) 项）", systemImage: "lock.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentCyan)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .tint(AmberTheme.accentCyan)
            }

            if !payload.fileHashes.isEmpty {
                DisclosureGroup(isExpanded: $showsFileHashes) {
                    payloadRows(payload.fileHashes)
                } label: {
                    Label("文件哈希（\(payload.fileHashes.count) 个）", systemImage: "number")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentCyan)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .tint(AmberTheme.accentCyan)
            }

            if !payload.outputsSummary.isEmpty {
                Text("\(payload.artifactKindTitle == "插件" ? "状态" : "输出")：\(payload.outputsSummary)")
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(payload.activationNotice, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(payload.activationNotice.contains("保持停用")
                    ? AmberTheme.accentAmber : AmberTheme.accentGreen)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func payloadRows(_ rows: [String]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: 180)
    }

    private func localizedPermissionSummary(_ payload: RecipeImportApprovalPayload) -> String {
        switch payload.effectClassRawValue {
        case IOSToolEffectClass.pure.rawValue: "只读，不产生副作用"
        case IOSToolEffectClass.networkRead.rawValue: "只读网络访问"
        case IOSToolEffectClass.idempotent.rawValue: "可重复执行的本地更改"
        case IOSToolEffectClass.sideEffect.rawValue: "可能更改状态，需要批准"
        default: payload.permissionSummary
        }
    }

    private func effectClassTitle(_ effectClass: IOSToolEffectClass) -> String {
        switch effectClass {
        case .pure: "只读"
        case .networkRead: "只读网络"
        case .idempotent: "幂等"
        case .sideEffect: "有副作用"
        }
    }

    private func shortHash(_ hash: String?) -> String? {
        guard let hash, !hash.isEmpty else { return nil }
        return String(hash.prefix(10))
    }
}
