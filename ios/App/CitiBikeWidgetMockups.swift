import SwiftUI

// Mockups only: Citi Bike as its own widget (Nearest Dock or a Favorite Dock), out of Saved Route.
// Delete once built.

// MARK: - Sample data

private struct MockDock: Hashable {
    var name: String
    var bikes: Int
    var eBikes: Int
    var docks: Int
    var walk: Int
}

private enum MockData {
    static let nearest = MockDock(name: "4 Av & 9 St", bikes: 3, eBikes: 1, docks: 22, walk: 2)
    static let favorite = MockDock(name: "5 Av & 3 St", bikes: 6, eBikes: 2, docks: 9, walk: 6)
    static let others = [
        MockDock(name: "5 Av & 3 St", bikes: 6, eBikes: 2, docks: 9, walk: 6),
        MockDock(name: "7 Av & 9 St", bikes: 11, eBikes: 4, docks: 3, walk: 7),
        MockDock(name: "Prospect Park West & 8 St", bikes: 14, eBikes: 2, docks: 12, walk: 9),
    ]
    static let nearFavorite = [
        MockDock(name: "4 Av & 9 St", bikes: 3, eBikes: 1, docks: 22, walk: 2),
        MockDock(name: "4 Av & 3 St", bikes: 0, eBikes: 1, docks: 17, walk: 3),
        MockDock(name: "7 Av & 9 St", bikes: 11, eBikes: 4, docks: 3, walk: 4),
    ]
}

/// Nearest Dock or a Favorite Dock.
private enum MockShow { case nearest, favorite }

// MARK: - Widget frame

private enum MockSize {
    case small, medium, large
    var size: CGSize {
        switch self {
        case .small: CGSize(width: 158, height: 158)
        case .medium: CGSize(width: 338, height: 158)
        case .large: CGSize(width: 338, height: 354)
        }
    }
}

/// A Home Screen widget's frame: its size, 16 pt margins, the app's background and corners.
private struct MockWidget<Content: View>: View {
    let size: MockSize
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(width: size.size.width, height: size.size.height, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.routeLook, true)
    }
}

/// A caption over a mock.
private struct MockLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Faces

/// Under the dock's name: "➤ Nearest · 2 min walk", or a favorite's walk.
private struct DockSubtitle: View {
    let show: MockShow
    let dock: MockDock
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 3) {
            if show == .nearest {
                Image(systemName: "location.fill").font(.caption2.bold())
                Text("Nearest · \(dock.walk) min walk")
            } else {
                Text("\(dock.walk) min walk")
            }
        }
        .font(font)
        .foregroundStyle(show == .nearest ? CitiBikeMark.blue : Color(.secondaryLabel))
        .lineLimit(1)
    }
}

private struct DockHeader: View {
    let show: MockShow
    let dock: MockDock
    let size: MockSize
    var closes = true

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CitiBikeMark(size: size == .small ? 22 : size == .large ? 30 : 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(dock.name)
                    .font(size == .small ? .footnote.bold() : .body.bold())
                    .lineLimit(size == .small ? 2 : 1)
                    .minimumScaleFactor(0.75)
                DockSubtitle(show: show, dock: dock, font: size == .small ? .caption2 : .caption)
            }
            Spacer(minLength: 0)
            if size != .small {
                Text("8:41")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if closes {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
        }
    }
}

private struct DockFace: View {
    let show: MockShow
    let size: MockSize

    private var dock: MockDock { show == .nearest ? MockData.nearest : MockData.favorite }
    private var list: [MockDock] { show == .nearest ? MockData.others : MockData.nearFavorite }
    private let columns = ["Bikes", "E-Bikes", "Docks"]

    private func count(_ dock: MockDock, _ column: String) -> Int {
        column == "Bikes" ? dock.bikes : column == "E-Bikes" ? dock.eBikes : dock.docks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 8 : 10) {
            DockHeader(show: show, dock: dock, size: size)
            if size == .small {
                BoardBox {
                    VStack(spacing: 4) {
                        ForEach(columns, id: \.self) { column in
                            HStack {
                                Text(column).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(count(dock, column))").font(.headline).monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(columns, id: \.self) { column in
                        VStack(spacing: 2) {
                            Text("\(count(dock, column))")
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(column).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(BoardTile())
                    }
                }
                .frame(maxHeight: size == .large ? 104 : .infinity)
                if size == .large { nearby }
            }
            if size == .large { Spacer(minLength: 0) }
        }
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(show == .nearest ? "Next nearest" : "Nearby docks")
                Spacer(minLength: 6)
                ForEach(columns, id: \.self) { Text($0).fixedSize().frame(width: 50) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(list, id: \.self) { other in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(other.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text("\(other.walk) min walk").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    ForEach(columns, id: \.self) { column in
                        Text("\(count(other, column))").font(.headline).monospacedDigit().frame(width: 50)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// The card until a tap: the dock (or "Nearest Dock" and the last one found), the mark along
/// the bottom.
private struct DockCard: View {
    let show: MockShow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if show == .nearest {
                Text("Nearest Dock").font(.headline)
                HStack(spacing: 3) {
                    Image(systemName: "location.fill").font(.caption2.bold())
                    Text("Where you are")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(MockData.favorite.name).font(.headline)
                Text("Citi Bike dock").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            CitiBikeMark(size: 44)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(CitiBikeMark.blue.opacity(0.14)))
    }
}

// MARK: - Faces page

private struct FacesMockup: View {
    let show: MockShow

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(show == .nearest ? "Citi Bike · Nearest Dock" : "Citi Bike · Favorite Dock")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                MockLabel(text: "Until tapped (card)")
                HStack(spacing: 14) {
                    MockWidget(size: .small) { DockCard(show: show) }
                    MockWidget(size: .small) { DockFace(show: show, size: .small) }
                }
                MockLabel(text: "Medium, opened")
                MockWidget(size: .medium) { DockFace(show: show, size: .medium) }
                MockLabel(text: "Large, opened")
                MockWidget(size: .large) { DockFace(show: show, size: .large) }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Widget gallery

private struct GalleryMockup: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Widget gallery: Leeway").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                page(name: "Magic Widget",
                     description: "Automatically updates to show your current trip on your Home Screen and makes it easy to see nearby departures or start a favorite trip.",
                     sizes: "Medium") {
                    HStack(spacing: 8) {
                        LineBullet(route: "R", size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("4 Av-9 St").font(.subheadline.bold())
                            Text("Manhattan").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                page(name: "Saved Route",
                     description: "Show a route you've saved in the app.",
                     sizes: "Small · Medium · Large · Lock Screen") {
                    HStack(spacing: 8) {
                        LineBullet(route: "R", size: 26)
                        BusBadge(line: "B63", size: 26)
                    }
                }
                page(name: "Citi Bike",
                     description: "Show a favorite dock or the one nearest you.",
                     sizes: "Small · Medium · Large · Lock Screen", isNew: true) {
                    HStack(spacing: 8) {
                        CitiBikeMark(size: 26)
                        Text("3 · 1 · 22 docks").font(.subheadline.weight(.semibold)).foregroundStyle(CitiBikeMark.blue)
                    }
                }
                page(name: "Nearby",
                     description: "The subway, buses and Citi Bike docks closest to you.",
                     sizes: "Large (unchanged)") {
                    Image(systemName: "location.fill").foregroundStyle(.blue)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func page(name: String, description: String, sizes: String, isNew: Bool = false,
                      @ViewBuilder sample: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            sample()
                .frame(width: 96, height: 72)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(.headline)
                    if isNew {
                        Text("NEW").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.green))
                    }
                }
                Text(description).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(sizes).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Edit Widget

/// iOS's Edit Widget panel: the widget's name and description, then its fields.
private struct EditPanel<Fields: View>: View {
    let title: String
    let description: String
    @ViewBuilder let fields: Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold())
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) { fields }
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct EditRow: View {
    let label: String
    let value: String
    var tint: Color = .blue
    var divider = false

    var body: some View {
        VStack(spacing: 0) {
            if divider { Divider().padding(.leading, 14) }
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(tint)
                Image(systemName: "chevron.up.chevron.down").font(.caption.bold()).foregroundStyle(tint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

private struct EditMockup: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                MockLabel(text: "Citi Bike · Show: Nearest Dock (no Dock row)")
                EditPanel(title: "Citi Bike", description: "Show a favorite dock or the one nearest you.") {
                    EditRow(label: "Show", value: "Nearest Dock")
                }
                MockLabel(text: "Citi Bike · Show: Favorite Dock")
                EditPanel(title: "Citi Bike", description: "Show a favorite dock or the one nearest you.") {
                    EditRow(label: "Show", value: "Favorite Dock")
                    EditRow(label: "Dock", value: "5 Av & 3 St", divider: true)
                }
                MockLabel(text: "Tapping Dock: every dock, nearest first, searchable")
                dockList
                MockLabel(text: "Saved Route · Kind is Subway / Bus only")
                EditPanel(title: "Saved Route", description: "Show a route you've saved in the app.") {
                    EditRow(label: "Kind", value: "Subway")
                    EditRow(label: "Route", value: "R from 4 Av-9 St", divider: true)
                }
                HStack(spacing: 8) {
                    ForEach(["Subway", "Bus"], id: \.self) { kind in
                        HStack {
                            if kind == "Subway" { Image(systemName: "checkmark").font(.caption.bold()) }
                            Text(kind)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                    Text("(Citi Bike removed)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var dockList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search Docks")
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 8)
            ForEach(Array(([MockData.nearest] + MockData.others).enumerated()), id: \.offset) { index, dock in
                if index > 0 { Divider() }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dock.name)
                        Text("\(dock.walk) min walk").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if dock.name == MockData.favorite.name {
                        Image(systemName: "checkmark").foregroundStyle(.blue).font(.body.bold())
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

// MARK: - Lock Screen

private struct LockMockup: View {
    var body: some View {
        VStack(spacing: 14) {
            MockLabel(text: "Lock Screen · Nearest Dock")
            rectangular(show: .nearest)
            inline("➤ 3 bikes · 4 Av & 9 St")
            MockLabel(text: "Lock Screen · Favorite Dock")
            rectangular(show: .favorite)
            inline("6 bikes · 5 Av & 3 St")
        }
        .padding(20)
        .background(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom))
    }

    private func rectangular(show: MockShow) -> some View {
        let dock = show == .nearest ? MockData.nearest : MockData.favorite
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if show == .nearest { Image(systemName: "location.fill").font(.caption2.bold()) }
                Image(systemName: "bicycle").font(.caption.bold())
                Text(dock.name).font(.headline).lineLimit(1)
            }
            HStack {
                ForEach([("\(dock.bikes)", "Bikes"), ("\(dock.eBikes)", "E-Bikes"), ("\(dock.docks)", "Docks")], id: \.1) { value in
                    VStack(spacing: 0) {
                        Text(value.0).font(.title3.bold()).monospacedDigit()
                        Text(value.1).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: 170, height: 76)
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func inline(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
    }
}

// MARK: - Routes tab

/// New Route's first page without Citi Bike.
private struct NewRouteMockup: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    tile("Subway", symbol: "tram.fill", tint: .black) {
                        HStack(spacing: 5) {
                            ForEach(["R", "D", "N"], id: \.self) { LineBullet(route: $0, size: 26) }
                        }
                    }
                    tile("Bus", symbol: "bus.fill", tint: BusBadge.blue) {
                        HStack(spacing: 5) {
                            ForEach(["B63", "B37"], id: \.self) { BusBadge(line: $0, size: 26) }
                        }
                    }
                    Text("Citi Bike docks are now their own widget. Add the Citi Bike widget from the Home Screen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New Route")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func tile(_ name: String, symbol: String, tint: Color, @ViewBuilder sample: () -> some View) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint))
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.title3.bold())
                sample()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Previews

#Preview("CB1 Gallery") { GalleryMockup() }
#Preview("CB2 Edit Widget") { EditMockup() }
#Preview("CB3 Nearest Dock") { FacesMockup(show: .nearest) }
#Preview("CB4 Favorite Dock") { FacesMockup(show: .favorite) }
#Preview("CB5 Lock Screen") { LockMockup() }
#Preview("CB6 New Route") { NewRouteMockup() }
