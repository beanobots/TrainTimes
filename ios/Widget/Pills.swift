import AppIntents
import SwiftUI
import WidgetKit

/// A round-ended button face on the widget and the countdown.
struct Pill: View {
    let symbol: String
    /// Lit in this line's color, from a tap until the redraw it asks for.
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
                    Capsule().fill(Color.boardButton)
                }
            }
            .widgetAccentable(lit != nil)
            .contentShape(Capsule())
    }

    private var iconColor: Color {
        guard renderingMode == .fullColor else { return .white }
        guard let lit else { return .boardText }
        return lit.usesDarkText ? .black : .white
    }
}

/// How every button answers a tap, ↻, map and walk alike: lit in its line's
/// colour the moment it's tapped, then, as the widget (or the countdown)
/// redraws with what the tap asked for, faded back over half a second.
private let flashFade = Animation.easeOut(duration: 0.5)

/// A button that flashes when tapped. It's a toggle that's always off: iOS
/// turns a toggle on the moment it's tapped, before its intent has run, so it
/// lights at once; the redraw after the intent draws it off again.
private struct FlashButton<Intent: AppIntent>: View {
    let symbol: String
    let intent: Intent
    let route: String
    let label: String
    var fills = false
    var large = false

    var body: some View {
        Toggle(isOn: false, intent: intent) {
            Text(label)
        }
        .toggleStyle(FlashToggleStyle(symbol: symbol, route: route, label: label, fills: fills, large: large))
    }
}

private struct FlashToggleStyle: ToggleStyle {
    let symbol: String
    let route: String
    let label: String
    let fills: Bool
    let large: Bool

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Pill(symbol: symbol, lit: configuration.isOn ? LineStyle.of(route) : nil, fills: fills, large: large)
                .animation(configuration.isOn ? nil : flashFade, value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// ↻: new times for the widgets and the countdown.
struct RefreshButton: View {
    /// The line whose colour it flashes in; Trains near you's has none, so grey.
    var route = ""
    var fills = false
    /// Unless the countdown is its own, a widget refreshes itself, which is
    /// quicker than going through the app.
    var widgetsOnly = false
    var large = false
    /// The `TrainEntry.widgetID` of the widget it's on; nil on the countdown.
    var widgetID: String? = nil
    /// The last try for new times couldn't reach the MTA, so the times shown
    /// are old: it shows no signal in place of ↻.
    var failed = false

    var body: some View {
        let symbol = failed ? "wifi.slash" : "arrow.clockwise"
        let label = failed ? "Refresh. Couldn't reach the MTA, so these times are old" : "Refresh"
        if widgetsOnly {
            FlashButton(symbol: symbol, intent: RefreshWidgetsIntent(widgetID: widgetID ?? ""), route: route,
                        label: label, fills: fills, large: large)
        } else {
            FlashButton(symbol: symbol, intent: RefreshIntent(widgetID: widgetID), route: route,
                        label: label, fills: fills, large: large)
        }
    }
}

/// Starts or stops the countdown.
struct WalkButton<Intent: AppIntent>: View {
    let intent: Intent
    let route: String
    /// Whether the countdown is running, so a tap stops it.
    let running: Bool
    var fills = false
    var large = false

    var body: some View {
        FlashButton(symbol: "figure.walk", intent: intent, route: route,
                    label: running ? "Stop the countdown" : "I'm on my way", fills: fills, large: large)
    }
}

/// The medium and large widgets' switch between the later trains and the stops
/// before yours (or, with a change, where the trains are). It's the one button
/// in the map's toggle, which draws the times or the stops for its state, so
/// they swap at once (see `SwapToggleStyle`). It flashes as the others do: lit
/// while the toggle's state is ahead of the widget's, until the widget redraws.
struct MapButton: View {
    /// Whether the stops show: the state of the toggle it's in.
    let isOn: Binding<Bool>
    let route: String
    /// Whether the widget hasn't yet redrawn since the tap.
    var pending = false
    var large = false

    var body: some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Pill(symbol: "map", lit: pending ? LineStyle.of(route) : nil, fills: true, large: large)
                .animation(pending ? nil : flashFade, value: pending)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn.wrappedValue ? "Show times" : "Show where the train is")
    }
}
