import SwiftUI

@MainActor
struct IOSSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var store: IOSStoreCoordinator
    private let policyLinks: IOSStorePolicyLinks

    init(
        store: IOSStoreCoordinator? = nil,
        policyLinks: IOSStorePolicyLinks = .configured()
    ) {
        self._store = State(initialValue: store ?? IOSStoreCoordinator())
        self.policyLinks = policyLinks
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        entitlementSection
                        productsSection
                        restoreSection
                        policySection
                        policyLinksSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer()
            VStack(spacing: 2) {
                Text("Amber Pro")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                Text("StoreKit 2 订阅")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var entitlementSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "订阅状态")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Label(entitlementTitle, systemImage: entitlementIcon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(entitlementColor)
                    Text(entitlementDetail)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.entitlement.isFromCache {
                        Label("离线缓存 · \(formatDate(store.entitlement.checkedAt))", systemImage: "internaldrive")
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.accentAmber)
                    }
                    if let message = store.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("订阅提示：\(message)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private var productsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "选择方案")
            AmberFormGroup {
                if store.products.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        if store.operation == .loading {
                            HStack(spacing: 10) {
                                ProgressView().tint(AmberTheme.accent)
                                Text("正在读取 App Store 产品…")
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.muted)
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            Text("暂未读取到可购买方案。")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                            Button {
                                Task { await store.refresh() }
                            } label: {
                                Label("重新加载", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                } else {
                    ForEach(Array(store.products.enumerated()), id: \.element.id) { index, product in
                        productRow(product)
                        if index < store.products.count - 1 {
                            Divider().overlay(AmberTheme.borderSoft).padding(.leading, 14)
                        }
                    }
                }
            }
            Text("价格、币种和税费以 App Store 购买确认页为准。订阅会自动续期，可随时在 Apple 账户中取消。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)
            if !policyLinks.allowsPurchases {
                Text("购买暂未开放：隐私政策或使用条款尚未配置为可访问的 HTTPS 地址。恢复购买仍可使用。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .accessibilityLabel("购买暂未开放。隐私政策或使用条款尚未配置为可访问的 HTTPS 地址。恢复购买仍可使用。")
            }
        }
    }

    private func productRow(_ product: IOSStoreProductDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        productIdentity(product)
                        productPrice(product)
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        productIdentity(product)
                        productPrice(product)
                    }
                }
            }

            Button {
                Task { await store.purchase(productID: product.id) }
            } label: {
                if store.operation == .purchasing(productID: product.id) {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("正在购买…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("订阅 \(product.displayName)")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AmberTheme.accent)
            .disabled(store.operation != .idle || !policyLinks.allowsPurchases)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func productIdentity(_ product: IOSStoreProductDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(product.displayName)
                .font(.body.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
            Text(product.description)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func productPrice(_ product: IOSStoreProductDisplay) -> some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            Text(product.displayPrice)
                .font(.body.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
            if !product.periodLabel.isEmpty {
                Text(product.periodLabel)
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var restoreSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "购买记录")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("恢复购买会显示 Apple 的账户确认，并从 App Store 同步交易与订阅状态。无需绑定 Amber 账户。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await store.restore() }
                    } label: {
                        Label(store.operation == .restoring ? "正在恢复…" : "恢复购买", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.operation != .idle)
                    .frame(minHeight: 44)

                    Button("管理 Apple 订阅") {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AmberTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private var policySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "访问边界")
            AmberFormGroup {
                Text("Amber Pro 当前解锁 iCloud 私有数据库中的加密跨设备备份。本地备份、本机文件夹与 WebDAV 同步、本地对话、HealthKit 摘要和恢复购买不会被订阅锁定，Apple 登录也不是购买前置条件。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            }
        }
    }

    private var policyLinksSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "条款与隐私")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 10) {
                    if let privacyPolicyURL = policyLinks.publicPrivacyPolicyURL {
                        Link(destination: privacyPolicyURL) {
                            Label("隐私政策", systemImage: "hand.raised")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    } else {
                        Text("隐私政策尚未配置为可访问的 HTTPS 地址，因此购买保持关闭。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.accentAmber)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let termsOfUseURL = policyLinks.publicTermsOfUseURL {
                        Link(destination: termsOfUseURL) {
                            Label("使用条款", systemImage: "doc.text")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    } else {
                        Text("使用条款尚未配置为可访问的 HTTPS 地址，因此购买保持关闭。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.accentAmber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private var entitlementTitle: String {
        switch store.entitlement.state {
        case .none: "未订阅"
        case .active: "订阅有效"
        case .gracePeriod: "账单宽限期"
        case .billingRetry: "账单重试中"
        case .expired: "订阅已过期"
        case .revoked: "订阅已撤销"
        }
    }

    private var entitlementIcon: String {
        switch store.entitlement.state {
        case .active: "checkmark.seal.fill"
        case .gracePeriod: "clock.badge.checkmark"
        case .billingRetry: "creditcard.trianglebadge.exclamationmark"
        case .expired: "calendar.badge.exclamationmark"
        case .revoked: "xmark.seal"
        case .none: "circle.dashed"
        }
    }

    private var entitlementColor: Color {
        switch store.entitlement.state {
        case .active: AmberTheme.accentGreen
        case .gracePeriod, .billingRetry: AmberTheme.accentAmber
        case .expired, .revoked: AmberTheme.accentRed
        case .none: AmberTheme.foreground
        }
    }

    private var entitlementDetail: String {
        switch store.entitlement.state {
        case .none:
            "没有发现有效的 Amber Pro 订阅。"
        case .active(let productID, let expirationDate):
            subscriptionDetail(productID: productID, date: expirationDate, prefix: "当前方案有效")
        case .gracePeriod(let productID, let expirationDate):
            subscriptionDetail(productID: productID, date: expirationDate, prefix: "Apple 正在处理付款问题，宽限期内仍保留 Pro 权益")
        case .billingRetry(let productID, let expirationDate):
            subscriptionDetail(productID: productID, date: expirationDate, prefix: "Apple 正在重试付款，请检查支付方式")
        case .expired(let productID, let expirationDate):
            subscriptionDetail(productID: productID, date: expirationDate, prefix: "当前方案已结束")
        case .revoked(let productID, let revocationDate):
            subscriptionDetail(productID: productID, date: revocationDate, prefix: "App Store 已撤销这项订阅")
        }
    }

    private func subscriptionDetail(productID: String, date: Date?, prefix: String) -> String {
        let productName = store.products.first(where: { $0.id == productID })?.displayName ?? productID
        guard let date else { return "\(prefix) · \(productName)" }
        return "\(prefix) · \(productName) · \(formatDate(date))"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
