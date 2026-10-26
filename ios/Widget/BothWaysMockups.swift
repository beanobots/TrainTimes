#if DEBUG
import SwiftUI
import WidgetKit

// Throwaway mockups: better ways for Next train to show both directions, at Prospect Av on the
// R. Delete once one is picked.

private enum MockWay {
    case manhattan, bayRidge

    var heading: String { self == .manhattan ? "Manhattan" : "Bay Ridge - 95 St" }
    var short: String { self == .manhattan ? "Manhattan" : "Bay Ridge" }
    var arrow: String { self == .manhattan ? "arrow.up" : "arrow.down" }
    /// Minutes to the next trains, their lines, and whether the first is live.
    var minutes: [Int] { self == .manhattan ? [4, 12, 20, 29, 37, 45] : [9, 18, 27, 36, 45, 54] }
    var routes: [String] { self == .manhattan ? ["N", "R", "R", "N", "R", "R"] : ["R", "R", "R", "R", "R", "R"] }
    var live: Bool { self == .manhattan }
    var clock: String { self == .manhattan ? "8:29" : "8:34" }
}

private struct MockBothEntry: TimelineEntry {
    let date: Date
    let index: Int
}

private struct MockBothProvider: TimelineProvider {
    func placeholder(in context: Context) -> MockBothEntry { MockBothEntry(date: .now, index: 0) }
    func getSnapshot(in context: Context, completion: @escaping (MockBothEntry) -> Void) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MockBothEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

// MARK: Pieces

private func countdown(_ way: MockWay, size: CGFloat) -> some View {
    HStack(spacing: 4) {
        Text("\(way.minutes[0]):00")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(way.live ? Color.liveText : Color.boardText)
        if way.live {
            LiveMark(size: size / 3).foregroundStyle(Color.liveText)
        }
    }
    .lineLimit(1)
    .fixedSize()
}

private func box<Content: View>(_ content: () -> Content) -> some View {
    content()
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
}

private func header(_ subtitle: String? = nil, tag: String) -> some View {
    HStack(spacing: 8) {
        LineBullet(route: "R", size: 24)
        Text("Prospect Av \(Text(subtitle ?? "").font(.footnote).foregroundStyle(Color.boardGray))")
            .font(.body.bold())
            .foregroundStyle(Color.boardText)
            .lineLimit(1)
        Spacer(minLength: 4)
        Text(tag)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.boardGray)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.boardButton))
    }
}

private func arrow(_ way: MockWay, size: CGFloat = 11) -> some View {
    Image(systemName: way.arrow)
        .font(.system(size: size, weight: .heavy))
        .foregroundStyle(Color.boardGray)
}

private func later(_ way: MockWay, from: Int = 1, count: Int = 2) -> String {
    way.minutes.dropFirst(from).prefix(count).map(String.init).joined(separator: " · ") + " min"
}

// MARK: A · Yours, with the other way under it

/// Your direction as the normal medium widget, a slim strip for the other way beneath.
private struct YoursPlusStrip: View {
    var yours: MockWay = .manhattan
    var tag = "A · Yours + strip"
    var note: String? = nil

    private var other: MockWay { yours == .manhattan ? .bayRidge : .manhattan }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(yours.short, tag: tag)
            box {
                HStack(spacing: 8) {
                    countdown(yours, size: 42)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            LineBullet(route: yours.routes[0], size: 18)
                            Text("leaves \(yours.clock)").font(.subheadline.weight(.semibold))
                        }
                        Text("then \(later(yours))").font(.caption).foregroundStyle(Color.boardGray)
                    }
                    .foregroundStyle(Color.boardText)
                }
            }
            HStack(spacing: 6) {
                arrow(other)
                Text(other.short).font(.caption.weight(.semibold)).foregroundStyle(Color.boardGray)
                LineBullet(route: other.routes[0], size: 14)
                Text(later(other, from: 0, count: 3))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.boardText)
                Spacer(minLength: 0)
                if let note {
                    Text(note).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.boardGray)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: B · Two rows

/// One row per direction, each its own box: where it goes on the left, countdown on the right.
private struct TwoRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(tag: "B · Two rows")
            row(.manhattan)
            row(.bayRidge)
        }
    }

    private func row(_ way: MockWay) -> some View {
        box {
            HStack(spacing: 8) {
                arrow(way, size: 13)
                VStack(alignment: .leading, spacing: 0) {
                    Text(way.short).font(.subheadline.weight(.semibold)).foregroundStyle(Color.boardText)
                    HStack(spacing: 3) {
                        LineBullet(route: way.routes[0], size: 12)
                        Text("then \(later(way))").font(.caption2).foregroundStyle(Color.boardGray)
                    }
                }
                Spacer(minLength: 0)
                countdown(way, size: 28)
            }
        }
    }
}

// MARK: D · Departure board

/// Both directions' trains in one list, soonest first, like a platform's board.
private struct DepartureBoard: View {
    private var rows: [(MockWay, Int)] {
        let all = [MockWay.manhattan, .bayRidge].flatMap { way in (0..<3).map { (way, $0) } }
        return all.sorted { $0.0.minutes[$0.1] < $1.0.minutes[$1.1] }.prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(tag: "D · Board")
            box {
                VStack(spacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        let (way, i) = row
                        HStack(spacing: 6) {
                            LineBullet(route: way.routes[i], size: 16)
                            arrow(way, size: 10)
                            Text(way.short)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.boardText)
                            Spacer(minLength: 0)
                            Text("\(way.minutes[i]) min")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(way.live && i == 0 ? Color.liveText : Color.boardText)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: E · Small, split

/// Small: the box split top and bottom, one direction in each.
private struct SmallSplit: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                LineBullet(route: "R", size: 20)
                Text("Prospect Av").font(.footnote.weight(.semibold)).foregroundStyle(Color.boardText).lineLimit(1)
            }
            half(.manhattan)
            half(.bayRidge)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("E").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.boardGray).offset(x: 6, y: 8)
        }
    }

    private func half(_ way: MockWay) -> some View {
        box {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    arrow(way, size: 9)
                    Text(way.short).font(.caption2.weight(.semibold)).foregroundStyle(Color.boardGray)
                }
                countdown(way, size: 26)
            }
        }
    }
}

// MARK: F · Large, two columns

/// Large: a column per direction, the countdown then the next few.
private struct LargeColumns: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LineBullet(route: "R", size: 30)
                Text("Prospect Av").font(.title3.bold()).foregroundStyle(Color.boardText)
                Spacer()
                Text("F · Large columns").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.boardGray)
            }
            HStack(spacing: 8) {
                column(.manhattan)
                column(.bayRidge)
            }
        }
    }

    private func column(_ way: MockWay) -> some View {
        box {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    arrow(way)
                    Text(way.heading).font(.footnote.weight(.semibold)).foregroundStyle(Color.boardGray).lineLimit(1)
                }
                countdown(way, size: 40)
                Divider()
                ForEach(1..<6) { i in
                    HStack(spacing: 6) {
                        LineBullet(route: way.routes[i], size: 18)
                        Text("\(way.minutes[i]) min")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(Color.boardText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
        }
    }
}

// MARK: Widget

private struct BothWaysMockups: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bothWaysMockups", provider: MockBothProvider()) { entry in
            Group {
                switch entry.index {
                case 0: YoursPlusStrip()
                case 1: TwoRows()
                // C: as A, but which way leads swaps with the time of day
                case 2: YoursPlusStrip(yours: .manhattan, tag: "C · Swaps, morning", note: "until 12 PM")
                case 3: YoursPlusStrip(yours: .bayRidge, tag: "C · Swaps, evening", note: "after 12 PM")
                case 4: DepartureBoard()
                case 5: SmallSplit()
                default: LargeColumns()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .containerBackground(Color.boardBackground, for: .widget)
        }
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview("Medium", as: .systemMedium) {
    BothWaysMockups()
} timeline: {
    MockBothEntry(date: .now, index: 0)
    MockBothEntry(date: .now, index: 1)
    MockBothEntry(date: .now, index: 2)
    MockBothEntry(date: .now, index: 3)
    MockBothEntry(date: .now, index: 4)
}

#Preview("Small", as: .systemSmall) {
    BothWaysMockups()
} timeline: {
    MockBothEntry(date: .now, index: 5)
}

#Preview("Large", as: .systemLarge) {
    BothWaysMockups()
} timeline: {
    MockBothEntry(date: .now, index: 6)
}
#endif
