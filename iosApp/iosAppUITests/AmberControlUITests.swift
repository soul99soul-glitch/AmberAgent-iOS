import XCTest

/// 设备遥控冒烟测试：在真机上拉起已安装的 Amber 主应用，
/// 截图存档并输出辅助功能树，作为外部操控通道的验证载体。
final class AmberControlUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchInstalledAmberAndSnapshot() throws {
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()

        // App 内嵌 KMP/Python 运行时，冷启动较慢。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if app.state == .runningForeground { break }
            sleep(1)
        }
        sleep(5)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "amber-launch"
        attachment.lifetime = .keepAlways
        add(attachment)

        print("AMBER_UI_TREE_BEGIN")
        print(app.debugDescription)
        print("AMBER_UI_TREE_END")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
