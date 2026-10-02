import SwiftUI

/// Which greeting the launch curtain shows. Pure so the date rules are testable.
enum NovelLaunchMood: Equatable {
    case standard
    /// 00:00–04:59: the night-owl variant.
    case lateNight
    /// November: National Novel Writing Month.
    case novelWritingMonth
    /// Jan 1.
    case newYear

    static func current(at date: Date, calendar: Calendar = .current) -> NovelLaunchMood {
        let parts = calendar.dateComponents([.month, .day, .hour], from: date)
        if parts.month == 1, parts.day == 1 { return .newYear }
        if let hour = parts.hour, hour < 5 { return .lateNight }
        if parts.month == 11 { return .novelWritingMonth }
        return .standard
    }

    var tagline: String {
        switch self {
        case .standard: "每个故事，都从一页空白开始"
        case .lateNight: "夜深了，灵感正好"
        case .novelWritingMonth: "十一月是写作月，今天也写一点"
        case .newYear: "新的一年，新的第一章"
        }
    }

    var symbol: String? {
        switch self {
        case .standard: nil
        case .lateNight: "moon.stars.fill"
        case .novelWritingMonth: "flame.fill"
        case .newYear: "sparkles"
        }
    }
}

/// Cold-launch overlay: the book mark opens, the nib drops an ink dot, the
/// tagline types in, then the curtain lifts. Tap anywhere to skip. Skipped
/// entirely under Reduce Motion.
struct NovelLaunchCurtain: View {
    let mood: NovelLaunchMood
    let onFinish: () -> Void

    @State private var pagesOpen = false
    @State private var nibDown = false
    @State private var inkDot = false
    @State private var typedCount = 0
    @State private var lifting = false
    @State private var finished = false

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 28) {
                ZStack {
                    NovelBookMark(open: pagesOpen)
                        .frame(width: 132, height: 96)
                        .offset(y: 26)
                    NovelNibMark()
                        .frame(width: 22, height: 54)
                        .offset(y: nibDown ? -46 : -100)
                        .opacity(nibDown ? 1 : 0)
                    Circle()
                        .fill(AmberTheme.accent)
                        .frame(width: 9, height: 9)
                        .offset(y: -12)
                        .scaleEffect(inkDot ? 1 : 0.01)
                        .opacity(inkDot ? 1 : 0)
                }
                .frame(height: 150)

                HStack(spacing: 8) {
                    if let symbol = mood.symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(AmberTheme.accent)
                            .symbolEffect(.pulse, options: .repeating, isActive: typedCount > 0)
                    }
                    // The full line reserves the size so typing never shifts the row.
                    Text(mood.tagline)
                        .opacity(0)
                        .overlay(alignment: .leading) {
                            Text(String(mood.tagline.prefix(typedCount)))
                        }
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(AmberTheme.foreground2)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mood.tagline)
            }
        }
        .offset(y: lifting ? -40 : 0)
        .opacity(lifting ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await play() }
    }

    private func play() async {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { pagesOpen = true }
        try? await Task.sleep(for: .milliseconds(260))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { nibDown = true }
        try? await Task.sleep(for: .milliseconds(320))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { inkDot = true }
        for count in 1...mood.tagline.count {
            guard !finished else { return }
            typedCount = count
            try? await Task.sleep(for: .milliseconds(45))
        }
        try? await Task.sleep(for: .milliseconds(420))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        typedCount = mood.tagline.count
        withAnimation(.easeIn(duration: 0.32)) { lifting = true }
        Task {
            try? await Task.sleep(for: .milliseconds(330))
            onFinish()
        }
    }
}

/// The app mark's open book: two tilted pages that swing open from the gutter.
struct NovelBookMark: View {
    var open: Bool

    var body: some View {
        HStack(spacing: 6) {
            page.rotation3DEffect(.degrees(open ? 0 : 82), axis: (0, 1, 0), anchor: .trailing, perspective: 0.6)
            page.scaleEffect(x: -1).rotation3DEffect(.degrees(open ? 0 : -82), axis: (0, 1, 0), anchor: .leading, perspective: 0.6)
        }
    }

    private var page: some View {
        NovelPageShape()
            .fill(AmberTheme.foreground)
            .overlay {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(AmberTheme.background)
                            .frame(height: 3.5)
                            .rotationEffect(.degrees(10))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 26)
            }
    }
}

private struct NovelPageShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.15))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.15))
            path.closeSubpath()
        }
    }
}

/// The copper pen nib from the app mark.
struct NovelNibMark: View {
    var body: some View {
        NibShape()
            .fill(AmberTheme.accent)
            .overlay {
                VStack(spacing: 0) {
                    Rectangle().fill(AmberTheme.background).frame(width: 1.5)
                    Circle().fill(AmberTheme.background).frame(width: 5, height: 5)
                    Rectangle().fill(AmberTheme.background).frame(width: 1.5).frame(maxHeight: 10)
                }
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
    }

    private struct NibShape: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.7))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.7))
                path.closeSubpath()
            }
        }
    }
}
