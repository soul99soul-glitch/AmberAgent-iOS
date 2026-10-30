import SwiftUI
import XCTest
@testable import iosApp

/// Production rows rendered with isolated data. Attachments require visual
/// review; these assertions establish capture dimensions, not layout quality.
@MainActor
final class IOSWakeVisualEvidenceTests: XCTestCase {
    func testWakeTaskRowsAtRegularNarrowAndAccessibilityWidths() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WakeVisualEvidence.\(UUID().uuidString)")
        let suite = "WakeVisualEvidence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = IOSWakeTaskStore(fileURL: directory.appendingPathComponent("tasks.json"), now: { date })
        try populate(store: store, at: date)
        let scheduler = IOSWakeScheduler(
            store: store, now: { date }, isForeground: { true }, systemSchedulingEnabled: false,
            startRun: { _, _ in
                XCTFail("Visual evidence must not start a provider run")
                return .failed("视觉测试不运行模型。")
            },
            submitSystem: { _ in XCTFail("Visual evidence must not submit a system task") }
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        for (name, width, typeSize) in [
            ("regular-402", CGFloat(402), DynamicTypeSize.large),
            ("narrow-320", CGFloat(320), DynamicTypeSize.large),
            ("accessibility3-402", CGFloat(402), DynamicTypeSize.accessibility3),
        ] {
            let size = CGSize(width: width, height: 852)
            let host = UIHostingController(rootView: ScrollView {
                IOSWakeTasksSection(scheduler: scheduler)
                    .padding(.bottom, 24)
            }
                .background(AmberTheme.background)
                .defaultAppStorage(defaults)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, typeSize)
                .preferredColorScheme(.light))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            XCTAssertEqual(window.bounds.width, width, accuracy: 1)

            let scroll = try XCTUnwrap(firstScrollView(in: host.view))
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let pageStride = max(1, scroll.bounds.height * 0.75)
            var offset = top
            var page = 1
            while true {
                scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                try await Task.sleep(for: .milliseconds(80))
                host.view.layoutIfNeeded()
                try capture(host.view, size: size, name: "wake-tasks-\(name)-page-\(String(format: "%02d", page))")
                if offset >= bottom { break }
                offset = min(bottom, offset + pageStride)
                page += 1
            }
            window.rootViewController = nil
            await Task.yield()
        }
    }

    private func populate(store: IOSWakeTaskStore, at date: Date) throws {
        let conversationID = UUID().uuidString
        let origin = IOSWakeOrigin(userMessageID: "visual-user", userText: "收到研究回复后继续整理，并保留原对话进度。")
        let waiting = try store.schedule(
            conversationID: conversationID, sourceRunID: "visual-source", origin: origin,
            title: "等待外部助手的研究结果，核对长篇材料、整理引用并在原对话交付完整报告，同时向用户展示下一步进度",
            prompt: "读取研究结果，整理报告并回写原对话。",
            fireAt: date.addingTimeInterval(600),
            event: "grok.research.completed.\(String(repeating: "跨平台助手协作与资料整理", count: 8)).original-conversation-results-ready",
            requiresForeground: true, requestID: "visual-waiting"
        )
        try store.noteWaiting(
            id: waiting.id,
            reason: "任务已保存，等待可用的前台执行机会。手机解锁并打开 Amber 后继续；计划时间不代表已经执行，也不会把结果写入其他对话。"
        )
        for (suffix, title, status, message) in [
            ("failed", "读取助手回复失败，等待用户检查连接后重试", IOSWakeTask.Status.failed,
             "本次连接未完成，已保留原始任务和对话。请检查实际网络状态，重试不会覆盖当前正在查看的其他对话。"),
            ("interrupted", "整理过程被系统中断，已保存当前执行状态", IOSWakeTask.Status.interrupted,
             "上次运行没有完成回执，当前不会自动重放可能已经发生的操作。查看原对话后可决定重试。"),
            ("completed", "研究报告已经整理完成并写回原对话", IOSWakeTask.Status.completed,
             "已完成资料汇总和引用整理。打开原对话查看完整报告。"),
        ] {
            let task = try store.schedule(
                conversationID: conversationID, sourceRunID: "visual-source", origin: origin,
                title: title, prompt: "整理已经授权的研究资料。", fireAt: date,
                event: nil, requiresForeground: false, requestID: "visual-\(suffix)"
            )
            let runID = "visual-\(suffix)-run"
            _ = try store.claim(id: task.id, runID: runID)
            _ = try store.finish(runID: runID, status: status, message: message)
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    private func capture(_ view: UIView, size: CGSize, name: String) throws {
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
