#if DEBUG
import SwiftUI

// Mockups only: a Saved Route widget whose fastest way has two changes in a row
// (4 Av-9 St → Grand Central: R, Q at DeKalb Av, S at Times Sq), beside a one-change way
// (4 5 at Court St). Delete once built.

// MARK: - Sample trip

private struct MockLeg {
    /// The lines changed to, as good as each other.
    let lines: [String]
    let at: String
    /// Across the platform, else the walk's minutes.
    let walk: Int?
    /// Minutes until it leaves the change; past the first change, a clock time instead.
    let leavesIn: Int?
    let leavesAt: String
}

private struct MockRideWay {
    let changes: [MockLeg]
    let arrives: String
}

private let fastest = MockRideWay(changes: [
    MockLeg(lines: ["Q"], at: "DeKalb Av", walk: nil, leavesIn: 9, leavesAt: "8:52"),
    MockLeg(lines: ["S"], at: "Times Sq", walk: 4, leavesIn: nil, leavesAt: "9:14"),
], arrives: "9:18")

private let others: [MockRideWay] = [
    MockRideWay(changes: [MockLeg(lines: ["4", "5"], at: "Court St", walk: 3, leavesIn: 7, leavesAt: "8:50")],
                arrives: "9:21"),
    MockRideWay(changes: [
        MockLeg(lines: ["N"], at: "Atlantic Av", walk: nil, leavesIn: 6, leavesAt: "8:49"),
        MockLeg(lines: ["7"], at: "Times Sq", walk: 3, leavesIn: nil, leavesAt: "9:15"),
    ], arrives: "9:23"),
]

// MARK: - Pieces

private func mark(_ line: String, _ size: CGFloat) -> some View {
    LineBullet(route: line, size: size)
}

private func marks(_ lines: [String], _ size: CGFloat) -> some View {
    HStack(spacing: 2) { ForEach(lines, id: \.self) { mark($0, size) } }
}

/// Across the platform (train · walk · train), or the walker and minutes.
private func transfer(_ walk: Int?) -> some View {
    Group {
        if let walk {
            HStack(spacing: 3) {
                Image(systemName: "figure.walk")
                Text("\(walk) min")
            }
            .font(.subheadline.weight(.medium))
        } else {
            HStack(spacing: 1) {
                Image(systemName: "tram.fill")
                Image(systemName: "figure.walk")
                Image(systemName: "tram.fill")
            }
            .font(.footnote.weight(.semibold))
        }
    }
    .foregroundStyle(BoardInk.text)
    .fixedSize()
}

/// The countdown as the widgets draw it: big rounded digits, green when live.
private func countdown(_ text: String, size: CGFloat) -> some View {
    HStack(spacing: 4) {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.liveText)
        Image(systemName: "dot.radiowaves.up.forward")
            .font(.system(size: size / 3, weight: .bold))
            .foregroundStyle(Color.liveText)
    }
}

/// "Leaves in 9 min" for the first change, the clock time for later ones (further out, less sure).
private func leaves(_ leg: MockLeg, font: Font) -> some View {
    Group {
        if let leavesIn = leg.leavesIn {
            Text("\(leavesIn) min").font(font)
        } else {
            Text(leg.leavesAt).font(font).foregroundStyle(BoardInk.gray)
        }
    }
    .foregroundStyle(BoardInk.text)
    .monospacedDigit()
}

private func caption(_ text: String) -> some View {
    Text(text).font(.caption2.weight(.semibold)).foregroundStyle(BoardInk.gray)
}

// MARK: - Widget frame

private enum MockSize {
    case small, medium, large
    /// iPhone 18 Pro's widget sizes.
    var size: CGSize {
        switch self {
        case .small: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 364, height: 170)
        case .large: CGSize(width: 364, height: 382)
        }
    }
}

private struct MockWidget<Content: View>: View {
    let size: MockSize
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(width: size.size.width, height: size.size.height, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .environment(\.routeLook, true)
    }
}

/// The header: R, "4 Av-9 St → Grand Central", "Manhattan, via Q S".
private func header(medium: Bool) -> some View {
    HStack(spacing: 8) {
        mark("R", medium ? 24 : 30)
        VStack(alignment: .leading, spacing: 0) {
            Text("4 Av-9 St \(Text("→").foregroundStyle(BoardInk.gray)) Grand Central")
                .font(medium ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(BoardInk.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !medium {
                HStack(spacing: 3) {
                    Text("Manhattan, via")
                    ForEach(["Q", "S", "4", "5"], id: \.self) { mark($0, 14) }
                }
                .font(.footnote)
                .foregroundStyle(BoardInk.gray)
            }
        }
        Spacer(minLength: 4)
        Image(systemName: "figure.walk")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 30)
            .background(Capsule().fill(Color.accentColor))
    }
}

// MARK: - Small

/// The countdown, then the changes as a chain under it.
private struct SmallFace: View {
    var body: some View {
        MockWidget(size: .small) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    mark("R", 22)
                    Text("4 Av-9 St").font(.subheadline.weight(.semibold)).foregroundStyle(BoardInk.text)
                }
                countdown("4:12", size: 34)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    mark("R", 16)
                    Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(BoardInk.gray)
                    mark("Q", 16)
                    Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(BoardInk.gray)
                    mark("S", 16)
                }
                Text("Arrives 9:18").font(.caption).foregroundStyle(BoardInk.gray)
            }
        }
    }
}

// MARK: - Medium

/// Today's layout C, with the second change as a second row under the first.
private struct MediumRows: View {
    var body: some View {
        MockWidget(size: .medium) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    countdown("4:12", size: 30)
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        mark("R", 16)
                        Text("leaves 8:43").font(.subheadline.weight(.semibold)).foregroundStyle(BoardInk.text)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BoardTile())
                ForEach(Array(fastest.changes.enumerated()), id: \.offset) { index, leg in
                    HStack(spacing: 8) {
                        marks(leg.lines, 20)
                        VStack(alignment: .leading, spacing: 0) {
                            caption(index == 0 ? "Change at" : "Then at")
                            Text(leg.at).font(.footnote.weight(.semibold)).foregroundStyle(BoardInk.text)
                        }
                        Spacer(minLength: 4)
                        transfer(leg.walk).scaleEffect(0.9)
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 0) {
                            caption(leg.leavesIn == nil ? "Leaves at" : "Leaves in")
                            leaves(leg, font: .subheadline.weight(.semibold))
                        }
                        .frame(width: 62, alignment: .trailing)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 30)
                }
            }
        }
    }
}

/// The countdown box, then the trip as a strip: R — DeKalb Av — Q — Times Sq — S, each change's
/// leave under its place.
private struct MediumStrip: View {
    var body: some View {
        MockWidget(size: .medium) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    countdown("4:12", size: 30)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(spacing: 5) {
                            mark("R", 16)
                            Text("leaves 8:43").font(.subheadline.weight(.semibold)).foregroundStyle(BoardInk.text)
                        }
                        Text("arrives 9:18").font(.caption).foregroundStyle(BoardInk.gray)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BoardTile())
                JourneyStrip(way: fastest, size: 22)
                    .frame(height: 52)
            }
        }
    }
}

/// R ─ ● ─ Q ─ ● ─ S: the rides as bullets on a line, the changes as dots with the place, the
/// transfer and when the next ride leaves under each.
private struct JourneyStrip: View {
    let way: MockRideWay
    var size: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ride("R")
            ForEach(Array(way.changes.enumerated()), id: \.offset) { _, leg in
                stop(leg)
                ride(leg.lines.first ?? "")
            }
        }
    }

    private func ride(_ line: String) -> some View {
        mark(line, size)
            .frame(height: size)
    }

    private func stop(_ leg: MockLeg) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Rectangle().fill(BoardInk.gray.opacity(0.5)).frame(height: 2)
                Circle().fill(BoardInk.text).frame(width: 8, height: 8)
            }
            .frame(height: size)
            Text(leg.at).font(.caption.weight(.semibold)).foregroundStyle(BoardInk.text).lineLimit(1)
            HStack(spacing: 4) {
                transfer(leg.walk).scaleEffect(0.75)
                if let leavesIn = leg.leavesIn {
                    Text("· \(leavesIn) min")
                } else {
                    Text("· \(leg.leavesAt)")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(BoardInk.gray)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Large

/// Today's large table, each way's changes stacked in its row; the place's caption says which.
private struct LargeTable: View {
    var body: some View {
        MockWidget(size: .large) {
            VStack(alignment: .leading, spacing: 0) {
                header(medium: false)
                topCard.padding(.top, 10)
                HStack(spacing: 6) {
                    Text("Change at").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
                    Text("Transfer").frame(width: 66)
                    Text("Leaves").frame(width: 56, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(BoardInk.gray)
                .padding(.horizontal, 4)
                .padding(.top, 10)
                .padding(.bottom, 2)
                wayRows(fastest, fastest: true)
                wayRows(others[0], fastest: false)
            }
        }
    }

    private func wayRows(_ way: MockRideWay, fastest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(way.changes.enumerated()), id: \.offset) { index, leg in
                HStack(spacing: 6) {
                    marks(leg.lines, 22).frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(leg.at).font(.subheadline.weight(.semibold)).foregroundStyle(BoardInk.text)
                        if index == 0, fastest {
                            Text("Fastest · arrives \(way.arrives)").font(.caption.weight(.semibold))
                                .foregroundStyle(Color.liveText)
                        } else if index == 0 {
                            Text("Arrives \(way.arrives)").font(.caption).foregroundStyle(BoardInk.gray)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    transfer(leg.walk).frame(width: 66)
                    leaves(leg, font: index == 0 ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                        .frame(width: 56, alignment: .trailing)
                }
                .padding(.leading, index > 0 ? 12 : 0)
                .overlay(alignment: .leading) {
                    if index > 0 {
                        // "then": a hook from the change above
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(BoardInk.gray)
                            .offset(x: -2, y: -10)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }
}

/// The countdown card, then the fastest way as a journey strip in its own box, then the others
/// as one line each: their marks chained, arrival and when the first change leaves.
private struct LargeStrip: View {
    var body: some View {
        MockWidget(size: .large) {
            VStack(alignment: .leading, spacing: 0) {
                header(medium: false)
                topCard.padding(.top, 10)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fastest").font(.caption.weight(.semibold)).foregroundStyle(Color.liveText)
                        Spacer()
                        Text("arrives 9:18").font(.caption.weight(.semibold)).foregroundStyle(BoardInk.gray)
                    }
                    JourneyStrip(way: fastest, size: 24)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BoardTile())
                .padding(.top, 8)
                ForEach(Array(others.enumerated()), id: \.offset) { _, way in
                    otherRow(way)
                }
            }
        }
    }

    private func otherRow(_ way: MockRideWay) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                mark("R", 18)
                ForEach(Array(way.changes.enumerated()), id: \.offset) { _, leg in
                    Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(BoardInk.gray)
                    marks(leg.lines, 18)
                }
            }
            Text(way.changes.map(\.at).joined(separator: ", "))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(BoardInk.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text("arr \(way.arrives)").font(.caption).foregroundStyle(BoardInk.gray).monospacedDigit()
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
    }
}

/// The large widgets' countdown card: the countdown, then the R leaving and the next ones.
private var topCard: some View {
    HStack(spacing: 8) {
        countdown("4:12", size: 44)
        Spacer(minLength: 0)
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 5) {
                mark("R", 18)
                Text("leaves 8:43").font(.subheadline.weight(.semibold)).foregroundStyle(BoardInk.text)
            }
            Text("then 9, 17 min").font(.caption).foregroundStyle(BoardInk.gray)
        }
    }
    .padding(.horizontal, 14)
    .frame(height: 84)
    .background(BoardTile())
}

// MARK: - Home Screen

private struct HomeScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.72, green: 0.56, blue: 0.70)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) { content }
                .padding(.top, 20)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private func label(_ text: String) -> some View {
    Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white)
}

private func phone(_ view: some View, _ name: String) -> some View {
    view.previewDevice(PreviewDevice(rawValue: "iPhone 18 Pro")).previewDisplayName(name)
}

struct TwoChange1_Previews: PreviewProvider {
    static var previews: some View {
        phone(HomeScreen {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 6) { SmallFace(); label("Small") }
            }
            VStack(spacing: 6) { MediumRows(); label("Medium A · rows") }
            VStack(spacing: 6) { MediumStrip(); label("Medium B · strip") }
        }, "Two changes: small + medium")
    }
}

struct TwoChange2_Previews: PreviewProvider {
    static var previews: some View {
        phone(HomeScreen {
            VStack(spacing: 6) { LargeTable(); label("Large A · table") }
        }, "Two changes: large A")
    }
}

struct TwoChange3_Previews: PreviewProvider {
    static var previews: some View {
        phone(HomeScreen {
            VStack(spacing: 6) { LargeStrip(); label("Large B · strip") }
        }, "Two changes: large B")
    }
}
#endif
