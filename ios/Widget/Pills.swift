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
    /// A circle rather than a wider pill, for a lesser button (Transit Directions' ✕).
    var round = false
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var height: CGFloat { large ? BoardStyle.large.buttonHeight : BoardStyle.compact.buttonHeight }

    var body: some View {
        Image(systemName: symbol)
            .font(large ? .subheadline.weight(.bold) : .footnote.weight(.bold))
            // Held to what fits its face, which stays the height of the row of buttons
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(iconColor)
            .frame(width: fills ? nil : round ? height : 44, height: height)
            .frame(maxWidth: fills ? .infinity : nil)
            .background {
                if let lit, renderingMode == .fullColor {
                    Capsule().fill(lit.swiftUIColor)
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
        return lit.textColor
    }
}

/// Lit in its line's colour while on. A toggle because iOS flips it on tap, before the intent
/// runs, so it responds instantly; the redraw then shows the real state. ↻ is always off (lit
/// until new times arrive); walk is on while the countdown runs.
private struct FlashButton<Intent: AppIntent>: View {
    let symbol: String
    let intent: Intent
    let route: String
    let label: String
    var isOn = false
    var fills = false
    var large = false

    var body: some View {
        Toggle(isOn: isOn, intent: intent) {
            Pill(symbol: symbol, lit: isOn ? LineStyle.of(route) : nil, fills: fills, large: large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// ↻ on the countdown: new times for it and the widgets.
struct RefreshButton: View {
    /// The line whose colour it flashes.
    var route = ""
    var fills = false

    var body: some View {
        FlashButton(symbol: "arrow.clockwise", intent: RefreshIntent(widgetID: nil), route: route,
                    label: "Refresh", fills: fills)
    }
}

/// Transit Directions' ✕, beside walk while it shows a trip or Favorite Stop: back to its Quick
/// Trip and Favorite Stop buttons. With them to draw (`endTripFace`), a toggle, as iOS flips one
/// on tap before the intent runs: the tap shows them at once, over the whole widget, until the
/// redraw shows the real ones. With `closing`, Next train's or Transfers' open board's ✕
/// instead: back to its card (`CloseBoardIntent`), which `endTripFace` then is.
struct EndTripButton: View {
    var large = false
    /// The `TrainEntry.widgetID` of the open board it closes; nil on Transit Directions.
    var closing: String? = nil
    @Environment(\.stillControls) private var still
    @Environment(\.endTripFace) private var face

    var body: some View {
        if let closing {
            button(CloseBoardIntent(widgetID: closing), label: "Hide the times")
        } else {
            button(EndSharedTripIntent(), label: "Back to Favorite Stop, Nearby and Trip")
        }
    }

    @ViewBuilder private func button<Intent: AppIntent>(_ intent: Intent, label: String) -> some View {
        if still {
            Pill(symbol: "xmark", large: large, round: true)
        } else if let face {
            let style = SwapToggleStyle { isOn in
                Pill(symbol: "xmark", large: large, round: true)
                    .overlay(alignment: .topLeading) {
                        if isOn.wrappedValue {
                            GeometryReader { proxy in
                                // From the ✕ back to the widget's top left
                                let origin = proxy.frame(in: .named(EndTripFace.space)).origin
                                face.view
                                    .frame(width: face.size.width, height: face.size.height)
                                    .background(Color.boardBackground)
                                    .offset(x: -origin.x, y: -origin.y)
                            }
                            // Not crossfaded over the board
                            .transition(.pressed)
                        }
                    }
            }
            Toggle(isOn: false, intent: intent) {
                Text(label)
            }
            .toggleStyle(style)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
        } else {
            Button(intent: intent) {
                Pill(symbol: "xmark", large: large, round: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }
}

/// A walk's countdown's "I'm on the train" (`BoardedTrainIntent`), at the station or the change.
struct BoardButton: View {
    let route: String
    var fills = false

    var body: some View {
        FlashButton(symbol: "tram.fill", intent: BoardedTrainIntent(), route: route, label: "I'm on the train",
                    fills: fills)
    }
}

/// Starts or stops the countdown; lit while it's running.
struct WalkButton<Intent: AppIntent>: View {
    let intent: Intent
    let route: String
    /// The countdown is running, so a tap stops it.
    let running: Bool
    var fills = false
    var large = false
    @Environment(\.stillControls) private var still

    var body: some View {
        if still {
            Pill(symbol: "figure.walk", lit: running ? LineStyle.of(route) : nil, fills: fills, large: large)
        } else {
            FlashButton(symbol: "figure.walk", intent: intent, route: route,
                        label: running ? "Stop the countdown" : "I'm on my way", isOn: running, fills: fills, large: large)
        }
    }
}
