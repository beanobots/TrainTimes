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

    /// A live prediction on the countdown, which is always dark.
    static let liveGreen = Color(uiColor: .liveGreen)

    /// A live prediction in the app and on the widgets: darker on a light
    /// background so it stays readable, `liveGreen` on a dark one.
    static let liveText = Color(light: UIColor(red: 0.08, green: 0.50, blue: 0.20, alpha: 1), dark: .liveGreen)
}

extension UIColor {
    /// A live prediction on a dark background.
    fileprivate static let liveGreen = UIColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1)
}

extension LineStyle {
    /// The line's colour, and its `uiColor` for drawing with UIKit.
    var swiftUIColor: Color { Color(hex: color) }

    var uiColor: UIColor {
        let rgb = Self.rgb(color)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// The colour of the letter or number on its bullet: black on the light
    /// bullets, white on the rest.
    var textColor: Color { usesDarkText ? .black : .white }

    var textUIColor: UIColor { usesDarkText ? .black : .white }
}

extension Arrival {
    /// Its time's colour: green for a live prediction, or for a timetable
    /// time `scheduled`, the colour of the text around it.
    func statusColor(scheduled: Color) -> Color {
        isLive ? .liveText : scheduled
    }
}

/// A line's round bullet: its letter or number on the MTA's color for it.
struct LineBullet: View {
    /// A real-time route id; see `LineStyle.of`.
    let route: String
    let size: CGFloat
    /// Beside text of a text style, it grows as that does with the phone's
    /// text size, up to twice `size`; otherwise it stays `size`.
    private let scales: Bool
    @ScaledMetric private var scaledSize: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// `textStyle` is the style of the text it's beside, for it to grow as
    /// that does; nil where it has a set room.
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
            // Tinted and clear Home Screens draw a widget in one color, which
            // would fill the bullet over its letter; an outline stays readable.
            Self.label(style, size: size)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(lineWidth: 1.5))
                .widgetAccentable()
                .accessibilityLabel(Lines.spokenName(of: route))
        }
    }

    /// The letter or number of a bullet `size` across, in its middle.
    static func label(_ style: LineStyle, size: CGFloat) -> some View {
        let fontSize = style.labelSize(bullet: size)
        return Text(style.label)
            .font(.system(size: fontSize, weight: .bold))
            .offset(y: -capitalsOffset(fontSize: fontSize))
    }

    /// How far below the middle of its line a bold label's capitals sit. SwiftUI
    /// centres a line of text, which runs from its ascender to its descender, so
    /// this puts the letter or number itself in the middle of the circle.
    static func capitalsOffset(fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        return (font.ascender + font.descender - font.capHeight) / 2
    }
}

extension VerticalAlignment {
    /// The middle of a block of text as you see it: halfway between the top of
    /// its first line's capitals and its last baseline, so a bullet beside a
    /// station name and direction looks centred on them.
    private enum TextMiddle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }

    static let textMiddle = VerticalAlignment(TextMiddle.self)
}

extension View {
    /// Puts this block of text's `.textMiddle` where its text's middle is,
    /// given the height of its first line's capitals.
    func textMiddleGuide(capHeight: CGFloat) -> some View {
        alignmentGuide(.textMiddle) { d in
            (d[.firstTextBaseline] - capHeight + d[.lastTextBaseline]) / 2
        }
    }
}

/// The bullets of the chosen lines in about the room of one: side by side for
/// two, two rows of two for three or four, and rows of three for more, in the
/// same square as four.
struct LineBullets: View {
    let routes: [String]
    let size: CGFloat

    /// How wide the bullets of this many lines are.
    static func width(count: Int, size: CGFloat) -> CGFloat {
        switch count {
        case ..<2: size
        case 2: size * 1.6 + 2
        default: size * 1.2 + 2
        }
    }

    /// How `count` lines' bullets share a square `side` across, `gap` apart:
    /// one, two to a row for up to four, three for more; how many rows that
    /// makes; and how big each bullet is, so the rows fit the square too.
    /// `BulletImage` draws them the same way.
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
                ForEach(routes, id: \.self) { LineBullet(route: $0, size: size * 0.8) }
            }
        } else {
            let grid = Self.grid(count: routes.count, side: Self.width(count: routes.count, size: size), gap: 2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(stride(from: 0, to: routes.count, by: grid.columns)), id: \.self) { start in
                    HStack(spacing: 2) {
                        ForEach(routes[start..<min(start + grid.columns, routes.count)], id: \.self) {
                            LineBullet(route: $0, size: grid.bullet)
                        }
                    }
                }
            }
        }
    }
}

/// Beside a live prediction, so it stands out without its green: with
/// Settings › Mark live times, or the phone's Differentiate Without Color.
struct LiveMark: View {
    let size: CGFloat

    static let symbol = "dot.radiowaves.up.forward"

    var body: some View {
        Image(systemName: Self.symbol)
            .font(.system(size: size, weight: .bold))
            .accessibilityLabel("Live")
    }
}

/// Beside a timetable time, so it stands out from a live prediction: with
/// Settings › Mark scheduled times.
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
    /// The symbol of a time's mark, as there's one, for text.
    func symbol(isLive: Bool) -> String? {
        guard showsMark(isLive: isLive) else { return nil }
        return isLive ? LiveMark.symbol : ScheduledMark.symbol
    }
}

extension AppSettings {
    /// Which times get their mark: as chosen in Settings, and live ones always
    /// with the phone's Differentiate Without Color, or on a widget drawn in
    /// one colour (a `renderingMode` other than full colour).
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
