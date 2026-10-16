import SwiftUI
import WidgetKit

/// The medium widget's other side, behind its map button: where the next train
/// is, as the stops between it and yours. The feed lists a trip's stops from the
/// one it's at or heading for, so the list starts there; more than `maxRows`
/// keep the first few and yours and fold the rest into one row. Given a
/// `height`, the rows spread out evenly to fill it.
struct StopList: View {
    let train: Arrival
    let now: Date
    var maxRows = 4
    var style = BoardStyle.compact
    var height: CGFloat? = nil

    private var spacing: CGFloat { style.isLarge ? 0 : 1 }

    /// Each row's share of `height` under the label, never less than the style's.
    private func rowHeight(rows: Int) -> CGFloat {
        guard let height, rows > 0 else { return style.rowHeight }
        let label = UIFont.preferredFont(forTextStyle: .caption2).lineHeight
        return max(style.rowHeight, floor((height - label - spacing) / CGFloat(rows)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let layout = StopLayout(train: train, now: now, maxRows: maxRows) {
                let rowHeight = rowHeight(rows: layout.rows.count)
                Text(layout.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(1)
                ZStack(alignment: .topLeading) {
                    StopRail(layout: layout, color: Color(hex: LineStyle.of(train.route).color), style: style, rowHeight: rowHeight)
                        .frame(width: style.railColumn, height: CGFloat(layout.rows.count) * rowHeight)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(layout.rows) { row in
                            stopRow(row, passed: CGFloat(row.id) < layout.trainRow, height: rowHeight)
                        }
                    }
                    TrainMarker(route: train.route, isLive: train.isLive, size: style.markerSize)
                        .offset(x: (style.railColumn - style.markerSize) / 2,
                                y: layout.trainRow * rowHeight + (rowHeight - style.markerSize) / 2)
                }
            } else {
                Text("WHERE IT IS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.boardGray)
                Text("The MTA hasn't said yet")
                    .font(style.stopFont)
                    .foregroundStyle(Color.boardGray)
            }
        }
    }

    private func stopRow(_ row: StopLayout.Row, passed: Bool, height: CGFloat) -> some View {
        HStack(spacing: style.isLarge ? 7 : 6) {
            // The rail's column
            Color.clear.frame(width: style.railColumn)
            Text(row.name)
                .font(style.stopFont.weight(row.kind == .yours ? .bold : row.isTrainStop ? .semibold : .medium))
                .italic(row.kind == .folded)
                .foregroundStyle(row.kind == .yours || row.isTrainStop ? Color.boardText : passed ? Color.boardDim : Color.boardGray)
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

/// Which stops the list shows, and where the train is among them: at most
/// `maxRows`, the first few and yours with the rest folded into one row.
struct StopLayout {
    enum Kind: Equatable {
        case stop, folded, yours
    }

    struct Row: Identifiable {
        /// Its place in the list, from the top.
        let id: Int
        let name: String
        let kind: Kind
        /// The stop the train is at or heading for.
        let isTrainStop: Bool
        /// When a train that hasn't set off leaves its first stop.
        let departs: Date?
    }

    let rows: [Row]
    /// Where the train is, in rows from the middle of the first: 0.5 is between
    /// the first two, and -0.5 is on its way to the first.
    let trainRow: CGFloat
    /// "7 STOPS AWAY", "NEXT STOP"
    let label: String

    /// `maxRows` is 3 or more.
    init?(train: Arrival, now: Date, maxRows: Int = 4) {
        let stops = train.approach
        guard let place = train.place(now: now), !stops.isEmpty else { return nil }
        let last = stops.count - 1
        // The stop it's at or heading for, and whether it's on its way there
        let (index, onTheWay): (Int, Bool) = switch place {
        case .starting: (0, false)
        case .at(let stop): (stop, false)
        case .approaching(let stop): (stop, true)
        }

        // From the stop it just left (or is at) down to yours; with only three
        // rows for a long way, from the stop it's heading for
        var first = onTheWay ? max(0, index - 1) : index
        if maxRows < 4, last - first + 1 > maxRows { first = index }
        var shown: [Int?] = (first...last).map { $0 }
        var folded = 0
        if shown.count > maxRows {
            let kept = maxRows - 2
            folded = shown.count - kept - 1
            shown = Array(shown.prefix(kept)) + [nil, last]
        }
        rows = shown.enumerated().map { row, stop in
            guard let stop else {
                return Row(id: row, name: folded == 1 ? "1 more stop" : "\(folded) more stops", kind: .folded, isTrainStop: false, departs: nil)
            }
            return Row(
                id: row,
                name: stops[stop].name,
                kind: stop == last ? .yours : .stop,
                isTrainStop: stop == index && stop != last,
                departs: place == .starting && stop == 0 ? stops[0].time : nil
            )
        }

        let target = CGFloat(shown.firstIndex(of: index) ?? 0)
        if onTheWay {
            trainRow = shown.firstIndex(of: index - 1).map { (CGFloat($0) + target) / 2 } ?? target - 0.5
        } else {
            trainRow = target
        }

        let away = last - index + (onTheWay ? 1 : 0)
        if onTheWay && index == last {
            label = "NEXT STOP"
        } else if away == 0 {
            label = "AT YOUR STOP"
        } else {
            label = away == 1 ? "1 STOP AWAY" : "\(away) STOPS AWAY"
        }
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
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        // Tinted and clear Home Screens draw the widget in one color, keeping
        // only how opaque each part is: there, what's filled with the widget's
        // background here is cut out of the rail instead
        let tinted = renderingMode != .fullColor
        Canvas { context, size in
            var eraser = context
            eraser.blendMode = .destinationOut
            let h = rowHeight
            let x = size.width / 2
            let middle = { (row: CGFloat) in row * h + h / 2 }
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
                let top = middle(CGFloat(row.id))
                let bottom = middle(CGFloat(row.id + 1))
                if row.kind == .folded || layout.rows[row.id + 1].kind == .folded {
                    var dashes = Path()
                    dashes.move(to: CGPoint(x: x, y: top))
                    dashes.addLine(to: CGPoint(x: x, y: bottom))
                    context.stroke(dashes, with: .color(color), style: StrokeStyle(lineWidth: 4, dash: [3, 3]))
                } else {
                    context.fill(bar(top, bottom), with: .color(color))
                }
            }
            let trainY = middle(layout.trainRow)
            if tinted {
                eraser.fill(bar(0, trainY), with: .color(.black.opacity(0.62)))
            } else {
                context.fill(bar(0, trainY), with: .color(Color.boardBackground.opacity(0.62)))
            }

            for row in layout.rows where row.kind != .folded {
                let y = middle(CGFloat(row.id))
                if row.kind == .yours {
                    if tinted {
                        eraser.fill(circle(style.ringSize, y), with: .color(.black))
                    } else {
                        context.fill(circle(style.ringSize, y), with: .color(Color.boardBackground))
                    }
                    context.stroke(circle(style.ringSize - 3, y), with: .color(Color.boardText), lineWidth: 3)
                } else {
                    var dot = context
                    dot.opacity = y < trainY - 1 ? 0.45 : 1
                    if tinted {
                        var hole = eraser
                        hole.opacity = dot.opacity
                        hole.fill(circle(style.dotSize, y), with: .color(.black))
                    } else {
                        dot.fill(circle(style.dotSize, y), with: .color(Color.boardBackground))
                    }
                    dot.fill(circle(style.dotSize / 2, y), with: .color(Color.boardText))
                }
            }
            // Room for the train's outline, which can't have a background to part it from the rail
            if tinted {
                eraser.fill(circle(style.markerSize + 4, trainY), with: .color(.black))
            }
        }
    }
}

/// The train on the rail: its line's bullet, or an outline of it while it's
/// still a timetable time.
private struct TrainMarker: View {
    let route: String
    let isLive: Bool
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let style = LineStyle.of(route)
        if renderingMode == .fullColor {
            fullColor(style)
        } else {
            // As LineBullet is on tinted and clear Home Screens: filled, it would
            // be one disc with no letter. The rail leaves room around it.
            label(style)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(lineWidth: 1.5))
                .widgetAccentable()
                .accessibilityLabel("\(style.label) train")
        }
    }

    private func label(_ style: LineStyle) -> some View {
        let fontSize = size * (style.label.count > 1 ? 0.45 : 0.62)
        return Text(style.label)
            .font(.system(size: fontSize, weight: .bold))
            .offset(y: -LineBullet.capitalsOffset(fontSize: fontSize))
    }

    private func fullColor(_ style: LineStyle) -> some View {
        let color = Color(hex: style.color)
        return label(style)
            .foregroundStyle(isLive ? (style.usesDarkText ? Color.black : Color.white) : color)
            .frame(width: size, height: size)
            .background(Circle().fill(isLive ? color : Color.boardBackground))
            .overlay {
                if !isLive { Circle().strokeBorder(color, lineWidth: 1.5) }
            }
            // A ring of the widget's background parts it from the rail
            .background(Circle().fill(Color.boardBackground).padding(-2))
            .accessibilityLabel("\(style.label) train")
    }
}
