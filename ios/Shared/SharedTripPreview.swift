import SwiftUI
import WidgetKit

/// The Transit Directions widget as it will show `trip`, with its times now, fetched as in the
/// app's Widgets tab (`WidgetPreview`): in the Share sheet and the app's New Trip tab.
struct SharedTripPreview: View {
    let trip: SharedTrip
    @State private var board: SharedStore.SavedBoard?
    @State private var failed = false

    private let settings = SharedStore.loadSettings()

    var body: some View {
        TimelineView(.everyMinute) { context in
            TrainWidgetView(entry: entry(at: context.date))
        }
        .environment(\.boardFamily, .systemMedium)
        .environment(\.boardMargins, EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        .toggleStyle(.button)
        .frame(maxWidth: 338)
        .frame(height: 158)
        .background(Color.boardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .task(id: option) { await load() }
    }

    private var option: SharedTrip.Option { trip.option }

    private func entry(at date: Date) -> TrainEntry {
        let selection = option.selection
        let change = option.change
        guard let board else {
            return TrainEntry(date: date, selection: selection, trains: [],
                              problem: failed ? "Couldn't reach the MTA" : "Getting times…",
                              settings: settings, change: change, transfers: change != nil, tripSource: trip.source)
        }
        return TrainEntry(date: date, selection: selection,
                          trains: TimelinePlan.trains(board.trains, at: date, selection: selection,
                                                      fetched: board.fetched, keepsStops: false),
                          notice: board.notice, settings: settings,
                          connections: change == nil ? nil
                              : TimelinePlan.connections(board.connections ?? [], at: date, selection: selection,
                                                         fetched: board.fetched, keepsStops: false),
                          change: change, transfers: change != nil,
                          destination: option.directDestination, destinationTimes: board.destinationTimes ?? [:],
                          tripSource: trip.source)
    }

    /// Saved times for the trip at once, if any, then new ones once line taps pause.
    private func load() async {
        let option = self.option
        let selection = option.selection
        let destination = option.directDestination
        board = SharedStore.loadBoard(for: selection, change: option.change, destinationID: destination?.id)
        failed = false
        try? await Task.sleep(for: .seconds(0.4))
        guard !Task.isCancelled else { return }
        let alerts = selection.mentionsAlerts(with: settings)
        do {
            let fetched = if let change = option.change {
                try await TrainService.board(for: selection, change: change, includingAlerts: alerts,
                                             includingOutages: selection.elevatorAlerts)
            } else {
                try await TrainService.board(for: selection, arrivingAt: destination, includingAlerts: alerts,
                                             includingOutages: selection.elevatorAlerts)
            }
            guard !Task.isCancelled else { return }
            board = SharedStore.SavedBoard(fetched: .now, trains: fetched.trains,
                                           notice: fetched.notice(for: selection, settings: settings),
                                           connections: option.change == nil ? nil : fetched.connections,
                                           destinationTimes: destination == nil ? nil : fetched.destinationTimes)
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

/// One of the trips found for directions: its lines, where from and to, any change, and its
/// minutes door to door if known, with a checkmark when it's the one picked.
struct TripOptionRow: View {
    let option: SharedTrip.Option
    let picked: Bool
    var minutes: Int? = nil
    /// False where the picked row shows otherwise, as New Trip's highlight does.
    var checksPicked = true
    /// Whether to say if a change is across the platform or a walk, as New Trip does.
    var describesChange = false
    /// With `describesChange`, whether the change's stations are open to pick from, as New Trip
    /// opens them with a tap on the picked trip; nil where they don't open.
    var stationsOpen: Bool? = nil

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: option.selection.routes, size: 24)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                // Where from and to the row's whole width, the minutes on the line under it
                Text("\(option.selection.station?.name ?? "") → \(option.endStation?.name ?? "")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    details
                    Spacer(minLength: 0)
                    if let minutes {
                        Text("\(minutes) min")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if picked, checksPicked {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(stationsOpen == nil ? "" : stationsOpen == true ? "Hides the stations to change at"
                               : "Shows the stations to change at")
    }

    /// Under where from and to: any change, or which way the train goes.
    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let change = option.change, describesChange {
                // The station on a line of its own, as long names wrap, then the lines and how
                HStack(spacing: 4) {
                    Text(changeStations(change))
                    if let stationsOpen {
                        Image(systemName: stationsOpen ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                ChangeKindLabel(change: change, selection: option.selection)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let change = option.change {
                HStack(spacing: 4) {
                    Text("Change at \(change.stationNames(for: option.selection)) to")
                    LineBullets(routes: change.allRoutes, size: 14)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text(toward)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Which way its train goes, by where its lines end that way, as the train's own sign has it:
    /// "Toward Jamaica" for the F from 4 Av-9 St, rather than the platform's "Manhattan - Queens".
    /// The platform's name where they end in more than two places (the A's three branches).
    private var toward: String {
        let selection = option.selection
        guard let station = selection.station else { return selection.heading }
        let here = Set(station.platforms.map(\.id))
        var ends: [String] = []
        for route in selection.routes {
            let direction = selection.direction(of: route)
            for branch in StationDirectory.branches(of: route) where branch.contains(where: here.contains) {
                guard let id = direction == .north ? branch.first : branch.last, !here.contains(id),
                      let end = StationDirectory.station(id: id)?.platforms.first(where: { $0.id == id })?.short,
                      !ends.contains(end) else { continue }
                ends.append(end)
            }
        }
        guard !ends.isEmpty, ends.count <= 2 else { return selection.heading }
        return "Toward \(ends.joined(separator: " or "))"
    }

    /// Where it changes: "Change at Atlantic Av-Barclays Ctr"; where the stations open, how many
    /// there are ("Change at 2 stations") once there's more than one.
    private func changeStations(_ change: Change) -> String {
        let stations = Set(change.stops.compactMap { $0.station?.complex }).count
        return stationsOpen != nil && stations > 1 ? "Change at \(stations) stations"
            : "Change at \(change.stationNames(for: option.selection))"
    }
}

/// The lines a change is to, at any of its stations, and whether they're across the platform
/// (`Change.isAcross(_:from:)`) or a walk to another one; where only some are across, which.
struct ChangeKindLabel: View {
    let change: Change
    let selection: Selection

    var body: some View {
        let routes = change.allRoutes
        let across = routes.filter { route in
            change.stops.contains { $0.routes.contains(route) && $0.isAcross(route, from: selection) }
        }
        HStack(spacing: 4) {
            Image(systemName: across.isEmpty ? "figure.walk" : "arrow.left.arrow.right")
                .accessibilityHidden(true)
            if across.isEmpty || across.count == routes.count {
                bullets(routes)
                Text(across.isEmpty ? "a walk to another platform" : "across the platform")
            } else {
                bullets(across)
                Text("across the platform, others a walk")
            }
        }
        .lineLimit(1)
    }

    /// In a row, as three or more in `LineBullets` cluster too small to read at this size.
    private func bullets(_ routes: [String]) -> some View {
        HStack(spacing: 2) {
            ForEach(routes, id: \.self) { LineBullet(route: $0, size: 14) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Lines.list(routes))
    }
}
