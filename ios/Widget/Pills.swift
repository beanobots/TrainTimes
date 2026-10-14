import AppIntents
import SwiftUI
import WidgetKit

/// A round-ended button face on the widget and the countdown.
struct Pill: View {
    let symbol: String
    /// Lit in this line's color, for a walk button whose countdown is running.
    var lit: LineStyle? = nil
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.bold))
            .foregroundStyle(iconColor)
            .frame(width: 44, height: 24)
            .background {
                if let lit, renderingMode == .fullColor {
                    Capsule().fill(Color(hex: lit.color))
                } else if lit != nil {
                    // Tinted and clear Home Screens draw a widget in one color; an outline stays readable
                    Capsule().strokeBorder(lineWidth: 1.5)
                } else {
                    Capsule().fill(.white.opacity(0.15))
                }
            }
            .widgetAccentable(lit != nil)
            .contentShape(Capsule())
    }

    private var iconColor: Color {
        guard let lit, renderingMode == .fullColor else { return .white }
        return lit.usesDarkText ? .black : .white
    }
}

/// ↻: new times for the widgets and the countdown.
struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshIntent()) {
            Pill(symbol: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }
}

/// Starts or stops the countdown; lit while it's running.
struct WalkButton<Intent: AppIntent>: View {
    let intent: Intent
    let route: String
    let isOn: Bool

    var body: some View {
        Button(intent: intent) {
            Pill(symbol: "figure.walk", lit: isOn ? LineStyle.of(route) : nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Stop the countdown" : "I'm on my way")
    }
}
