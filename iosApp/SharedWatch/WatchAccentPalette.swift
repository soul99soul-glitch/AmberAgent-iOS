import SwiftUI

/// Watch colors derived from the phone theme accent. The phone accent is
/// tuned for light canvases, so every role is re-lit for the black Watch
/// background; hue and saturation are the only things carried over.
struct WatchAccentPalette: Equatable {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// Logo, global tint and the primary ask button.
    var accent: RGB
    /// Text on `accent`.
    var onAccent: RGB
    /// Status text, symbol and border on the result card.
    var cardAccent: RGB
    /// Result card background, top-leading to bottom-trailing.
    var cardGradient: [RGB]

    static let minimumAccentBrightness = 0.78

    /// The original Amber copper, kept verbatim for older phones and when
    /// the user turns following off.
    static let copper = WatchAccentPalette(
        accent: RGB(red: 0.83, green: 0.39, blue: 0.20),
        onAccent: RGB(red: 1, green: 1, blue: 1),
        cardAccent: RGB(red: 0.91, green: 0.47, blue: 0.25),
        cardGradient: [RGB(red: 0.29, green: 0.14, blue: 0.085),
                       RGB(red: 0.10, green: 0.065, blue: 0.05),
                       RGB(red: 0.055, green: 0.035, blue: 0.03)]
    )

    init(accent: RGB, onAccent: RGB, cardAccent: RGB, cardGradient: [RGB]) {
        self.accent = accent
        self.onAccent = onAccent
        self.cardAccent = cardAccent
        self.cardGradient = cardGradient
    }

    init(hex: UInt32) {
        let (hue, saturation, brightness) = Self.hsb(hex)
        accent = Self.rgb(hue, saturation, max(brightness, Self.minimumAccentBrightness))
        onAccent = Self.luminance(accent) > 0.55 ? RGB(red: 0, green: 0, blue: 0) : RGB(red: 1, green: 1, blue: 1)
        cardAccent = Self.rgb(hue, saturation, max(brightness, 0.9))
        let cardSaturation = min(saturation, 0.75)
        cardGradient = [Self.rgb(hue, cardSaturation, 0.29),
                        Self.rgb(hue, cardSaturation * 0.7, 0.10),
                        Self.rgb(hue, cardSaturation * 0.63, 0.055)]
    }

    private static func hsb(_ hex: UInt32) -> (Double, Double, Double) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        let maximum = max(red, green, blue)
        let delta = maximum - min(red, green, blue)
        guard delta > 0 else { return (0, 0, maximum) }
        var hue: Double
        if maximum == red { hue = (green - blue) / delta }
        else if maximum == green { hue = (blue - red) / delta + 2 }
        else { hue = (red - green) / delta + 4 }
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return (hue, delta / maximum, maximum)
    }

    private static func rgb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> RGB {
        let sector = hue * 6
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: (red, green, blue) = (chroma, x, 0)
        case 1: (red, green, blue) = (x, chroma, 0)
        case 2: (red, green, blue) = (0, chroma, x)
        case 3: (red, green, blue) = (0, x, chroma)
        case 4: (red, green, blue) = (x, 0, chroma)
        default: (red, green, blue) = (chroma, 0, x)
        }
        let offset = brightness - chroma
        return RGB(red: red + offset, green: green + offset, blue: blue + offset)
    }

    private static func luminance(_ color: RGB) -> Double {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }
}
