import SwiftUI

extension DesktopMessageFontFamily {
    func swiftUIFont(size: Double, weight: Font.Weight = .regular) -> Font {
        let design: Font.Design = switch self {
        case .system: .default
        case .serif: .serif
        case .mono: .monospaced
        }
        return .system(size: size, weight: weight, design: design)
    }
}
