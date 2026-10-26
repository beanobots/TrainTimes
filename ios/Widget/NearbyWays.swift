import SwiftUI
import WidgetKit

/// One way a nearby station's line goes, on Transit Directions' Nearby: an arrow in a disc of the
/// line's colour, where it goes and where it ends, then its next train from the times fetched as
/// the screen drew. A row across the widget, the ways stacked beside `NearbyBothTile`.
struct NearbyWayRow: View {
    let route: String
    let way: LineWay
    /// "Manhattan", or the way's letter for a line without names.
    let label: String
    /// Where the line ends going this way, unless `label` names it.
    let end: String?
    let date: Date
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// Saved times older than this aren't shown: the trains in them may have changed.
    static let freshFor: TimeInterval = 30 * 60

    /// The way's next train you can still catch, from its saved times, if they're recent.
    private var next: Arrival? {
        guard let board = SharedStore.loadBoard(for: way.selection),
              board.fetched > date.addingTimeInterval(-Self.freshFor) else { return nil }
        return way.selection.catchable(board.trains, now: date).first
    }

    var body: some View {
        let next = next
        HStack(spacing: 8) {
            WayDisc(route: route, symbol: way.direction == .north ? "arrow.up" : "arrow.down", size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.boardText)
                if let end {
                    Text(end)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.boardGray)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            if let next {
                minutes(next)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.boardText.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(next))
    }

    /// "4 min", green with its mark when live.
    private func minutes(_ train: Arrival) -> some View {
        let wait = MinutesToGo(until: train.time, from: date)
        let marks = SharedStore.loadSettings().timeMarks(withoutColor: withoutColor, renderingMode: renderingMode)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(wait.number).font(.system(size: 20, weight: .bold, design: .rounded))
            if !wait.isNow {
                Text("min").font(.system(size: 12, weight: .semibold))
            }
            StatusMark(isLive: train.isLive, marks: marks, size: 9)
        }
        .monospacedDigit()
        .foregroundStyle(train.statusColor(scheduled: .boardText))
        .lineLimit(1)
        .fixedSize()
    }

    private func spoken(_ next: Arrival?) -> String {
        let wait = next.map { ", next train \(MinutesToGo(until: $0.time, from: date).spoken)" } ?? ""
        return "\(Lines.name(of: route)) train, \(label)\(end.map { ", to \($0)" } ?? "")\(wait)"
    }
}

/// Both ways at once, down the side of the ways' rows, as wide as option 5's mockup.
struct NearbyBothTile: View {
    let route: String

    static let width: CGFloat = 90

    var body: some View {
        VStack(spacing: 5) {
            WayDisc(route: route, symbol: "arrow.up.arrow.down", size: 30)
            Text("Both\nways")
                .font(.subheadline.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.boardText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.boardText.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Lines.name(of: route)) trains, both directions")
    }
}

/// An arrow in a disc of the line's colour; outlined on tinted and clear Home Screens, which draw
/// in one colour, as `LineBullet` is.
private struct WayDisc: View {
    let route: String
    let symbol: String
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let style = LineStyle.of(route)
        let arrow = Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .heavy))
            .frame(width: size, height: size)
        if renderingMode == .fullColor {
            arrow
                .foregroundStyle(style.textColor)
                .background(Circle().fill(style.swiftUIColor))
        } else {
            arrow
                .overlay(Circle().stroke(lineWidth: 1.5))
                .widgetAccentable()
        }
    }
}
