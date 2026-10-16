import SwiftUI
import UIKit
import WidgetKit

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// A live prediction, on the widget's black background.
    static let liveGreen = Color(red: 0.30, green: 0.85, blue: 0.39)

    /// A live prediction in the app: darker on a light background so it stays
    /// readable, brighter on a dark one.
    static let liveText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1)
            : UIColor(red: 0.08, green: 0.50, blue: 0.20, alpha: 1)
    })
}

/// A line's round bullet: its letter or number on the MTA's color for it.
struct LineBullet: View {
    /// A real-time route id; see `LineStyle.of`.
    let route: String
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let style = LineStyle.of(route)
        let fontSize = size * (style.label.count > 1 ? 0.45 : 0.62)
        let label = Text(style.label)
            .font(.system(size: fontSize, weight: .bold))
            .offset(y: -Self.capitalsOffset(fontSize: fontSize))
        if renderingMode == .fullColor {
            label
                .foregroundStyle(style.usesDarkText ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color(hex: style.color)))
                .accessibilityLabel("\(style.label) train")
        } else {
            // Tinted and clear Home Screens draw a widget in one color, which
            // would fill the bullet over its letter; an outline stays readable.
            label
                .frame(width: size, height: size)
                .overlay(Circle().stroke(lineWidth: 1.5))
                .widgetAccentable()
                .accessibilityLabel("\(style.label) train")
        }
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

/// The bullets of the chosen lines in about the room of one: side by side for
/// two, two rows of two for three or four.
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

    var body: some View {
        if routes.count < 2 {
            LineBullet(route: routes.first ?? "", size: size)
        } else if routes.count == 2 {
            HStack(spacing: 2) {
                ForEach(routes, id: \.self) { LineBullet(route: $0, size: size * 0.8) }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(stride(from: 0, to: routes.count, by: 2)), id: \.self) { start in
                    HStack(spacing: 2) {
                        ForEach(routes[start..<min(start + 2, routes.count)], id: \.self) { LineBullet(route: $0, size: size * 0.6) }
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

    var body: some View {
        Image(systemName: "dot.radiowaves.up.forward")
            .font(.system(size: size, weight: .bold))
            .accessibilityLabel("Live")
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

extension Notice {
    var symbol: String {
        switch kind {
        case .alert(let kind): kind.symbol
        case .elevator: "figure.roll"
        }
    }

    var tint: Color {
        switch kind {
        case .alert(let kind): kind.tint
        case .elevator: .orange
        }
    }
}
