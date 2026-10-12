import SwiftUI
import XCTest
import Vision
@testable import iosApp

@MainActor
final class IOSIntelligentUIStudyVisualTests: XCTestCase {
    func testInlineStudyFitsCompactDarkAndAccessibilityWithFeedback() async throws {
        let definition = try studyCard()
        let study = try XCTUnwrap(definition.study)
        var revealed = IOSIntelligentUIStudySession()
        try revealed.reveal(definition: study)
        var quiz = IOSIntelligentUIStudySession()
        try quiz.setMode(.quiz, definition: study)
        try quiz.answer(optionID: "yongle", definition: study)
        for (name, session, textSize, dark) in [
            ("review", IOSIntelligentUIStudySession(), DynamicTypeSize.large, false),
            ("revealed", revealed, DynamicTypeSize.large, false),
            ("quiz-feedback", quiz, DynamicTypeSize.large, false),
            ("dark", quiz, DynamicTypeSize.large, true),
            ("accessibility", quiz, DynamicTypeSize.accessibility3, false)
        ] {
            let raw = try session.encodedValue()
            let card = IOSIntelligentUICard(definition: definition, selectedOptionID: .constant(nil),
                                           values: .constant([IOSIntelligentUIStudySession.storageKey: raw]),
                                           isSubmitEnabled: true)
                .padding(12).frame(width: 320)
                .background(AmberTheme.background)
                .environment(\.dynamicTypeSize, textSize)
                .environment(\.colorScheme, dark ? .dark : .light)
                .ignoresSafeArea()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: card)
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 5_000)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(150))
            let fit = host.sizeThatFits(in: CGSize(width: 320, height: 5_000))
            XCTAssertLessThanOrEqual(fit.width, 321)
            XCTAssertGreaterThan(fit.height, 300)
            window.frame.size.height = fit.height
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            let attachment = XCTAttachment(image: image)
            attachment.name = "task-ui-study-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("task-ui-study-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: file)
            print("TASK_UI_VISUAL_EVIDENCE \(file.path)")
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            XCTAssertTrue(visible.contains("明朝十六帝"))
            XCTAssertTrue(visible.contains("朱元璋"))
            XCTAssertFalse(visible.contains("Live"))
            if session.mode == .quiz { XCTAssertTrue(visible.contains("再记一下")) }
        }
    }

    // Native study actions and their original draft/receipt assertions run in
    // IOSIntelligentUIComponentAXAcceptanceTests using the system UI automation tree.

    private func studyCard() throws -> IOSIntelligentUICardDefinition {
        try IOSIntelligentUIProtocol.decode(#"""
        {"version":1,"card_id":"ming-study","kind":"study","goal":"明朝十六帝 · 互动记忆卡","question":"","options":[],
         "study":{"items":[
           {"id":"hongwu","prompt":"朱元璋的年号是什么？","answer":"洪武。朱元璋建立明朝，口诀从「洪」起。","detail":"洪建永洪宣，正景天成；弘正嘉隆，万泰天崇。",
            "options":[{"id":"hongwu","label":"洪武"},{"id":"yongle","label":"永乐"}],"correct_option_id":"hongwu"},
           {"id":"yingzong","prompt":"明英宗朱祁镇用了哪两个年号？","answer":"正统与天顺，同一位皇帝两次在位。",
            "options":[{"id":"two-reigns","label":"正统与天顺"},{"id":"wrong","label":"洪武与建文"}],"correct_option_id":"two-reigns"}]},
         "components":[{"id":"reset","kind":"resetButton","title":"清空学习卡"}],
         "submit":{"label":"针对错题继续练习","intent":"continue"}}
        """#)
    }
}
