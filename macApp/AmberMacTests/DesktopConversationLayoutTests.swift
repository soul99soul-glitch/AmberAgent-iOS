import AppKit
import SwiftUI
import XCTest
@testable import AmberMac

/// Window-level layout checks: they need the SwiftUI view tree and AppKit hosting, so they run in the
/// Xcode test target instead of the platform-independent runtime harness.
final class DesktopConversationLayoutTests: XCTestCase {
    @MainActor func testTranscriptContentWidthClampsSidebarToggleAndRowHeightsPreserveOffWindowFallback() {
        // At default 1180pt window width, toggling the 288pt sidebar or 324pt inspector keeps container width >= 728pt,
        // so the centered 680pt transcript column width must remain constant and never invalidate row heights.
        XCTAssertEqual(DesktopLiveRows.contentWidth(forContainerWidth: 892), 680)
        XCTAssertEqual(DesktopLiveRows.contentWidth(forContainerWidth: 1180), 680)
        XCTAssertEqual(DesktopLiveRows.contentWidth(forContainerWidth: 856), 680)
        // Narrow container subtracts horizontal padding (48pt) and clamps at 0.
        XCTAssertEqual(DesktopLiveRows.contentWidth(forContainerWidth: 572), 524)
        XCTAssertEqual(DesktopLiveRows.contentWidth(forContainerWidth: 24), 0)

        let rowHeights = DesktopRowHeights()
        let ids = (0..<10).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            let message = DesktopMessage(id: id, role: .assistant, text: "Row \(index)")
            let layout = DesktopRowHeights.Layout(
                message: message, width: 680, fontFamily: .system, fontSize: 15,
                reasoningExpanded: nil, autoExpandThinking: false, reasoningExpandedByDefault: false,
                hidesToolCalls: false, expandedTools: []
            )
            let y = CGFloat(index) * 300
            XCTAssertTrue(rowHeights.record(id, .init(layout: layout, frame: CGRect(x: 0, y: y, width: 680, height: 280))))
            XCTAssertEqual(rowHeights.height(id, layout: layout), 280)

            let resizedLayout = DesktopRowHeights.Layout(
                message: message, width: 524, fontFamily: .system, fontSize: 15,
                reasoningExpanded: nil, autoExpandThinking: false, reasoningExpandedByDefault: false,
                hidesToolCalls: false, expandedTools: []
            )
            XCTAssertNil(rowHeights.height(id, layout: resizedLayout))
            XCTAssertEqual(rowHeights.anyHeight(id), 280)
        }

        let bottomViewport = CGRect(x: 0, y: 2400, width: 680, height: 600)
        let liveRows = DesktopLiveRows(visible: bottomViewport, rowIDs: ids, heights: rowHeights)
        // Rows near the bottom viewport (y >= 1500) are live; earlier history rows stay virtualized placeholders.
        XCTAssertFalse(liveRows.contains(0))
        XCTAssertFalse(liveRows.contains(3))
        XCTAssertTrue(liveRows.contains(8))
        XCTAssertTrue(liveRows.contains(9))
    }

    @MainActor func testRightInspectorToolbarToggleRemainsStationaryAcrossExpandAndCollapse() throws {
        let defaults = UserDefaults.standard
        let previousInspectorVisible = defaults.object(forKey: "desktop.inspector.visible")
        defer {
            if let previousInspectorVisible {
                defaults.set(previousInspectorVisible, forKey: "desktop.inspector.visible")
            } else {
                defaults.removeObject(forKey: "desktop.inspector.visible")
            }
        }
        defaults.set(true, forKey: "desktop.inspector.visible")

        let workspace = DesktopWorkspace.uiFixture()
        let root = DesktopWorkspaceView(workspace: workspace, searchRequest: 0)
            .frame(width: 1440, height: 860)
            .environment(\.colorScheme, .light)
            .environment(\.desktopLiquidMorphPreviewProgress, nil)
            .tint(DesktopTheme.accent)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1440, height: 860))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))

        func findSubprobe(_ id: String) throws -> (view: NSView, frameInWindow: NSRect) {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let toolbar = try XCTUnwrap(window.toolbar)
            func search(_ root: NSView) -> NSView? {
                if root.identifier?.rawValue == id { return root }
                for child in root.subviews {
                    if let found = search(child) { return found }
                }
                return nil
            }
            for item in toolbar.items {
                guard let itemView = item.view else { continue }
                itemView.layoutSubtreeIfNeeded()
                if let probe = search(itemView) {
                    return (probe, probe.convert(probe.bounds, to: nil))
                }
            }
            XCTFail("Toolbar probe \(id) not found")
            throw CancellationError()
        }

        func findInspectorItem() throws -> (view: NSView, frameInWindow: NSRect) {
            try findSubprobe("amber.toolbar.inspectorToggle")
        }

        func findToolbarCapsule() throws -> (view: NSView, frameInWindow: NSRect) {
            try findSubprobe("amber.toolbar.liquidCapsule")
        }

        func clickWindow(at point: NSPoint) {
            if let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0
            ), let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + 0.02, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0.0
            ) {
                window.sendEvent(down)
                window.sendEvent(up)
            }
        }

        // Initial state: right inspector is docked -> top capsule bar is SHORT (80pt) and toggle tooltip is "隐藏右侧面板".
        let initial = try findInspectorItem()
        let initialCapsule = try findToolbarCapsule()
        XCTAssertEqual(initial.view.toolTip, "隐藏右侧面板")
        XCTAssertEqual(initialCapsule.frameInWindow.width, 80.0, accuracy: 2.0)
        let anchorPoint = NSPoint(x: initial.frameInWindow.midX, y: initial.frameInWindow.midY)

        // Click 1 at anchorPoint: collapse right inspector -> top capsule bar LENGTHENS to 260pt while toggle anchor stays fixed.
        clickWindow(at: anchorPoint)
        RunLoop.main.run(until: Date().addingTimeInterval(0.85))
        let collapsed = try findInspectorItem()
        let collapsedCapsule = try findToolbarCapsule()
        XCTAssertEqual(collapsed.view.toolTip, "显示右侧面板（窗口足够宽时常驻）")
        XCTAssertTrue(collapsed.frameInWindow.contains(anchorPoint),
                      "Expected collapsed item frame \(collapsed.frameInWindow) to contain fixed cursor point \(anchorPoint)")
        XCTAssertEqual(collapsed.frameInWindow.midX, initial.frameInWindow.midX, accuracy: 1.0)
        XCTAssertEqual(collapsedCapsule.frameInWindow.width, 260.0, accuracy: 2.0)
        XCTAssertEqual(collapsedCapsule.frameInWindow.maxX, initialCapsule.frameInWindow.maxX, accuracy: 1.0)

        // Click 2 at the exact same anchorPoint without moving the cursor: re-expand right inspector -> top capsule SHORTENS back to 80pt.
        clickWindow(at: anchorPoint)
        RunLoop.main.run(until: Date().addingTimeInterval(0.85))
        let reexpanded = try findInspectorItem()
        let reexpandedCapsule = try findToolbarCapsule()
        XCTAssertEqual(reexpanded.view.toolTip, "隐藏右侧面板")
        XCTAssertTrue(reexpanded.frameInWindow.contains(anchorPoint))
        XCTAssertEqual(reexpanded.frameInWindow.midX, initial.frameInWindow.midX, accuracy: 1.0)
        XCTAssertEqual(reexpandedCapsule.frameInWindow.width, 80.0, accuracy: 2.0)
        XCTAssertEqual(reexpandedCapsule.frameInWindow.maxX, initialCapsule.frameInWindow.maxX, accuracy: 1.0)

        // Rapid mid-animation reversal (click to collapse, then reverse 90ms into the spring at the same anchorPoint).
        clickWindow(at: anchorPoint)
        RunLoop.main.run(until: Date().addingTimeInterval(0.09))
        let midTransition = try findInspectorItem()
        let midCapsule = try findToolbarCapsule()
        XCTAssertTrue(midTransition.frameInWindow.contains(anchorPoint))
        XCTAssertEqual(midTransition.frameInWindow.midX, initial.frameInWindow.midX, accuracy: 1.0)
        XCTAssertGreaterThan(midCapsule.frameInWindow.width, 95.0)
        clickWindow(at: anchorPoint)
        RunLoop.main.run(until: Date().addingTimeInterval(0.85))
        let reversed = try findInspectorItem()
        let reversedCapsule = try findToolbarCapsule()
        XCTAssertEqual(reversed.view.toolTip, "隐藏右侧面板")
        XCTAssertTrue(reversed.frameInWindow.contains(anchorPoint))
        XCTAssertEqual(reversed.frameInWindow.midX, initial.frameInWindow.midX, accuracy: 1.0)
        XCTAssertEqual(reversedCapsule.frameInWindow.width, 80.0, accuracy: 2.0)
    }

}
