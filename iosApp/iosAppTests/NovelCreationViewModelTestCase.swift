import XCTest
@testable import iosApp

@MainActor
class NovelCreationViewModelTestCase: XCTestCase {
    var quickStartSuggestionsJSON: String {
        """
        {
          "schemaVersion": 1,
          "overview": "一列以记忆为票价的列车穿行雾海。",
          "world": {
            "title": "雾海列车规则",
            "content": "列车不能在同一座车站停靠两次。"
          },
          "characters": {
            "title": "失忆乘客",
            "content": "主角用逐渐消失的记忆追查列车终点。"
          },
          "masterOutline": {
            "title": "三段旅程",
            "content": "登车、发现代价、选择保留最后一段记忆。"
          },
          "writingRequirements": {
            "title": "悬疑节奏",
            "content": "每章揭示一条规则，并保留一个可回收线索。"
          }
        }
        """
    }

    func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
