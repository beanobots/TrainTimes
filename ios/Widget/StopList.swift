import SwiftUI
import WidgetKit

/// The medium widget's other side, behind its map button: where the next train
/// is, as the stops between it and yours (see `StopLayout`). Given a `height`,
/// the rows spread out evenly to fill it.
struct StopList: View {
    let train: Arrival
    let now: Date
    var maxRows = 4
    var style = BoardStyle.compact
    var height: CGFloat? = nil

    private var spacing: CGFloat { style.isLarge ? 0 : 1 }

    /// Room above the first row for a train on its way to it, which sits half a
    /// row up, so it doesn't run into the label: half the marker and its ring.
    private func lead(_ layout: StopLayout) -> CGFloat {
        layout.trainRow < 0 ? style.markerSize / 2 + 2 : 0
    }

    /// Each row's share of `height` under the label, never less than the style's.
    private func rowHeight(rows: Int, lead: CGFloat) -> CGFloat {
        guard let height, rows > 0 else { return style.rowHeight }
        let label = style.font(.caption2).lineHeight
        return max(style.rowHeight, floor((height - label - spacing - lead) / CGFloat(rows)))
    }

    var body: some View {
        if let layout = StopLayout(train: train, now: now, maxRows: maxRows) {
            map(layout)
                // The rail and the train on it are drawn, so VoiceOver has them in words
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(layout.spoken(clock: Spoken.clock))
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                Text("WHERE IT IS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.boardGray)
                Text("The MTA hasn't said yet")
                    .font(style.stopFont)
                    .foregroundStyle(Color.boardGray)
            }
        }
    }

    private func map(_ layout: StopLayout) -> some View {
        let lead = lead(layout)
        let rowHeight = rowHeight(rows: layout.rows.count, lead: lead)
        return VStack(alignment: .leading, spacing: spacing) {
            Text(layout.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
            ZStack(alignment: .topLeading) {
                StopRail(layout: layout, color: LineStyle.of(train.route).swiftUIColor, style: style, rowHeight: rowHeight, lead: lead)
                    .frame(width: style.railColumn, height: lead + CGFloat(layout.rows.count) * rowHeight)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(layout.rows) { row in
                        stopRow(row, passed: CGFloat(row.id) < layout.trainRow, height: rowHeight)
                    }
                }
                .padding(.top, lead)
                TrainMarker(route: train.route, isLive: train.isLive, size: style.markerSize)
                    .offset(x: (style.railColumn - style.markerSize) / 2,
                            y: lead + layout.trainRow * rowHeight + (rowHeight - style.markerSize) / 2)
            }
        }
    }

    private func stopRow(_ row: StopLayout.Row, passed: Bool, height: CGFloat) -> some View {
        HStack(spacing: style.isLarge ? 7 : 6) {
            // The rail's column
            Color.clear.frame(width: style.railColumn)
            Text(row.name)
                .mapStop(style.stopFont, yours: row.kind == .yours, trainStop: row.isTrainStop,
                         folded: row.kind == .folded, passed: passed)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let departs = row.departs {
                Spacer(minLength: 4)
                Text(departs.clock)
                    .font(style.departsFont)
                    .monospacedDigit()
                    .foregroundStyle(Color.boardText)
            }
        }
        .frame(height: height)
    }
}

/// The line down the list's left edge, in the train's colour: dimmed behind the
/// train, dashed where stops are folded, with a dot at each stop and a ring at
/// yours, dark on light in light mode.
private struct StopRail: View {
    let layout: StopLayout
    let color: Color
    let style: BoardStyle
    let rowHeight: CGFloat
    /// Room above the first row, which the line runs up through.
    let lead: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let tinted = renderingMode != .fullColor
        Canvas { context, size in
            let h = rowHeight
            let x = size.width / 2
            let middle = { (row: CGFloat) in lead + row * h + h / 2 }
            let bar = { (top: CGFloat, bottom: CGFloat) in Path(CGRect(x: x - 2, y: top, width: 4, height: max(0, bottom - top))) }
            let circle = { (diameter: CGFloat, y: CGFloat) in
                Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
            }

            // The line continues above the list
            context.fill(bar(0, middle(0)), with: .linearGradient(
                Gradient(colors: [color.opacity(0), color]),
                startPoint: CGPoint(x: x, y: 0),
                endPoint: CGPoint(x: x, y: middle(0))
            ))
            for row in layout.rows.dropLast() {
                context.strokeRail(from: CGPoint(x: x, y: middle(CGFloat(row.id))),
                                   to: CGPoint(x: x, y: middle(CGFloat(row.id + 1))), color: color,
                                   dashed: row.kind == .folded || layout.rows[row.id + 1].kind == .folded)
            }
            let trainY = middle(layout.trainRow)
            context.fillBackground(bar(0, trainY), tinted: tinted, opacity: 0.62)

            for row in layout.rows where row.kind != .folded {
                let y = middle(CGFloat(row.id))
                if row.kind == .yours {
                    context.fillBackground(circle(style.ringSize, y), tinted: tinted)
                    context.stroke(circle(style.ringSize - 3, y), with: .color(Color.boardText), lineWidth: 3)
                } else {
                    var dot = context
                    dot.opacity = y < trainY - 1 ? 0.45 : 1
                    dot.fillBackground(circle(style.dotSize, y), tinted: tinted)
                    dot.fill(circle(style.dotSize / 2, y), with: .color(Color.boardText))
                }
            }
            // Room around the train, which can't have a background to part it from the rail
            if tinted {
                context.fillBackground(circle(style.markerSize + 4, trainY), tinted: true)
            }
        }
    }
}

extension GraphicsContext {
    /// A stretch of a map's line from `start` to `end`, 4 points wide: dashed
    /// beside folded stops.
    mutating func strokeRail(from start: CGPoint, to end: CGPoint, color: Color, dashed: Bool) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 4, dash: dashed ? [3, 3] : []))
    }

    /// Fills `path` with the widget's background, to part what's drawn over it
    /// from what's under it. Tinted and clear Home Screens draw the widget in
    /// one colour, keeping only how opaque each part is, so there (`tinted`)
    /// it's cut out instead.
    mutating func fillBackground(_ path: Path, tinted: Bool, opacity: Double = 1) {
        if tinted {
            var eraser = self
            eraser.blendMode = .destinationOut
            eraser.fill(path, with: .color(.black.opacity(opacity)))
        } else {
            fill(path, with: .color(Color.boardBackground.opacity(opacity)))
        }
    }
}

extension Text {
    /// A stop's name on the maps: yours bold, the one the train is at or
    /// heading for semibold, folded stops italic, and those the train has
    /// passed dimmed.
    func mapStop(_ font: Font, yours: Bool, trainStop: Bool, folded: Bool, passed: Bool) -> some View {
        self.font(font.weight(yours ? .bold : trainStop ? .semibold : .medium))
            .italic(folded)
            .foregroundStyle(yours || trainStop ? Color.boardText : passed ? Color.boardDim : Color.boardGray)
    }
}

/// The train on the rail: its line's bullet, or an outline of it while it's
/// still a timetable time.
struct TrainMarker: View {
    let route: String
    let isLive: Bool
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let style = LineStyle.of(route)
        if renderingMode == .fullColor {
            fullColor(style)
        } else if isLive {
            // Tinted and clear Home Screens draw a widget in one colour, which
            // would fill the bullet over its letter, so the letter is cut out
            // of it. The rail leaves room around it.
            Circle()
                .frame(width: size, height: size)
                .overlay(LineBullet.label(style, size: size).blendMode(.destinationOut))
                .compositingGroup()
                .widgetAccentable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Lines.spokenName(of: route))
        } else {
            // An outline, as LineBullet draws itself there
            LineBullet(route: route, size: size)
        }
    }

    private func fullColor(_ style: LineStyle) -> some View {
        let color = style.swiftUIColor
        return LineBullet.label(style, size: size)
            .foregroundStyle(isLive ? style.textColor : color)
            .frame(width: size, height: size)
            .background(Circle().fill(isLive ? color : Color.boardBackground))
            .overlay {
                if !isLive { Circle().strokeBorder(color, lineWidth: 1.5) }
            }
            // A ring of the widget's background parts it from the rail
            .background(Circle().fill(Color.boardBackground).padding(-2))
            .accessibilityLabel(Lines.spokenName(of: route))
    }
}
