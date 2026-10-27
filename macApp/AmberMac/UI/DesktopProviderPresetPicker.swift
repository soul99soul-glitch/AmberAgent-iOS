import SwiftUI

/// Add-provider step one: pick a vendor (and, for vendors that sell one, its coding plan). The form then needs only a key.
struct DesktopProviderPresetPicker: View {
    let onPick: (DesktopProviderPreset, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hovered: String?

    private var groups: [(DesktopProviderPreset.Group, [DesktopProviderPreset])] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let presets = DesktopProviderPreset.all.filter {
            text.isEmpty || $0.name.lowercased().contains(text) || $0.summary.lowercased().contains(text) || $0.id.contains(text)
        }
        return DesktopProviderPreset.Group.allCases.compactMap { group in
            let items = presets.filter { $0.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("添加服务商").font(DesktopTheme.serif(size: 22, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
                    Text("选择服务商，填入 API Key 后即可获取模型。有编程套餐的服务商可直接选套餐。")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 16)
            TextField("搜索服务商", text: $query).textFieldStyle(.desktop).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups, id: \.0) { group, items in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(DesktopTheme.inkTertiary)
                            VStack(spacing: 6) { ForEach(items) { card($0) } }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(24)
        .frame(width: 620, height: 600)
        .background(DesktopTheme.paper)
    }

    private func card(_ preset: DesktopProviderPreset) -> some View {
        let isHovered = hovered == preset.id
        return HStack(spacing: 12) {
            Text(preset.monogram)
                .font(DesktopTheme.serif(size: 15, weight: .semibold))
                .foregroundStyle(DesktopTheme.accentInk)
                .frame(width: 30, height: 30)
                .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.honeyEdge, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.system(size: 14, weight: .medium)).foregroundStyle(DesktopTheme.ink).lineLimit(1)
                Text(preset.summary).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 12)
            // Only vendors that sell a plan need a choice; others add on click.
            if preset.plan != nil {
                pill("按量 API") { onPick(preset, false) }
                pill(preset.planTitle, prominent: true) { onPick(preset, true) }
            } else {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesktopTheme.inkTertiary).opacity(isHovered ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isHovered ? DesktopTheme.honeyEdge : DesktopTheme.hairline))
        .shadow(color: .black.opacity(isHovered ? 0.05 : 0), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovered = $0 ? preset.id : (hovered == preset.id ? nil : hovered) }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onPick(preset, false) }
    }

    private func pill(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: prominent ? .medium : .regular))
                .foregroundStyle(prominent ? DesktopTheme.accentInk : DesktopTheme.inkSecondary)
                .padding(.horizontal, 10).frame(height: 24)
                .background {
                    if prominent { DesktopTheme.glow(RoundedRectangle(cornerRadius: 6)) }
                    else { RoundedRectangle(cornerRadius: 6).fill(DesktopTheme.paperDeep) }
                }
        }
        .buttonStyle(DesktopPressButtonStyle())
    }
}
