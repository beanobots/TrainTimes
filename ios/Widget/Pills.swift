import AppIntents
import SwiftUI
import WidgetKit

/// A round-ended button face on the widget and the countdown.
struct Pill: View {
    let symbol: String
    /// Lit in this line's color: a walk button whose countdown is running, a map
    /// button showing the stops, or ↻ just after it was tapped.
    var lit: LineStyle? = nil
    /// Takes an equal share of the row, as on the home screen widgets; the
    /// countdown's are a fixed width.
    var fills = false
    /// On the medium widget's larger layout.
    var large = false
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Image(systemName: symbol)
            .font(large ? .subheadline.weight(.bold) : .footnote.weight(.bold))
            .foregroundStyle(iconColor)
            .frame(width: fills ? nil : 44, height: large ? BoardStyle.large.buttonHeight : BoardStyle.compact.buttonHeight)
            .frame(maxWidth: fills ? .infinity : nil)
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
    /// Lit in this line's color just after it was tapped.
    var lit: LineStyle? = nil
    var fills = false
    /// With no countdown running, a widget refreshes itself, which is quicker
    /// than going through the app.
    var widgetsOnly = false
    var large = false

    var body: some View {
        Group {
            if widgetsOnly {
                Button(intent: RefreshWidgetsIntent()) { face }
            } else {
                Button(intent: RefreshIntent()) { face }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }

    /// Lights up at once as new times come in, then fades back over a second
    /// (widgets animate between timeline entries).
    private var face: some View {
        Pill(symbol: "arrow.clockwise", lit: lit, fills: fills, large: large)
            .animation(lit == nil ? .easeOut(duration: 1) : nil, value: lit)
    }
}

/// Starts or stops the countdown; lit while it's running.
struct WalkButton<Intent: AppIntent>: View {
    let intent: Intent
    let route: String
    let isOn: Bool
    var fills = false
    var large = false

    var body: some View {
        Button(intent: intent) {
            Pill(symbol: "figure.walk", lit: isOn ? LineStyle.of(route) : nil, fills: fills, large: large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Stop the countdown" : "I'm on my way")
    }
}

/// The medium widget's switch between the later trains and the stops before
/// yours; lit while the stops show.
struct MapButton: View {
    let selection: Selection
    let isOn: Bool
    var large = false

    var body: some View {
        Button(intent: ToggleMapIntent(selection: selection)) {
            Pill(symbol: "map", lit: isOn ? LineStyle.of(selection.firstRoute) : nil, fills: true, large: large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Show times" : "Show where the train is")
    }
}
