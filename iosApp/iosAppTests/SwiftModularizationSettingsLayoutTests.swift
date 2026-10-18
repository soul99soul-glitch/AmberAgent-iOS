import SwiftUI
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Scene-backed geometry probes; PNGs are retained for separate visual review.
@MainActor
final class SwiftModularizationSettingsLayoutTests: XCTestCase {
    private let height: CGFloat = 760

    private var cases: [(width: CGFloat, type: DynamicTypeSize)] {
        [(320, .large), (393, .large), (320, .accessibility3), (393, .accessibility3)]
    }

    func testProviderConfigurationAndModelRowsFitPhoneViewports() async throws {
        let context = try makeProviderContext()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }

        for (width, type) in cases {
            for showsModels in [false, true] {
                let fixture = try SwiftModularizationHostingFixture(
                    root: NavigationStack {
                        ProviderDetailView(settingsStore: context.legacy, providerRegistry: context.registry,
                                           sharedSettings: context.shared, providerId: context.providerID,
                                           initiallyShowsModels: showsModels)
                    }.defaultAppStorage(context.defaults),
                    width: width, height: height, type: type
                )
                defer { fixture.close() }
                try await fixture.settle()
                let scroll = try XCTUnwrap(fixture.mainScrollView())
                fixture.assertNoHorizontalOverflow(scroll)
                let page = showsModels ? "models" : "config"
                let name = "settings-provider-\(page)-\(suffix(width, type))"
                if !showsModels {
                    let field = try XCTUnwrap(inputViews(in: fixture).first,
                                              "Provider configuration must mount an editable field")
                    assertReachable(field, in: scroll, fixture: fixture)
                }
                try fixture.capturePNG(name, in: self)

                fixture.scrollToBottom(scroll)
                try await fixture.settle()
                fixture.assertNoHorizontalOverflow(scroll)
                XCTAssertGreaterThan(scroll.contentOffset.y, 0,
                                     "The \(page) page must have reachable lower controls")
                if type == .accessibility3 && showsModels {
                    try fixture.capturePNG("\(name)-bottom", in: self)
                }
            }
        }
    }

    func testProviderModelEditorFieldsFitAndRemainReachable() async throws {
        var draft = ProviderModelDraft()
        draft.modelId = "gpt-6-astra-with-a-deliberately-long-model-identifier"
        draft.displayName = "自定义推理模型 · 带有较长显示名称和说明"
        draft.contextWindowText = "262144"
        draft.headers = (1...3).map { index in
            ProviderHeaderDraft(name: "X-Review-Header-\(index)", value: "value-\(index)")
        }

        for (width, type) in cases {
            let fixture = try SwiftModularizationHostingFixture(
                root: ProviderModelEditorSheet(draft: draft, onSave: { _ in false }),
                width: width, height: height, type: type
            )
            defer { fixture.close() }
            try await fixture.settle()
            let scroll = try XCTUnwrap(fixture.mainScrollView())
            fixture.assertNoHorizontalOverflow(scroll)
            let field = try XCTUnwrap(inputViews(in: fixture).first,
                                      "Model editor must mount its real input fields")
            assertReachable(field, in: scroll, fixture: fixture)
            let name = "settings-provider-editor-\(suffix(width, type))"
            try fixture.capturePNG(name, in: self)

            fixture.scrollToBottom(scroll)
            try await fixture.settle()
            fixture.assertNoHorizontalOverflow(scroll)
            XCTAssertGreaterThan(scroll.contentOffset.y, 0,
                                 "Model editor lower fields must be scrollable")
            if type == .accessibility3 {
                let lowerField = try XCTUnwrap(inputViews(in: fixture).last)
                assertReachable(lowerField, in: scroll, fixture: fixture)
                try fixture.capturePNG("\(name)-bottom", in: self)
            }
        }
    }

    func testRuntimeOverviewAndPendingFingerprintFitPhoneViewports() async throws {
        let suite = "RuntimeLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = SettingsStore(userDefaults: defaults, apiKeyStore: EmptyKeyStore())
        let shared = IOSSharedSettingsStore(userDefaults: defaults)
        let permissions = IOSPermissionStore(userDefaults: defaults, taskStore: nil)

        for (width, type) in cases {
            let fixture = try SwiftModularizationHostingFixture(
                root: NavigationStack {
                    RuntimeEnvironmentView(settingsStore: legacy, sharedSettings: shared,
                                           permissionStore: permissions)
                }.defaultAppStorage(defaults),
                width: width, height: height, type: type
            )
            defer { fixture.close() }
            try await fixture.settle()
            let scroll = try XCTUnwrap(fixture.mainScrollView())
            fixture.assertNoHorizontalOverflow(scroll)
            try fixture.capturePNG("settings-runtime-overview-\(suffix(width, type))", in: self)
            fixture.scrollToBottom(scroll)
            try await fixture.settle()
            fixture.assertNoHorizontalOverflow(scroll)
        }

        let fingerprint = "SHA256:yx8UGq7bZ4I6N5bOjQ0Y5Qn3QqA3nVvVJHktPG6C5a8"
        for (width, type) in cases {
            let fixture = try SwiftModularizationHostingFixture(
                root: ScrollView {
                    HostFingerprintCard(status: .needsTrust(profileId: "layout-profile",
                                                           fingerprint: fingerprint),
                                        onTrust: {}, onCancel: {})
                        .padding(.top, 20)
                }, width: width, height: height, type: type
            )
            defer { fixture.close() }
            try await fixture.settle()
            let scroll = try XCTUnwrap(fixture.mainScrollView())
            fixture.assertNoHorizontalOverflow(scroll)
            let name = "settings-host-fingerprint-\(suffix(width, type))"
            try fixture.capturePNG(name, in: self)
            if type == .accessibility3 {
                fixture.scrollToBottom(scroll)
                try await fixture.settle()
                fixture.assertNoHorizontalOverflow(scroll)
                // The adjusted bottom inset is outside the visible content viewport.
                let visibleContentEnd = scroll.contentOffset.y + scroll.bounds.height
                    - scroll.adjustedContentInset.bottom
                XCTAssertGreaterThanOrEqual(visibleContentEnd, scroll.contentSize.height - 1,
                                            "The fingerprint card's lower actions must be scroll-reachable")
                try fixture.capturePNG("\(name)-bottom", in: self)
            }
        }
    }

    private func assertReachable(_ field: UIView, in scroll: UIScrollView,
                                 fixture: SwiftModularizationHostingFixture,
                                 file: StaticString = #filePath, line: UInt = #line) {
        fixture.scroll(scroll, to: field)
        let frame = field.convert(field.bounds, to: nil)
        let visible = fixture.visibleBounds(of: scroll)
        XCTAssertTrue(frame.intersects(visible), "Input must be reachable after scrolling",
                      file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, fixture.windowBounds.minX - 1,
                                    "Input clips at the left edge", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, fixture.windowBounds.maxX + 1,
                                 "Input clips at the right edge", file: file, line: line)
    }

    private func inputViews(in fixture: SwiftModularizationHostingFixture) -> [UIView] {
        (fixture.textFields().map { $0 as UIView } + fixture.textViews().map { $0 as UIView })
            .filter { !$0.isHidden && $0.bounds.width > 0 }
            .sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }

    private func suffix(_ width: CGFloat, _ type: DynamicTypeSize) -> String {
        "\(Int(width))-\(type == .accessibility3 ? "ax3" : "normal")"
    }

    private func makeProviderContext() throws -> ProviderContext {
        let suite = "ProviderLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let shared = IOSSharedSettingsStore(userDefaults: defaults)
        let legacy = SettingsStore(userDefaults: defaults, apiKeyStore: EmptyKeyStore())
        let registry = ProviderRegistryStore(settingsStore: legacy, userDefaults: defaults,
                                             keyNamespace: suite, keychainPrefix: suite)
        let provider = shared.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Provider Review · 自定义 OpenAI 兼容服务商与较长名称",
            apiKey: "", baseUrl: "https://gateway.example.test/region/team/openai/v1",
            modelName: "GPT-6-Astra · 自定义推理模型", modelId: "gpt-6-astra"))
        let providerID = provider.id.description()
        _ = shared.upsertProviderImageModel(providerId: providerID,
            modelId: "gpt-image-2.5-sunburst", displayName: "GPT Image 2.5 Sunburst")
        _ = shared.upsertProviderChatModel(providerId: providerID, modelUuid: nil,
            modelId: "text-embedding-3-small", displayName: "Embedding Model",
            contextWindowTokens: nil, modelType: .embedding, headers: [])
        for index in 1...10 {
            _ = shared.upsertProviderChatModel(providerId: providerID, modelUuid: nil,
                modelId: "review-chat-\(index)", displayName: "Long Review Chat Model \(index)",
                contextWindowTokens: nil, modelType: .chat, headers: [])
        }
        return ProviderContext(suite: suite, defaults: defaults, legacy: legacy,
                               registry: registry, shared: shared, providerID: providerID)
    }
}

@MainActor
private struct ProviderContext {
    let suite: String
    let defaults: UserDefaults
    let legacy: SettingsStore
    let registry: ProviderRegistryStore
    let shared: IOSSharedSettingsStore
    let providerID: String
}

private struct EmptyKeyStore: SettingsAPIKeyStore {
    func loadApiKey() -> String? { nil }
    func saveApiKey(_ key: String) -> Bool { true }
}
