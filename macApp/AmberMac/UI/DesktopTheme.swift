import AppKit
import SwiftUI

enum DesktopTheme {
    static let contentWidth: CGFloat = 760

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 21 / 255, green: 22 / 255, blue: 24 / 255)
            : Color(red: 252 / 255, green: 252 / 255, blue: 250 / 255)
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 32 / 255, green: 34 / 255, blue: 38 / 255)
            : Color(red: 242 / 255, green: 243 / 255, blue: 241 / 255)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 28 / 255, green: 29 / 255, blue: 32 / 255)
            : Color(red: 244 / 255, green: 245 / 255, blue: 243 / 255)
    }

    static func raised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 38 / 255, green: 40 / 255, blue: 44 / 255) : .white
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.08)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.55) : .black.opacity(0.56)
    }

    static func accentWash(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 61 / 255, green: 51 / 255, blue: 40 / 255)
            : Color(red: 238 / 255, green: 231 / 255, blue: 219 / 255)
    }

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 213 / 255, green: 172 / 255, blue: 123 / 255, alpha: 1)
            : NSColor(red: 160 / 255, green: 96 / 255, blue: 42 / 255, alpha: 1)
    })

    static func colorScheme(for appearance: String) -> ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
