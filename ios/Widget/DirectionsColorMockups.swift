#if DEBUG
import SwiftUI
import WidgetKit

// Throwaway mockups: colour schemes for Transit Directions' buttons. Delete once one is picked.

/// One colour scheme for Transit Directions.
private struct MockScheme {
    let name: String
    let background: Color
    let text: Color
    let secondary: Color
    /// Favorite Stop's card, given its line's colour.
    let cardFill: (Color) -> Color
    let nearby: Color
    let trip: Color
    let symbol: Color

    static let all: [MockScheme] = [
        MockScheme(name: "1 · Current", background: .boardBackground, text: .boardText, secondary: .boardGray,
                   cardFill: { $0.opacity(0.14) }, nearby: Color(hex: 0x00A3A3), trip: Color(hex: 0x7B61FF), symbol: .white),
        MockScheme(name: "2 · Line Wash",
                   background: Color(light: UIColor(red: 0.99, green: 0.96, blue: 0.84, alpha: 1),
                                     dark: UIColor(red: 0.16, green: 0.14, blue: 0.05, alpha: 1)),
                   text: .boardText, secondary: .boardGray,
                   cardFill: { $0.opacity(0.28) },
                   nearby: Color(light: .white, dark: UIColor(white: 0, alpha: 0.6)),
                   trip: Color(light: .white, dark: UIColor(white: 0, alpha: 0.6)),
                   symbol: Color(hex: 0xC9A100)),
        MockScheme(name: "3 · Quiet Mono", background: .boardBackground, text: .boardText, secondary: .boardGray,
                   cardFill: { _ in Color.boardText.opacity(0.07) },
                   nearby: .boardButton, trip: .boardButton, symbol: .boardText),
        MockScheme(name: "4 · Station Signage", background: Color(white: 0.07), text: .white, secondary: Color(white: 0.62),
                   cardFill: { _ in Color(white: 0.16) }, nearby: .white, trip: .white, symbol: .black),
        MockScheme(name: "5 · Warm Paper",
                   background: Color(light: UIColor(red: 0.96, green: 0.94, blue: 0.89, alpha: 1),
                                     dark: UIColor(red: 0.12, green: 0.11, blue: 0.09, alpha: 1)),
                   text: Color(light: UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1),
                               dark: UIColor(red: 0.95, green: 0.92, blue: 0.87, alpha: 1)),
                   secondary: Color(light: UIColor(red: 0.45, green: 0.40, blue: 0.34, alpha: 1),
                                    dark: UIColor(red: 0.66, green: 0.61, blue: 0.54, alpha: 1)),
                   cardFill: { $0.opacity(0.16) }, nearby: Color(hex: 0xD9653B), trip: Color(hex: 0x6B8E4E), symbol: .white),
        MockScheme(name: "6 · Midnight",
                   background: Color(light: UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1),
                                     dark: UIColor(red: 0.05, green: 0.10, blue: 0.17, alpha: 1)),
                   text: Color(light: UIColor(red: 0.05, green: 0.10, blue: 0.17, alpha: 1),
                               dark: UIColor(red: 0.92, green: 0.95, blue: 0.98, alpha: 1)),
                   secondary: Color(light: UIColor(red: 0.33, green: 0.40, blue: 0.50, alpha: 1),
                                    dark: UIColor(red: 0.58, green: 0.66, blue: 0.76, alpha: 1)),
                   cardFill: { $0.opacity(0.18) }, nearby: Color(hex: 0x2D9CDB), trip: Color(hex: 0xF2A93B), symbol: .white),
    ]
}

private struct MockSchemeEntry: TimelineEntry {
    let date: Date
    let index: Int
}

private struct MockSchemeProvider: TimelineProvider {
    func placeholder(in context: Context) -> MockSchemeEntry { MockSchemeEntry(date: .now, index: 0) }
    func getSnapshot(in context: Context, completion: @escaping (MockSchemeEntry) -> Void) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MockSchemeEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

/// The buttons, as `QuickTripView.cards` draws them, in a scheme.
private struct MockHome: View {
    let scheme: MockScheme
    private let route = "R"
    private let circle: CGFloat = 52

    var body: some View {
        let line = LineStyle.of(route).swiftUIColor
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                LineBullet(route: route, size: circle)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("4").font(.system(size: 32, weight: .bold)).monospacedDigit()
                        Text("min").font(.headline)
                    }
                    .foregroundStyle(scheme.text)
                    Text("Union St").font(.caption).foregroundStyle(scheme.secondary)
                    Text("to Manhattan").font(.caption).foregroundStyle(scheme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(scheme.cardFill(line)))
            .overlay(alignment: .bottomTrailing) {
                Text(scheme.name)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(scheme.secondary)
                    .padding(6)
            }
            .padding([.leading, .vertical], 16)
            VStack(spacing: 10) {
                badge("location.fill", tint: scheme.nearby)
                badge(QuickTripSymbol.name, tint: scheme.trip)
            }
            .frame(width: 16 + circle + 8 + 16)
        }
    }

    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: circle * 0.48, weight: .bold))
            .foregroundStyle(scheme.symbol)
            .frame(width: circle, height: circle)
            .background(Circle().fill(tint))
    }
}

private struct DirectionsColorMockups: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "directionsColorMockups", provider: MockSchemeProvider()) { entry in
            let scheme = MockScheme.all[entry.index]
            MockHome(scheme: scheme)
                .containerBackground(scheme.background, for: .widget)
        }
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

#Preview("Colour schemes", as: .systemMedium) {
    DirectionsColorMockups()
} timeline: {
    MockSchemeEntry(date: .now, index: 0)
    MockSchemeEntry(date: .now, index: 1)
    MockSchemeEntry(date: .now, index: 2)
    MockSchemeEntry(date: .now, index: 3)
    MockSchemeEntry(date: .now, index: 4)
    MockSchemeEntry(date: .now, index: 5)
}
#endif
