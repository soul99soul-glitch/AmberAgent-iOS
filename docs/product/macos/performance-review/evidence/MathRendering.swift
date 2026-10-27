import AppKit
import iosMath
import SwiftUI

@main struct MathBench {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let source = "能量 $E=mc^2$，比例 $\\frac{a+b}{c}$，继续 $\\sqrt{x^2+y^2}$。"
        let iterations = 500
        let coldStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { _ = DesktopMathText.render(source, fontSize: 15, scheme: .light) }
        let cold = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000

        var key: (String, Double, ColorScheme)?
        var cached = Text("")
        let warmStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            if key?.0 != source || key?.1 != 15 || key?.2 != .light {
                cached = DesktopMathText.render(source, fontSize: 15, scheme: .light)
                key = (source, 15, .light)
            }
            _ = cached
        }
        let warm = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1_000_000
        print("MATH inline iterations=\(iterations) cold_ms=\(String(format: "%.2f", cold)) one_entry_cache_ms=\(String(format: "%.2f", warm))")
        exit(0)
    }
}
