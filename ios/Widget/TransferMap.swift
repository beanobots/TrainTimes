import SwiftUI
import WidgetKit

/// The large widget's other side for a change, behind its map button: your
/// train's stops on the way to the change, its track down the left, and beside
/// it the track of the lines changed to. Each train is drawn where it would be
/// by how long it has to go to the change, so two that meet with little wait
/// ride side by side.
struct TransferMap: View {
    let connection: Connection
    let selection: Selection
    let change: Change
    let now: Date

    private var style: BoardStyle { .large }

    /// The tracks' column, and where each runs down it.
    static let railsWidth: CGFloat = 52
    static let localX: CGFloat = 13
    static let otherX: CGFloat = 41
    /// Below the last row: where trains still on their way to it are.
    static let tail: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            labels
            if let layout = TransferMapLayout(connection: connection, selection: selection, now: now) {
                GeometryReader { geometry in
                    let rowHeight = min(36, max(20, (geometry.size.height - Self.tail) / CGFloat(layout.rows.count)))
                    diagram(layout, rowHeight: rowHeight)
                }
            } else {
                Text("The MTA hasn't said yet")
                    .font(style.stopFont)
                    .foregroundStyle(Color.boardGray)
            }
        }
    }

    private var localColor: Color { Color(hex: LineStyle.of(selection.firstRoute).color) }

    /// A line for each colour of the lines changed to: the D's orange and the N's yellow.
    private var otherColors: [Color] {
        var colors: [UInt32] = []
        for route in change.routes where !colors.contains(LineStyle.of(route).color) {
            colors.append(LineStyle.of(route).color)
        }
        return colors.prefix(3).map { Color(hex: $0) }
    }

    /// "WHERE THEY ARE", and which track is which: local and express, or their lines.
    private var labels: some View {
        let express = change.isExpress(for: selection)
        return HStack(spacing: 5) {
            Text("WHERE THEY ARE")
            Spacer(minLength: 8)
            swatch([localColor], width: 4)
            Text(express ? "LOCAL" : selection.routes.map { LineStyle.of($0).label }.joined(separator: " "))
            swatch(otherColors, width: 3)
                .padding(.leading, 6)
            Text(express ? "EXPRESS" : change.routes.map { LineStyle.of($0).label }.joined(separator: " "))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.boardGray)
        .lineLimit(1)
    }

    private func swatch(_ colors: [Color], width: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: width, height: 11)
            }
        }
        .accessibilityHidden(true)
    }

    private func diagram(_ layout: TransferMapLayout, rowHeight: CGFloat) -> some View {
        let middle = { (row: CGFloat) in row * rowHeight + rowHeight / 2 }
        let marker = style.markerSize
        return ZStack(alignment: .topLeading) {
            TransferRails(layout: layout, rowHeight: rowHeight, localColor: localColor, otherColors: otherColors)
                .frame(width: Self.railsWidth, height: CGFloat(layout.rows.count) * rowHeight + Self.tail)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(layout.rows) { row in
                    rowLabel(row, layout: layout)
                        .frame(height: rowHeight)
                }
                if let note = layout.nextNote {
                    Text(note)
                        .font(.caption.italic())
                        .foregroundStyle(Color.boardGray)
                        .lineLimit(1)
                        .frame(height: Self.tail)
                }
            }
            .padding(.leading, Self.railsWidth + 10)
            if let row = layout.nextRow, let next = connection.next {
                TrainMarker(route: next.route, isLive: next.isLive, size: marker)
                    .offset(x: Self.otherX - marker / 2, y: middle(row) - marker / 2)
            }
            TrainMarker(route: connection.first.route, isLive: connection.first.isLive, size: marker)
                .offset(x: Self.localX - marker / 2, y: middle(layout.firstRow) - marker / 2)
        }
    }

    /// A stop's name and when your train is due there; the change's also has
    /// when the train it meets leaves, and the wait between.
    @ViewBuilder
    private func rowLabel(_ row: TransferMapLayout.Row, layout: TransferMapLayout) -> some View {
        // Stops it has passed are dimmed; the one it's at or heading for stands out
        let passed = CGFloat(row.id) > layout.firstRow + 0.01
        let isTrainStop = row.id == min(layout.rows.count - 1, Int(layout.firstRow.rounded(.down)))
        switch row.kind {
        case .change:
            changeLabel(row)
        case .folded:
            Text(row.name)
                .font(style.stopFont.italic())
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
        case .origin, .stop:
            let yours = row.kind == .origin
            HStack(spacing: 4) {
                Text(row.name)
                    .font(style.stopFont.weight(yours ? .bold : isTrainStop ? .semibold : .medium))
                    .foregroundStyle(yours || isTrainStop ? Color.boardText : passed ? Color.boardDim : Color.boardGray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(row.time.clock)
                    .font(yours ? style.departsFont : .footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(yours ? connection.first.statusColor : passed ? Color.boardDim : Color.boardGray)
            }
        }
    }

    /// The change's name, then your train getting there, the wait, and the
    /// train it meets leaving.
    private func changeLabel(_ row: TransferMapLayout.Row) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.boardText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(spacing: 4) {
                LineBullet(route: connection.arrival.route, size: 13)
                Text(connection.arrival.time.clock)
                    .foregroundStyle(connection.arrival.statusColor)
                if let next = connection.next {
                    waitPill
                    LineBullet(route: next.route, size: 13)
                    Text(next.time.clock)
                        .foregroundStyle(next.statusColor)
                }
            }
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    /// The wait, small, and filled when it's short enough to highlight.
    private var waitPill: some View {
        let quick = connection.isQuick(within: change.quickMinutes)
        return Text(connection.waitLabel)
            .font(.caption2.weight(.bold))
            .foregroundStyle(quick ? Color.boardBackground : Color.boardGray)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background {
                if quick { Capsule().fill(Color.boardText) }
            }
            .widgetAccentable(quick)
    }
}

/// Which stops the map shows, top to bottom from the change, and where the two
/// trains are among them, in rows from the middle of the first.
struct TransferMapLayout {
    enum Kind: Equatable {
        case change, origin, stop, folded
    }

    struct Row: Identifiable {
        /// Its place in the list, from the top.
        let id: Int
        let name: String
        let kind: Kind
        /// When your train is due there; for folded stops, midway between them.
        let time: Date
        /// The train it meets stops here too.
        let shared: Bool
    }

    let rows: [Row]
    /// Where your train is: 0 at the change, 1.5 midway between the second and
    /// third rows, and past the last row while it's on its way to it.
    let firstRow: CGFloat
    /// Where the train it meets would be on your train's way with as long to
    /// go to the change; nil without one.
    let nextRow: CGFloat?
    /// Where the train it meets is, when it's further off than the map shows:
    /// "D at 9 Av".
    let nextNote: String?

    /// `maxRows` is 4 or more.
    init?(connection: Connection, selection: Selection, now: Date, maxRows: Int = 6) {
        let stops = connection.arrival.approach
        let yours = Set(selection.stopIDs)
        guard let origin = stops.firstIndex(where: { yours.contains($0.id) }), origin < stops.count - 1 else { return nil }
        let last = stops.count - 1

        // The change at the top, then the stops between it and yours, yours, the
        // stops between yours and where the train is, and that. When there are
        // too many, the longer of the runs between folds into one row, then
        // the other.
        let between = Array((origin + 1)..<last)
        let before = origin > 1 ? Array(1..<origin) : []
        let room = maxRows - (origin > 0 ? 3 : 2)
        var foldBetween = false
        var foldBefore = false
        var shown = between.count + before.count
        for run in [between, before].sorted(by: { $0.count > $1.count }) where shown > room && run.count >= 2 {
            if run == between { foldBetween = true } else { foldBefore = true }
            shown -= run.count - 1
        }
        var groups: [[Int]] = [[last]]
        groups += foldBetween ? [Array(between.reversed())] : between.reversed().map { [$0] }
        groups.append([origin])
        groups += foldBefore ? [Array(before.reversed())] : before.reversed().map { [$0] }
        if origin > 0 { groups.append([0]) }

        // Stations the train it meets calls at on its way, where the two share a platform
        let station = { (stop: String) in StationDirectory.station(id: String(stop.dropLast()))?.id }
        let theirs = Set((connection.next?.approach ?? []).compactMap { station($0.id) })

        let rows = groups.enumerated().map { (index, group) -> Row in
            if group.count > 1 {
                let times = group.map { stops[$0].time.timeIntervalSince1970 }
                let middle = Date(timeIntervalSince1970: ((times.min() ?? 0) + (times.max() ?? 0)) / 2)
                return Row(id: index, name: "\(group.count) more stops", kind: .folded, time: middle, shared: false)
            }
            let stop = group[0]
            let kind: Kind = stop == last ? .change : stop == origin ? .origin : .stop
            let shared = stop == last || (station(stops[stop].id).map(theirs.contains) ?? false)
            return Row(id: index, name: stops[stop].name, kind: kind, time: stops[stop].time, shared: shared)
        }
        self.rows = rows
        firstRow = Self.row(at: now, in: rows)

        if let next = connection.next {
            // Your train gets to the change at the top row's time; the train it
            // meets is where yours would be with as long to go
            let row = Self.row(at: connection.arrival.time.addingTimeInterval(-next.time.timeIntervalSince(now)), in: rows)
            nextRow = row
            nextNote = row > CGFloat(rows.count - 1) ? Self.note(for: next, now: now) : nil
        } else {
            nextRow = nil
            nextNote = nil
        }
    }

    /// Where your train is at `time`: between two rows by how far it has come
    /// from one to the next, or below the last while it's on its way there.
    private static func row(at time: Date, in rows: [Row]) -> CGFloat {
        guard let top = rows.first, time < top.time else { return 0 }
        for index in rows.indices.dropLast() where time >= rows[index + 1].time {
            let upper = rows[index].time
            let lower = rows[index + 1].time
            let span = upper.timeIntervalSince(lower)
            let fraction = span > 0 ? upper.timeIntervalSince(time) / span : 0
            return CGFloat(index) + CGFloat(min(1, max(0, fraction)))
        }
        return CGFloat(rows.count - 1) + 0.6
    }

    /// "D at 36 St", "D heading for 36 St"
    private static func note(for train: Arrival, now: Date) -> String? {
        guard let place = train.place(now: now) else { return nil }
        switch place {
        case .starting:
            return train.approach.first.map { "\(train.lineLabel) starting at \($0.name)" }
        case .at(let index):
            return "\(train.lineLabel) at \(train.approach[index].name)"
        case .approaching(let index):
            return "\(train.lineLabel) heading for \(train.approach[index].name)"
        }
    }
}

/// The two tracks: your train's down the left, dashed past folded stops, with a
/// dot at each stop and a ring at yours; beside it a line for each colour of the
/// lines changed to; and a platform's outline across both where they stop
/// together. Both fade out below the last row, where trains come from.
private struct TransferRails: View {
    let layout: TransferMapLayout
    let rowHeight: CGFloat
    let localColor: Color
    let otherColors: [Color]
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        // Tinted and clear Home Screens draw the widget in one color, keeping
        // only how opaque each part is: there, what's filled with the widget's
        // background here is cut out of the tracks instead
        let tinted = renderingMode != .fullColor
        Canvas { context, size in
            var eraser = context
            eraser.blendMode = .destinationOut
            let h = rowHeight
            let middle = { (row: CGFloat) in row * h + h / 2 }
            let top = middle(0)
            let bottom = middle(CGFloat(layout.rows.count - 1))
            let localX = TransferMap.localX
            let bar = { (x: CGFloat, width: CGFloat, from: CGFloat, to: CGFloat) in
                Path(CGRect(x: x - width / 2, y: from, width: width, height: max(0, to - from)))
            }
            let circle = { (x: CGFloat, y: CGFloat, diameter: CGFloat) in
                Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
            }

            for row in layout.rows.dropLast() {
                let from = middle(CGFloat(row.id))
                let to = middle(CGFloat(row.id + 1))
                if row.kind == .folded || layout.rows[row.id + 1].kind == .folded {
                    var dashes = Path()
                    dashes.move(to: CGPoint(x: localX, y: from))
                    dashes.addLine(to: CGPoint(x: localX, y: to))
                    context.stroke(dashes, with: .color(localColor), style: StrokeStyle(lineWidth: 4, dash: [3, 3]))
                } else {
                    context.fill(bar(localX, 4, from, to), with: .color(localColor))
                }
            }
            context.fill(bar(localX, 4, bottom, size.height), with: Self.fading(localColor, x: localX, from: bottom, to: size.height))

            let count = CGFloat(otherColors.count)
            for (index, color) in otherColors.enumerated() {
                let x = TransferMap.otherX - (count * 5 - 2) / 2 + 1.5 + CGFloat(index) * 5
                context.fill(bar(x, 3, top, bottom), with: .color(color))
                context.fill(bar(x, 3, bottom, size.height), with: Self.fading(color, x: x, from: bottom, to: size.height))
            }

            for row in layout.rows where row.kind != .folded {
                let y = middle(CGFloat(row.id))
                if row.shared {
                    let outline = CGRect(x: 3, y: y - 9, width: TransferMap.railsWidth - 4, height: 18)
                    let platform = Path(roundedRect: outline, cornerRadius: 9)
                    if tinted {
                        eraser.fill(platform, with: .color(.black))
                    } else {
                        context.fill(platform, with: .color(Color.boardBackground))
                    }
                    context.stroke(Path(roundedRect: outline.insetBy(dx: 1.25, dy: 1.25), cornerRadius: 7.75),
                                   with: .color(Color.boardText), lineWidth: 2.5)
                } else if row.kind == .origin {
                    if tinted {
                        eraser.fill(circle(localX, y, 16), with: .color(.black))
                    } else {
                        context.fill(circle(localX, y, 16), with: .color(Color.boardBackground))
                    }
                    context.stroke(circle(localX, y, 13), with: .color(Color.boardText), lineWidth: 3)
                } else {
                    context.fill(circle(localX, y, 8), with: .color(Color.boardText))
                }
            }

            // Room for the trains' outlines, which can't have a background to part them from the tracks
            if tinted {
                let room = BoardStyle.large.markerSize + 4
                eraser.fill(circle(localX, middle(layout.firstRow), room), with: .color(.black))
                if let row = layout.nextRow {
                    eraser.fill(circle(TransferMap.otherX, middle(row), room), with: .color(.black))
                }
            }
        }
    }

    private static func fading(_ color: Color, x: CGFloat, from: CGFloat, to: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [color, color.opacity(0)]),
                        startPoint: CGPoint(x: x, y: from), endPoint: CGPoint(x: x, y: to))
    }
}
