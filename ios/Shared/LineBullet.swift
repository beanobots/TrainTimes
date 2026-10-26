import SwiftUI
import UIKit
import WidgetKit

extension Color {
    init(hex: UInt32) {
        let rgb = LineStyle.rgb(hex)
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// `light` in light mode, `dark` in dark mode.
    init(light: UIColor, dark: UIColor) {
        // Assigned rather than self.init(_:), which Xcode's previews can't build
        self = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// Live predictions on the countdown, which is always dark.
    static let liveGreen = Color(uiColor: .liveGreen)

    /// Live predictions in the app and widgets: darker in light mode for readability.
    static let liveText = Color(light: UIColor(red: 0.08, green: 0.50, blue: 0.20, alpha: 1), dark: .liveGreen)
}

extension UIColor {
    /// Live predictions on a dark background.
    fileprivate static let liveGreen = UIColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1)
}

extension LineStyle {
    /// The line's colour (`uiColor` for UIKit).
    var swiftUIColor: Color { Color(hex: color) }

    var uiColor: UIColor {
        let rgb = Self.rgb(color)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// Bullet label colour: black on light bullets, otherwise white.
    var textColor: Color { usesDarkText ? .black : .white }

    var textUIColor: UIColor { usesDarkText ? .black : .white }
}

extension Arrival {
    /// Green when live; otherwise `scheduled`, the surrounding text colour.
    func statusColor(scheduled: Color) -> Color {
        isLive ? .liveText : scheduled
    }
}

/// A line's round bullet: its letter or number on the MTA's color for it.
struct LineBullet: View {
    /// A real-time route id; see `LineStyle.of`.
    let route: String
    let size: CGFloat
    /// Scales with Dynamic Type, up to twice `size`, when given a text style.
    private let scales: Bool
    @ScaledMetric private var scaledSize: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// `textStyle` is the adjacent text's style to scale with; nil for a fixed size.
    init(route: String, size: CGFloat, relativeTo textStyle: Font.TextStyle? = nil) {
        self.route = route
        self.size = size
        scales = textStyle != nil
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: textStyle ?? .body)
    }

    var body: some View {
        let style = LineStyle.of(route)
        let size = scales ? min(scaledSize, self.size * 2) : self.size
        if renderingMode == .fullColor {
            Self.label(style, size: size)
                .foregroundStyle(style.textColor)
                .frame(width: size, height: size)
                .background(Circle().fill(style.swiftUIColor))
                .accessibilityLabel(Lines.spokenName(of: route))
        } else {
            // Tinted and clear Home Screens draw in one colour, which would hide the letter in a
            // filled bullet; an outline stays readable.
            Self.label(style, size: size)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(lineWidth: 1.5))
                .widgetAccentable()
                .accessibilityLabel(Lines.spokenName(of: route))
        }
    }

    /// The bullet's letter or number, centred for a bullet `size` across.
    static func label(_ style: LineStyle, size: CGFloat) -> some View {
        let fontSize = style.labelSize(bullet: size)
        return Text(style.label)
            .font(.system(size: fontSize, weight: .bold))
            .offset(y: -capitalsOffset(fontSize: fontSize))
    }

    /// How far a bold label's capitals sit below its line's centre. SwiftUI centres the
    /// ascender-to-descender box, so this offset centres the glyph itself.
    static func capitalsOffset(fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        return (font.ascender + font.descender - font.capHeight) / 2
    }
}

/// Several lines' bullets in about the room of one: side by side for two, a 2x2 grid for three or
/// four, rows of three for more.
struct LineBullets: View {
    let routes: [String]
    let size: CGFloat
    /// The line to light; the others are greyed out. Nil, or a line not among `routes`, lights all.
    var lit: String? = nil

    static func width(count: Int, size: CGFloat) -> CGFloat {
        switch count {
        case ..<2: size
        case 2: size * 1.6 + 2
        default: size * 1.2 + 2
        }
    }

    /// Columns, rows and bullet size for `count` bullets in a square `side` across, `gap` apart.
    /// `BulletImage` uses the same layout.
    static func grid(count: Int, side: CGFloat, gap: CGFloat) -> (columns: Int, rows: Int, bullet: CGFloat) {
        let columns = count <= 1 ? 1 : count <= 4 ? 2 : 3
        let rows = (count + columns - 1) / columns
        let across = CGFloat(max(columns, rows))
        return (columns, rows, (side - gap * (across - 1)) / across)
    }

    var body: some View {
        if routes.count < 2 {
            LineBullet(route: routes.first ?? "", size: size)
        } else if routes.count == 2 {
            HStack(spacing: 2) {
                ForEach(routes, id: \.self) { bullet($0, size: size * 0.8) }
            }
        } else {
            let grid = Self.grid(count: routes.count, side: Self.width(count: routes.count, size: size), gap: 2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(stride(from: 0, to: routes.count, by: grid.columns)), id: \.self) { start in
                    HStack(spacing: 2) {
                        ForEach(routes[start..<min(start + grid.columns, routes.count)], id: \.self) {
                            bullet($0, size: grid.bullet)
                        }
                    }
                }
            }
        }
    }

    /// A bullet, greyed out if another of `routes` is lit.
    private func bullet(_ route: String, size: CGFloat) -> some View {
        let dimmed = lit.map { $0 != route && routes.contains($0) } ?? false
        return LineBullet(route: route, size: size)
            .grayscale(dimmed ? 1 : 0)
            .opacity(dimmed ? 0.35 : 1)
    }
}

/// Marks a live time without relying on green: Settings › Mark live times, or Differentiate
/// Without Color.
struct LiveMark: View {
    let size: CGFloat

    static let symbol = "dot.radiowaves.up.forward"

    var body: some View {
        Image(systemName: Self.symbol)
            .font(.system(size: size, weight: .bold))
            .accessibilityLabel("Live")
    }
}

/// Marks a timetable time: Settings › Mark scheduled times.
struct ScheduledMark: View {
    let size: CGFloat

    static let symbol = "clock"

    var body: some View {
        Image(systemName: Self.symbol)
            .font(.system(size: size, weight: .bold))
            .accessibilityLabel("Scheduled")
    }
}

/// A time's `LiveMark` or `ScheduledMark`, as `marks` has them, or nothing.
struct StatusMark: View {
    let isLive: Bool
    let marks: TimeMarks
    let size: CGFloat

    var body: some View {
        if marks.showsMark(isLive: isLive) {
            if isLive {
                LiveMark(size: size)
            } else {
                ScheduledMark(size: size)
            }
        }
    }
}

extension TimeMarks {
    /// The mark's symbol name for use in text, if the time gets a mark.
    func symbol(isLive: Bool) -> String? {
        guard showsMark(isLive: isLive) else { return nil }
        return isLive ? LiveMark.symbol : ScheduledMark.symbol
    }
}

extension AppSettings {
    /// Which times get marks: per Settings, plus live times always under Differentiate Without
    /// Color or a one-colour widget (`renderingMode` not full colour).
    func timeMarks(withoutColor: Bool, renderingMode: WidgetRenderingMode = .fullColor) -> TimeMarks {
        TimeMarks(marksLiveTimes: marksLiveTimes, marksScheduledTimes: marksScheduledTimes,
                  withoutColor: withoutColor, inOneColor: renderingMode != .fullColor)
    }
}

extension ServiceAlert.Kind {
    var symbol: String {
        switch self {
        case .delays, .suspended: "exclamationmark.triangle.fill"
        case .serviceChange: "exclamationmark.circle.fill"
        case .notice: "info.circle.fill"
        }
    }

    var tint: Color { self == .notice ? .blue : .orange }
}

extension Notice.Kind {
    var symbol: String {
        switch self {
        case .alert(let kind): kind.symbol
        case .elevator: "figure.roll"
        }
    }

    var tint: Color {
        switch self {
        case .alert(let kind): kind.tint
        case .elevator: .orange
        }
    }
}

extension Notice {
    var symbol: String { kind.symbol }

    var tint: Color { kind.tint }
}
