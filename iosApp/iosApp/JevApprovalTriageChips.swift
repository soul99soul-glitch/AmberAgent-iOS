import SwiftUI

/// 增强 Phase E：审批分诊标签行（Jev approval triage chips）。
///
/// 三个中性事实胶囊（只读/可逆/与任务相关：是·否·未知），等宽排布在审批卡
/// 上方。红线：只标注，永不自动批准/拒绝；措辞中性，不出现"安全/低风险"等
/// 诱导词；三态同色同形，不用红绿暗示判断。标注缺失时本视图不渲染（审批卡
/// 与原样完全一致）。
struct JevApprovalTriageChips: View {
    let triage: IOSJevApprovalTriage

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // 辅助功能大字号下单行必然溢出窄容器：改为垂直堆叠（与设置页
        // apiSection 同款处理）；常规尺寸保持单行。
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                chip(title: "只读", state: triage.readonly)
                chip(title: "可逆", state: triage.reversible)
                chip(title: "与任务相关", state: triage.goalAligned)
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("审批分诊")
        } else {
            HStack(spacing: 8) {
                chip(title: "只读", state: triage.readonly)
                chip(title: "可逆", state: triage.reversible)
                chip(title: "与任务相关", state: triage.goalAligned)
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("审批分诊")
        }
    }

    private func chip(title: String, state: IOSJevApprovalTriage.TriState) -> some View {
        HStack(spacing: 0) {
            Text(title + "：")
                .foregroundStyle(AmberTheme.muted)
            Text(stateText(state))
                .foregroundStyle(AmberTheme.foreground2)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AmberTheme.foreground2.opacity(0.08), in: Capsule())
    }

    private func stateText(_ state: IOSJevApprovalTriage.TriState) -> String {
        switch state {
        case .yes: "是"
        case .no: "否"
        case .unknown: "未知"
        }
    }
}
