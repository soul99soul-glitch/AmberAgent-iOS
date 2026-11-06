import SwiftUI
import Shared
import XCTest
@testable import iosApp

@MainActor
final class ChatTimelineReviewRegressionTests: ChatNativeTimelineReplayTestCase {
    @MainActor
    private final class PacerMount: ObservableObject {
        @Published var identity = 0
        @Published var height: CGFloat = 600
        let growth = ChatTimelineGrowth()
    }

    private struct PacerFixture: View {
        @ObservedObject var mount: PacerMount

        var body: some View {
            ChatStreamingRevealPacer(text: "正在继续生成", isStreaming: true, reduceMotion: false) { _ in
                Color.clear.frame(width: 300, height: mount.height)
            }
            .id(mount.identity)
            .environment(\.chatTimelineGrowth, mount.growth)
        }
    }

    func testStreamingPacerRemountRecordsHeightWithoutReplayingExistingContentGrowth() throws {
        let mount = PacerMount()
        mount.growth.setEnabled(true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: PacerFixture(mount: mount))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        pump(seconds: 0.2)
        XCTAssertEqual(mount.growth.totalGrowth, 0, "首次挂载只建立高度基准")
        mount.height += 22
        pump(seconds: 0.2)
        XCTAssertEqual(mount.growth.totalGrowth, 22, "挂载后的真实新增行仍平滑生长")
        mount.identity += 1
        pump(seconds: 0.2)
        XCTAssertEqual(mount.growth.totalGrowth, 22, "流式中切回页面不能把整条已有回复当增量")
        mount.height += 22
        pump(seconds: 0.2)
        XCTAssertEqual(mount.growth.totalGrowth, 44, "重新挂载后继续计算真实增量")

        // 手指刚碰屏进入 .tracking 调用 setEnabled(false) 时不得无动画把 totalGrowth 清零导致瞬跳
        mount.growth.setEnabled(false)
        XCTAssertEqual(mount.growth.totalGrowth, 44, ".tracking 暂停新增生长时必须保留已提交高度基准，避免画面瞬跳")
        mount.growth.reset()
        XCTAssertEqual(mount.growth.totalGrowth, 0, "仅在视图销毁 reset 时清零")
    }

    func testFirstShortReplyDoesNotTranslateTimelineUntilContentBecomesScrollable() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        fixture.model.messages = [makeUserMessage("请继续回答")]
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        pump(seconds: 0.3)
        let id = KotlinUuid.companion.random()
        fixture.model.messages.append(makeAssistantMessage(id: id, text: "第一行", finished: false))
        fixture.model.send(.streamDelta)
        pump(seconds: 0.4)
        XCTAssertFalse(fixture.model.latestViewport.isContentScrollable)
        let scrollView = try XCTUnwrap(fixture.scrollView)
        let originalHeight = scrollView.contentSize.height
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        fixture.model.messages[1] = makeAssistantMessage(id: id, text: "第一行\n\n第二行\n\n第三行", finished: false)
        fixture.model.send(.streamDelta)
        pump(seconds: 0.5)
        XCTAssertGreaterThan(scrollView.contentSize.height, originalHeight)
        XCTAssertFalse(fixture.model.latestViewport.isContentScrollable)
        XCTAssertEqual(ChatRenderProbe.counts["growth-transform"]?["all"] ?? 0, 0,
                       "内容未满屏时换行不能推动整个列表")

        let longText = String(repeating: "继续生成的一行内容。\n\n", count: 60)
        fixture.model.messages[1] = makeAssistantMessage(id: id, text: longText, finished: false)
        fixture.model.send(.streamDelta)
        XCTAssertTrue(pumpUntil(timeout: 5) { fixture.model.latestViewport.isContentScrollable })
        ChatRenderProbe.reset()
        XCTAssertTrue(pumpUntil(timeout: 3) { (ChatRenderProbe.counts["growth-transform"]?["all"] ?? 0) > 0 },
                      "内容超过视口后仍需恢复平滑生长")
    }

    func testFrameDriverUses60HzOnlyForStreamingFollowAndRestores120HzForInteractions() throws {
        let driver = NativeTimelineScrollDriver()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        scrollView.contentSize = CGSize(width: 390, height: 1_400)
        scrollView.contentOffset.y = 600
        driver.attach(scrollView)
        defer { driver.invalidate() }
        driver.submit(.streamContentGrew())
        scrollView.contentSize.height += 100
        driver.handleLayoutMetricsChanged()
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 60)

        driver.handleKeyboardWillChangeFrame(duration: 0.25, curveRaw: 7)
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 120,
                       "已有 display link 也必须立即恢复键盘动画帧率")
        driver.handleKeyboardWillChangeFrame(duration: 0, curveRaw: 7)
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 60)

        driver.submit(.explicitBottom(source: .button, animated: true, keyboardToken: nil))
        scrollView.contentSize.height += 100
        driver.handleLayoutMetricsChanged()
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 120, "主动回底动画不能限到 60Hz")
        driver.submit(.generationTerminated)
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 120, "终态收敛也不属于流式降帧范围")
    }

    func testLiveTailSingleTokenAndChunkHeightGrowthLayoutMeasurements() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        let history = longConversation(turns: 6)
        let historicalIDs = Set(history.map { $0.id.toHexDashString() })
        fixture.model.messages = history + [makeUserMessage("继续搜索并整理回复")]
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        pump(seconds: 2.0)

        let id = KotlinUuid.companion.random()
        let liveID = id.toHexDashString()
        let seed = "## 连续正文\n\n" + String(repeating: "这是当前回复。", count: 5)
        fixture.model.messages.append(makeAssistantMessage(id: id, text: seed, finished: false))
        fixture.model.send(.streamDelta)
        pump(seconds: 2.0)

        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: id, text: seed + "续", finished: false
        )
        fixture.model.send(.streamDelta)
        pump(seconds: 0.3)
        ChatRenderProbe.enabled = false

        let singleTokenMeasures = ChatRenderProbe.counts["layout-measure"] ?? [:]
        let singleTokenHistorical = singleTokenMeasures.filter { historicalIDs.contains($0.key) }.values.reduce(0, +)
        let singleTokenCurrent = singleTokenMeasures[liveID] ?? 0
        print("[FANOUT-PROBE] single-token historical=\(singleTokenHistorical) current=\(singleTokenCurrent) all=\(singleTokenMeasures)")
        XCTAssertEqual(singleTokenHistorical, 0, "单字流式更新不得触发历史行重测")
        XCTAssertLessThanOrEqual(singleTokenCurrent, 3, "同行单字追加与淡入帧不得反复打穿当前行布局缓存")

        pump(seconds: 0.5)
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: id,
            text: seed + "续\n\n" + String(repeating: "换行后的连续回复。", count: 8),
            finished: false
        )
        fixture.model.send(.streamDelta)
        pump(seconds: 0.3)
        ChatRenderProbe.enabled = false

        let chunkMeasures = ChatRenderProbe.counts["layout-measure"] ?? [:]
        let chunkHistorical = chunkMeasures.filter { historicalIDs.contains($0.key) }.values.reduce(0, +)
        let chunkCurrent = chunkMeasures[liveID] ?? 0
        print("[FANOUT-PROBE] newline-chunk historical=\(chunkHistorical) current=\(chunkCurrent) all=\(chunkMeasures)")
        XCTAssertEqual(chunkHistorical, 0, "换行流式更新不得触发历史行重测")
    }
}
