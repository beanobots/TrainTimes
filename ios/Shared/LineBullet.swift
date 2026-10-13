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
        let label = Text(style.label)
            .font(.system(size: size * (style.label.count > 1 ? 0.45 : 0.62), weight: .bold))
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
