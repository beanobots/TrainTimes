import SwiftUI

// Throwaway mockups: how saved routes are named and styled on the Routes tab.
// Delete once a direction is picked and built.

/// One saved route as the mockups show it.
private struct MockRoute: Identifiable {
    enum Mark { case train([String]), bus(String), bike }
    let id = UUID()
    /// The name typed, if any.
    var name: String?
    var mark: Mark
    /// "R from 4 Av-9 St"
    var what: String
    /// "to Manhattan", "change at DeKalb Av"
    var way: String
    /// Today's automatic name, for the Current mockup.
    var currentTitle: String
    var placed: Int
    var kind: String
    /// The countdown the card shows.
    var minutes: String
    var place: String
    var heading: String

    static let samples: [MockRoute] = [
        MockRoute(name: "Work", mark: .train(["R", "Q"]), what: "R from 4 Av-9 St", way: "change at DeKalb Av for the Q",
                  currentTitle: "Work", placed: 2, kind: "Subway", minutes: "4 min", place: "4 Av-9 St", heading: "Manhattan"),
        MockRoute(name: nil, mark: .train(["F", "G"]), what: "F G from 4 Av-9 St", way: "to Brooklyn",
                  currentTitle: "4 Av-9 St", placed: 0, kind: "Subway", minutes: "7 min", place: "4 Av-9 St", heading: "Coney Island"),
        MockRoute(name: nil, mark: .bus("B63"), what: "B63 from 5 Av/3 St", way: "to Cobble Hill",
                  currentTitle: "B63 · 5 Av/3 St", placed: 1, kind: "Bus", minutes: "11 min", place: "5 Av/3 St", heading: "Cobble Hill"),
        MockRoute(name: "Gym", mark: .bike, what: "Citi Bike at 5 Av & 3 St", way: "8 bikes · 3 e-bikes · 12 docks",
                  currentTitle: "Gym", placed: 0, kind: "Citi Bike", minutes: "8 · 3", place: "5 Av & 3 St", heading: "Bikes · E-Bikes"),
    ]

    /// The headline: the typed name, else what you ride and from where.
    var headline: String { name ?? what }
    /// Under it: with a typed name, what you ride; else the way.
    var subline: String { name == nil ? way : "\(what) · \(way)" }

    var placedText: String {
        switch placed {
        case 0: "Not on Home Screen yet"
        case 1: "On Home Screen"
        default: "On Home Screen ×\(placed)"
        }
    }
}

private struct MockMark: View {
    let mark: MockRoute.Mark
    var size: CGFloat = 20

    var body: some View {
        switch mark {
        case .train(let routes):
            HStack(spacing: 2) {
                ForEach(routes, id: \.self) { LineBullet(route: $0, size: size) }
            }
        case .bus(let line): BusBadge(line: line, size: size)
        case .bike: CitiBikeMark(size: size)
        }
    }
}

/// A stand-in for the medium Saved Route widget.
private struct MockCard: View {
    let route: MockRoute
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(spacing: 6) {
                MockMark(mark: route.mark, size: compact ? 18 : 22)
                Text(route.place).font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer()
            }
            Text(route.heading).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline) {
                Text(route.minutes).font(.system(size: compact ? 26 : 36, weight: .bold, design: .rounded))
                Spacer()
                Text("then 9 min").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 12 : 16)
        .frame(width: compact ? 150 : WidgetLook.medium.size.width,
               height: compact ? 110 : WidgetLook.medium.size.height)
        .background(RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// The tab bar, to show the tab's name.
private struct MockTabBar: View {
    let tab: String
    let icon: String

    var body: some View {
        HStack {
            item("Nearby", "circle.inset.filled", false)
            item("Navigate", "location.fill", false)
            item(tab, icon, true)
            item("Settings", "gearshape", false)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 20)
    }

    private func item(_ title: String, _ icon: String, _ on: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 18))
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(on ? Color.accentColor : .primary)
        .frame(maxWidth: .infinity)
    }
}

private struct MockAddButton: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "plus")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .glassEffect(.regular, in: Capsule())
    }
}

/// The wallpaper screen every option but C shares: cards with a caption under each.
private struct WallpaperScreen<Caption: View>: View {
    let tab: String
    let icon: String
    let add: String
    @ViewBuilder let caption: (MockRoute) -> Caption

    var body: some View {
        ZStack(alignment: .bottom) {
            WallpaperBackdrop().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(MockRoute.samples) { route in
                        VStack(spacing: 6) {
                            MockCard(route: route)
                            caption(route)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                                .frame(maxWidth: WidgetLook.medium.size.width)
                        }
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 140)
            }
            VStack(spacing: 10) {
                MockAddButton(title: add)
                MockTabBar(tab: tab, icon: icon)
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Current

#Preview("0 Current") {
    WallpaperScreen(tab: "Routes", icon: "point.topleft.down.to.point.bottomright.curvepath.fill", add: "New Route") { route in
        Text("\(route.currentTitle) · \(route.placed == 0 ? "Not placed" : "\(route.placed) placed")")
            .font(.caption.weight(.medium))
            .lineLimit(1)
    }
}

// MARK: - A: Routes, described

/// The name (or what you ride) with its mark, the way under it, and where it's placed.
#Preview("A Routes, described") {
    WallpaperScreen(tab: "Routes", icon: "point.topleft.down.to.point.bottomright.curvepath.fill", add: "New Route") { route in
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                MockMark(mark: route.mark, size: 16)
                Text(route.headline).font(.subheadline.weight(.semibold))
            }
            Text(route.subline).font(.caption)
            Text(route.placedText)
                .font(.caption2.weight(.medium))
                .opacity(route.placed == 0 ? 0.7 : 0.9)
        }
        .multilineTextAlignment(.center)
        .lineLimit(1)
    }
}

// MARK: - B: Widgets

/// Back to calling them widgets: the name, then size and whether it's placed.
#Preview("B Widgets") {
    WallpaperScreen(tab: "Widgets", icon: "square.grid.2x2.fill", add: "New Widget") { route in
        VStack(spacing: 2) {
            Text(route.name ?? route.place).font(.caption.weight(.semibold))
            Text("\(route.kind) · Medium · \(route.placed == 0 ? "Not on Home Screen" : "On Home Screen")")
                .font(.caption2)
                .opacity(0.85)
        }
        .lineLimit(1)
    }
}

// MARK: - C: Routes as a list

/// A list of routes, each a row with its mark, name and way, and a small widget beside it.
#Preview("C Routes list") {
    ZStack(alignment: .bottom) {
        List {
            ForEach(MockRoute.samples) { route in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        MockMark(mark: route.mark, size: 24)
                        Text(route.headline).font(.headline)
                        Text(route.subline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Label(route.placedText, systemImage: route.placed == 0 ? "plus.square.dashed" : "checkmark.square.fill")
                            .font(.caption)
                            .foregroundStyle(route.placed == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    }
                    Spacer(minLength: 0)
                    MockCard(route: route, compact: true)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color(.separator), lineWidth: 0.5))
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.insetGrouped)
        VStack(spacing: 10) {
            MockAddButton(title: "New Route")
            MockTabBar(tab: "Routes", icon: "point.topleft.down.to.point.bottomright.curvepath.fill")
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Setup words

/// The words in New/Edit Route that clash or still say widget, today and as A would have them.
#Preview("A Setup words") {
    let rows: [(String, String, String)] = [
        ("Bus step 2 title", "Route", "Bus"),
        ("Bus step 2 hint", "Pick the route to show", "Pick the bus to show"),
        ("Row VoiceOver hint", "Edit this widget", "Edit this route"),
        ("Pinned size menu", "Widget", "Preview As"),
        ("Size tiles", "Saved Route · Medium", "Saved Route · Medium (kept)"),
        ("New Trip button", "Show on Widget", "Show on Widget (kept: Magic Widget)"),
        ("Name field placeholder", "4 Av-9 St", "R from 4 Av-9 St"),
    ]
    return List {
        Section {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(row.1).strikethrough(row.1 != row.2 && !row.2.contains("kept"))
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(row.2).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }
            }
        } header: {
            Text("Today → A")
        }
    }
}
