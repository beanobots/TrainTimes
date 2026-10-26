#if DEBUG
import SwiftUI
import WidgetKit

// Throwaway mockups: Transit Directions' Nearby, a line's ways and Both, redone in the Direction
// step's chosen look (D · Tiles): each way a tile led by an arrow in the line's colour, its name,
// where it ends, and its next train. Four places for Both. Delete once picked and built.

private struct MockWay {
    let arrow: String
    let name: String
    let end: String
    let minutes: Int
    let then: Int
    let live: Bool
}

private let manhattan = MockWay(arrow: "arrow.up", name: "Manhattan", end: "Forest Hills-71 Av", minutes: 4, then: 12, live: true)
private let brooklyn = MockWay(arrow: "arrow.down", name: "Brooklyn", end: "Bay Ridge-95 St", minutes: 9, then: 18, live: false)
private let line = LineStyle.of("R")

/// The tile's fill, as the widget's other cards.
private let tileFill = Color.boardText.opacity(0.07)

/// An arrow in a disc of the line's colour, as D's tiles lead with.
private struct WayDisc: View {
    let symbol: String
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(line.textColor)
            .frame(width: size, height: size)
            .background(Circle().fill(line.swiftUIColor))
    }
}

/// "4 min", green with its mark when live.
private struct NextMinutes: View {
    let way: MockWay
    var size: CGFloat = 17

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(way.minutes)").font(.system(size: size, weight: .bold, design: .rounded))
            Text("min").font(.system(size: size * 0.6, weight: .semibold))
            if way.live { LiveMark(size: size * 0.45) }
        }
        .monospacedDigit()
        .foregroundStyle(way.live ? Color.liveText : Color.boardText)
    }
}

/// ‹ R Prospect Av, its walk below, then anything `trailing` and ✕: Nearby's header as now.
private struct MockHeader<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "chevron.left")
                .font(.caption.weight(.bold)).foregroundStyle(Color.boardGray).padding(.top, 3)
            LineBullet(route: "R", size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text("Prospect Av").font(.subheadline.bold()).foregroundStyle(Color.boardText)
                Text("0.1 mi · \(Image(systemName: "figure.walk")) 1 min")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Color.boardGray)
            }
            Spacer()
            trailing
            Pill(symbol: "xmark", large: true, round: true)
        }
    }
}

extension MockHeader where Trailing == EmptyView {
    init() { trailing = EmptyView() }
}

/// D's tile: the disc and next train along the top, the name, then where it ends.
private struct WayTile: View {
    let way: MockWay
    var showsThen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                WayDisc(symbol: way.arrow)
                Spacer(minLength: 4)
                NextMinutes(way: way)
            }
            Spacer(minLength: 2)
            Text(way.name)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.boardText)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(showsThen ? "\(way.end) · then \(way.then)" : way.end)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tileFill))
    }
}

// MARK: 1 · Tiles, Both a narrow tile

/// D as it is: two tiles, Both a slim third tile at the end with its own disc.
private struct TilesNarrowBoth: View {
    var body: some View {
        VStack(spacing: 8) {
            MockHeader()
            HStack(spacing: 8) {
                WayTile(way: manhattan)
                WayTile(way: brooklyn)
                VStack(spacing: 6) {
                    WayDisc(symbol: "arrow.up.arrow.down")
                    Text("Both").font(.caption.bold()).foregroundStyle(Color.boardText)
                }
                .frame(width: 52)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tileFill))
            }
        }
    }
}

// MARK: 2 · Tiles, Both a bar beneath

/// The tiles get the whole width; Both is a full-width bar under them, so it reads as "these two".
private struct TilesBothBar: View {
    var body: some View {
        VStack(spacing: 6) {
            MockHeader()
            HStack(spacing: 8) {
                WayTile(way: manhattan)
                WayTile(way: brooklyn)
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.heavy))
                Text("Both ways").font(.caption.bold())
            }
            .foregroundStyle(Color.boardText)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Capsule().fill(tileFill))
        }
    }
}

// MARK: 3 · Tiles, Both in the header

/// Both as a pill beside ✕, like the widget's other header buttons; the tiles have all the room.
private struct TilesBothPill: View {
    var body: some View {
        VStack(spacing: 8) {
            MockHeader {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.heavy))
                    Text("Both").font(.caption.bold())
                }
                .foregroundStyle(Color.boardText)
                .padding(.horizontal, 12)
                .frame(height: BoardStyle.large.buttonHeight)
                .background(Capsule().fill(Color.boardButton))
            }
            HStack(spacing: 8) {
                WayTile(way: manhattan, showsThen: true)
                WayTile(way: brooklyn, showsThen: true)
            }
        }
    }
}

// MARK: 4 · Rows, Both a bracket

/// Each way a full-width row, just as the Both board's Two Rows will look, and Both a tile down
/// the side holding them together: picking a row gets that way, the side gets the pair.
private struct RowsBothBracket: View {
    var bothWidth: CGFloat = 58
    /// "Both ways" on two lines under the disc, for the wider tiles.
    var saysWays = false

    var body: some View {
        VStack(spacing: 6) {
            MockHeader()
            HStack(spacing: 6) {
                VStack(spacing: 6) {
                    row(manhattan)
                    row(brooklyn)
                }
                VStack(spacing: 5) {
                    WayDisc(symbol: "arrow.up.arrow.down", size: saysWays ? 30 : 26)
                    Text(saysWays ? "Both\nways" : "Both")
                        .font(saysWays ? .subheadline.bold() : .caption.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.boardText)
                }
                .frame(width: bothWidth)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tileFill))
            }
        }
    }

    private func row(_ way: MockWay) -> some View {
        HStack(spacing: 8) {
            WayDisc(symbol: way.arrow, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(way.name).font(.subheadline.bold()).foregroundStyle(Color.boardText)
                Text(way.end).font(.caption2.weight(.semibold)).foregroundStyle(Color.boardGray).lineLimit(1)
            }
            Spacer(minLength: 4)
            NextMinutes(way: way, size: 20)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tileFill))
    }
}

// MARK: Preview widget

private struct MockWaysEntry: TimelineEntry {
    let date = Date.now
    let variant: Int
}

private struct MockWaysProvider: TimelineProvider {
    func placeholder(in context: Context) -> MockWaysEntry { MockWaysEntry(variant: 0) }
    func getSnapshot(in context: Context, completion: @escaping (MockWaysEntry) -> Void) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MockWaysEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

private struct WaysPickerMockups: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "waysPickerMockups", provider: MockWaysProvider()) { entry in
            Group {
                switch entry.variant {
                case 0: TilesNarrowBoth()
                case 1: TilesBothBar()
                case 2: TilesBothPill()
                case 3: RowsBothBracket()
                case 4: RowsBothBracket(bothWidth: 76)
                case 5: RowsBothBracket(bothWidth: 90, saysWays: true)
                default: RowsBothBracket(bothWidth: 104, saysWays: true)
                }
            }
            .containerBackground(Color.boardBackground, for: .widget)
        }
        .supportedFamilies([.systemMedium])
    }
}

/// One timeline, a variant per entry: 1 narrow Both tile, 2 Both bar, 3 Both pill, 4 rows + bracket.
#Preview("Ways and Both", as: .systemMedium) {
    WaysPickerMockups()
} timeline: {
    MockWaysEntry(variant: 0)
    MockWaysEntry(variant: 1)
    MockWaysEntry(variant: 2)
    MockWaysEntry(variant: 3)
    MockWaysEntry(variant: 4)
    MockWaysEntry(variant: 5)
    MockWaysEntry(variant: 6)
}
#endif
