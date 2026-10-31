import XCTest
@testable import iosApp

/// 竖条启用条件：高度必须按实际按钮数计算，低于内容高度时整条让位，
/// 不能只判断能放下两个按钮。
final class AmberSideRailLayoutTests: XCTestCase {

    func testRequiredHeightCountsEveryButtonAndTheMiddleSpacer() {
        // Home 外屏：搜索 / 设置 / 账户 + 底部新对话。
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 3, bottomCount: 1), 218)
        // Chat 外屏：返回 / 新对话，无底部动作。
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 2, bottomCount: 0), 116)
        // 生成中的 Chat 外屏：返回 / 新对话 + 停止。
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 2, bottomCount: 1), 160)
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 0, bottomCount: 1), 58)
    }

    func testEmptyRailRequiresNoHeight() {
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 0, bottomCount: 0), 0)
    }

    func testMinimumRailWidthFitsADiameterWithBreathingRoom() {
        XCTAssertGreaterThanOrEqual(
            AmberSideRailMetrics.minimumRailWidth,
            AmberSideRailMetrics.buttonDiameter + 16
        )
    }

    func testEmptyRailIsInactiveEvenWithRoom() {
        XCTAssertFalse(AmberSideRailMetrics.isActive(topCount: 0, bottomCount: 0, availableHeight: 1_000))
    }

    func testActivationRequiresTheFullReservedHeight() {
        XCTAssertFalse(AmberSideRailMetrics.isActive(topCount: 3, bottomCount: 1, availableHeight: 217.9))
        XCTAssertTrue(AmberSideRailMetrics.isActive(topCount: 3, bottomCount: 1, availableHeight: 218))
    }

    /// 底部按钮随滚动出现/消失时，启用阈值不能跟着变，否则整条（含返回键）会闪烁。
    func testScrollToBottomAppearingDoesNotChangeActivation() {
        for height in stride(from: 100.0, through: 220.0, by: 2) {
            XCTAssertEqual(
                AmberSideRailMetrics.isActive(topCount: 2, bottomCount: 0, availableHeight: height),
                AmberSideRailMetrics.isActive(topCount: 2, bottomCount: 1, availableHeight: height),
                "height \(height)"
            )
        }
    }
}
