import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

/// The Nearby tab: next trains for every line at nearby stations.
struct LiveView: View {
    /// Set when the Nearby widget's "allow location" link opens the app.
    @Binding var allowingLocation: Bool
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var location = NearbyLocation()
    @State private var path = NavigationPath()
    @State private var live = LiveTrains()
    /// A map-picked place Nearby uses instead of your location, until Near Me is tapped.
    @State private var pin: CLLocation?
    @State private var droppingPin = false
    /// Closest stations to `here`, nearest first. Recomputed only when `here` changes,
    /// not on every redraw.
    @State private var nearby: [Nearby.Result] = []

    /// The pin, or else your location.
    private var here: CLLocation? { pin ?? location.location }

    /// Clears the pin and re-locates, even if you haven't moved. Times reload once
    /// the nearby stations change.
    private func findLocation() {
        pin = nil
        location.find()
        Task { await load() }
    }

    /// Every nearby station's trains, fetched together.
    private var everyTrain: [Selection] {
        nearby.flatMap(\.station.lineSelections)
    }

    private var marks: TimeMarks { settings.timeMarks(withoutColor: withoutColor) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                nearbySections
                if !SharedStore.isAvailable {
                    Section {
                        Label("The widget can't see your choice on this install, so it keeps showing Prospect Av (R) toward Manhattan.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } footer: {
                        Text("The shared storage the app and widget use wasn't set up when this was installed. Make sure the app and widget both have the App Group in Xcode, then reinstall.")
                    }
                }
            }
            // Lets the station name rows sit shorter than the standard 44pt row
            .environment(\.defaultMinListRowHeight, 0)
            .navigationDestination(for: Selection.self) { selection in
                TrainDetail(selection: selection)
                    // Fresh identity per train; otherwise a page replaced in place would keep
                    // the previous train's state
                    .id(selection.trainID)
            }
            // The same gap between station cards as between the Widgets tab's cards
            .listSectionSpacing(16)
            // No header above the first card, so start it just under the toolbar
            .contentMargins(.top, 8, for: .scrollContent)
            // Inline, level with the location buttons, so the first card stays near the top;
            // when times last loaded beneath it
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(live.updated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            // Location prompts and messages, centred where the station cards would be
            .overlay {
                if !showsStations || nearby.isEmpty {
                    emptyState
                }
            }
            // While pinned, says so above the tab bar, with a way back to your location
            .safeAreaBar(edge: .bottom) {
                if pin != nil {
                    pinnedBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: pin != nil)
            .toolbar {
                // The filled icon is the place the list is for; tapping the arrow clears a pin
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Near Me", systemImage: pin == nil && location.isAllowed ? "location.fill" : "location",
                           action: findLocation)
                        .accessibilityHint("Finds stations near where you are now")
                    Button("Drop Pin", systemImage: pin == nil ? "mappin" : "mappin.circle.fill") { droppingPin = true }
                        .accessibilityHint("Drops a pin on the map to find stations near it")
                }
            }
            .sheet(isPresented: $droppingPin) {
                DropPinSheet(start: (pin ?? location.location)?.coordinate) { pin = $0 }
                    // A floating glass sheet at half height, Nearby still showing above it
            }
            .onAppear { location.start() }
            .onChange(of: allowingLocation, initial: true) { _, allowing in
                guard allowing else { return }
                allowingLocation = false
                path = NavigationPath()
                if location.status == .denied || location.status == .restricted,
                   let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                } else {
                    findLocation()
                }
            }
            .onChange(of: here, initial: true) { _, here in
                nearby = here.map { Nearby.stations(near: $0, limit: 3) } ?? []
            }
            // Reload every minute and when the train list changes; pull-to-refresh and
            // returning to the app also re-locate (unless pinned)
            .updatingTrains(live, id: everyTrain.map(\.trainID), refreshing: {
                if location.isAllowed && pin == nil { location.find() }
            }, load: load)
        }
    }

    /// Any failure note, then a card per station near the pin or you.
    @ViewBuilder private var nearbySections: some View {
        if live.anyFailed(everyTrain) {
            Section {
                UnreachableNote(timetable: live.anyFromTimetable(everyTrain))
            }
        }
        if showsStations {
            ForEach(nearby) { result in
                Section {
                    NearbyStationRow(result: result)
                    ForEach(result.station.routes, id: \.self) { route in
                        NearbyLineRow(station: result.station, route: route, live: live, marks: marks) { path.append($0) }
                    }
                }
            }
        }
    }

    /// Whether there's a place to list stations near: the pin, or your location once found.
    private var showsStations: Bool {
        pin != nil || (location.isAllowed && !location.failed && location.location != nil)
    }

    /// Why there are no station cards, with what to do about it.
    @ViewBuilder private var emptyState: some View {
        if pin != nil {
            ContentUnavailableView {
                Label("No Stations Nearby", systemImage: "mappin.slash")
            } description: {
                Text("No stations within \(Nearby.rangeDescription) of the pin.")
            } actions: {
                Button("Move the Pin") { droppingPin = true }
                    .buttonStyle(.glassProminent)
            }
        } else if location.status == .notDetermined {
            ContentUnavailableView {
                Label("Trains Near You", systemImage: "location.fill")
            } description: {
                Text("See the next trains at the stations closest to you, or drop a pin anywhere.")
            } actions: {
                Button("Allow Location") { location.find() }
                    .buttonStyle(.glassProminent)
                Button("Drop a Pin") { droppingPin = true }
            }
        } else if !location.isAllowed {
            ContentUnavailableView {
                Label("Location Is Off", systemImage: "location.slash")
            } description: {
                Text("Turn on Location for Leeway in Settings, or drop a pin to see trains near somewhere else.")
            } actions: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Turn On in Settings", destination: url)
                        .buttonStyle(.glassProminent)
                }
                Button("Drop a Pin") { droppingPin = true }
            }
        } else if location.failed {
            ContentUnavailableView {
                Label("Couldn't Find You", systemImage: "location.slash")
            } description: {
                Text("Your location isn't available right now.")
            } actions: {
                Button("Try Again") { location.find() }
                    .buttonStyle(.glassProminent)
            }
        } else if location.location == nil {
            ProgressView("Finding stations near you…")
        } else {
            ContentUnavailableView {
                Label("No Stations Nearby", systemImage: "tram")
            } description: {
                Text("No stations within \(Nearby.rangeDescription) of you.")
            } actions: {
                Button("Drop a Pin") { droppingPin = true }
            }
        }
    }

    /// "Near the dropped pin" in a glass capsule: tap to move the pin, or ✕ to go back to
    /// your location.
    private var pinnedBar: some View {
        HStack(spacing: 4) {
            Button {
                droppingPin = true
            } label: {
                Label("Near the dropped pin", systemImage: "mappin.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Moves the pin")
            Button("Near Me", systemImage: "xmark", action: findLocation)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .accessibilityHint("Shows stations near where you are now")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.bottom, 8)
    }

    /// Rows show a dash until their first load.
    private func load() async {
        // Nearby rows show only the line's own trains, which are all in its own feeds
        await live.load(everyTrain, includingOtherLines: false)
    }
}

/// Header row for a nearby station: name and distance, tight above its lines with no separator.
private struct NearbyStationRow: View {
    let result: Nearby.Result

    var body: some View {
        HStack {
            Text(result.station.name).font(.headline)
            Spacer()
            Text(result.distance).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        // The same space above the name as above a widget's title on the Widgets tab
        .listRowInsets(.top, 16)
        .listRowInsets(.bottom, 0)
        .listRowSeparator(.hidden, edges: .bottom)
    }
}

/// Next trains for everything a Nearby tab page lists, fetched together.
@MainActor @Observable
final class LiveTrains {
    /// Next arrivals by `Selection.trainID`, as last fetched.
    private(set) var trains: [String: [Arrival]] = [:]
    /// `Selection.trainID`s whose last fetch failed. May include trains from an older
    /// list, so pages should check via `anyFailed(_:)`.
    private(set) var failed: Set<String> = []
    /// Those of `failed` showing the timetable's times instead (`TimetableStore`).
    private(set) var fromTimetable: Set<String> = []
    /// When the last load finished; nil before the first.
    private(set) var updated: Date?
    /// Ticks every few seconds so the minutes count down.
    var now = Date.now

    /// Fetches via `TrainService.trains(for:)`. Trains missing from the result lose their
    /// old times rather than count down stale ones. Trains not in `selections` keep their
    /// times and failure state, so an older load finishing late can't clear a newer one's rows.
    func load(_ selections: [Selection], includingOtherLines: Bool = true) async {
        // With nothing to fetch, nothing failed
        guard !selections.isEmpty else {
            failed = []
            return
        }
        let fetched = await TrainService.trains(for: selections, includingOtherLines: includingOtherLines)
        // Cancelled by a newer list; not a failure
        guard !Task.isCancelled else { return }
        let asked = Set(selections.map(\.trainID))
        let missing = asked.subtracting(fetched.keys)
        trains.merge(fetched) { $1 }
        // Those the MTA couldn't give, from the timetable if there is one
        let timetable = missing.isEmpty ? nil : TimetableStore.load()
        let timed = timetable.map {
            TrainService.trains(for: selections.filter { missing.contains($0.trainID) }, from: $0)
        } ?? [:]
        for trainID in missing { trains[trainID] = timed[trainID] }
        failed.subtract(asked)
        failed.formUnion(missing)
        fromTimetable.subtract(asked)
        fromTimetable.formUnion(timed.keys)
        now = .now
        updated = now
    }

    /// Whether any of a page's `selections` failed their last fetch.
    func anyFailed(_ selections: [Selection]) -> Bool {
        !failed.isDisjoint(with: selections.map(\.trainID))
    }

    /// Whether any of them show the timetable's times, as their last fetch failed.
    func anyFromTimetable(_ selections: [Selection]) -> Bool {
        !fromTimetable.isDisjoint(with: selections.map(\.trainID))
    }
}

extension View {
    /// Updates `now` every 10 seconds so, between loads, minutes count down and
    /// uncatchable trains drop off.
    func ticking(_ now: Binding<Date>) -> some View {
        task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now.wrappedValue = .now
            }
        }
    }

    /// Runs `load` now and every minute (restarting when `id` changes), and after
    /// `refreshing` on pull-to-refresh or app foregrounding. Ticks `live.now` in between.
    fileprivate func updatingTrains<ID: Equatable>(_ live: LiveTrains, id: ID, refreshing: @escaping () -> Void = {},
                                                   load: @escaping () async -> Void) -> some View {
        modifier(UpdatingTrains(live: live, id: id, refreshing: refreshing, load: load))
    }
}

private struct UpdatingTrains<ID: Equatable>: ViewModifier {
    let live: LiveTrains
    let id: ID
    let refreshing: () -> Void
    let load: () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .refreshable {
                refreshing()
                await load()
            }
            .task(id: id) {
                while !Task.isCancelled {
                    await load()
                    // After a failure, sooner; and as soon as the network's back (a station
                    // after a tunnel)
                    await Connectivity.shared.pause(for: .seconds(live.failed.isEmpty ? 60 : 15))
                }
            }
            .ticking(Binding { live.now } set: { live.now = $0 })
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshing()
                Task { await load() }
            }
    }
}

/// Shown above a page's trains when some failed to load; `timetable` if some of them show the
/// timetable's times instead.
private struct UnreachableNote: View {
    var timetable = false

    var body: some View {
        Label(timetable ? "Couldn't reach the MTA, so some times are the timetable's. Pull down to try again."
                  : "Couldn't reach the MTA. Pull down to try again.", systemImage: "wifi.exclamationmark")
            .foregroundStyle(.secondary)
    }
}

/// One line at a station with its next trains each way, matching the Nearby widget
/// (`Station.ways(of:trains:now:)`): toward Manhattan first. Directions with no name (end of
/// the line) are omitted, as is a direction where the line terminates at a shared platform,
/// unless some of its trains continue.
private struct NearbyLineRow: View {
    let station: Station
    let route: String
    let live: LiveTrains
    let marks: TimeMarks
    let open: (Selection) -> Void

    private var ways: [LineWay] {
        station.ways(of: route, trains: live.trains, now: live.now).compactMap { $0 }
    }

    var body: some View {
        // The bullet is centred between the directions
        HStack(spacing: 22) {
            LineBullet(route: route, size: 40)
                .frame(width: 44)
            VStack(spacing: 0) {
                ForEach(Array(ways.enumerated()), id: \.element.direction) { index, way in
                    let failed = live.failed.contains(way.selection.trainID)
                    if index > 0 {
                        Divider().padding(.vertical, 8)
                    }
                    Button {
                        open(way.selection)
                    } label: {
                        // The direction sits on the next train's baseline
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(way.label)
                                    .lineLimit(1)
                                // The next train's destination
                                if let terminal = way.trains?.first?.terminal {
                                    Text(terminal)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 12)
                            Minutes(trains: way.trains, failed: failed, now: live.now, marks: marks)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Lines.name(of: route)) \(way.label)"
                                        + (way.trains?.first?.terminal.map { ", to \($0)" } ?? ""))
                    // The label covers the whole row, so times go in the value
                    .accessibilityValue(Minutes.spoken(way.trains, failed: failed, now: live.now))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// A map to tap a place for Nearby to search around.
private struct DropPinSheet: View {
    /// The last pin or your location; nil falls back to Prospect Av.
    let start: CLLocationCoordinate2D?
    let drop: (CLLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var coordinate: CLLocationCoordinate2D?
    /// The middle of the map as last moved, for VoiceOver's Drop Pin Here; nil before it's moved.
    @State private var cameraCenter: CLLocationCoordinate2D?

    private var center: CLLocationCoordinate2D {
        start ?? Selection.fallback.station.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            ?? CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 2500, longitudinalMeters: 2500))) {
                    UserAnnotation()
                    if let coordinate {
                        Marker("Pin", systemImage: "mappin", coordinate: coordinate)
                            .tint(.red)
                    }
                }
                .onTapGesture { point in
                    coordinate = proxy.convert(point, from: .local)
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    cameraCenter = context.region.center
                }
                // Without tapping a point: the pin goes in the middle of the map
                .accessibilityAction(named: "Drop Pin Here") {
                    coordinate = cameraCenter ?? center
                }
            }
            // A glass capsule floating over the map
            .safeAreaInset(edge: .bottom) {
                Text(coordinate == nil ? "Tap the map to drop a pin." : "Tap elsewhere to move it.")
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .padding(.bottom, 8)
            }
            .navigationTitle("Drop Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        if let coordinate {
                            drop(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                        }
                        dismiss()
                    }
                    .disabled(coordinate == nil)
                }
            }
        }
    }
}

/// The next train large ("3 min"), the two after it small beneath ("then 9, 15 min"),
/// live predictions in green.
private struct Minutes: View {
    /// Nil until fetched.
    let trains: [Arrival]?
    /// Shows "Couldn't load" instead.
    let failed: Bool
    let now: Date
    let marks: TimeMarks

    var body: some View {
        if failed {
            Text("Couldn't load").font(.subheadline).foregroundStyle(.secondary)
        } else if let trains {
            if trains.isEmpty {
                Text("No trains").font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    next(trains[0])
                    if trains.count > 1 {
                        later(trains.dropFirst().prefix(2))
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(trains, now: now))
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// VoiceOver text, e.g. "Now, 1 minute, 7 minutes by the timetable". Scheduled
    /// times say so, as their colour does on screen.
    static func spoken(_ trains: [Arrival]?, failed: Bool = false, now: Date) -> String {
        guard !failed else { return "Couldn't load" }
        guard let trains else { return "Loading" }
        guard !trains.isEmpty else { return "No trains" }
        return trains.prefix(3).map { train in
            let time = MinutesToGo(until: train.time, from: now).spoken
            return train.isLive ? time : "\(time) by the timetable"
        }
        .joined(separator: ", ")
    }

    /// The next train, large: "3 min" or "Now".
    private func next(_ train: Arrival) -> some View {
        let minutes = MinutesToGo(until: train.time, from: now)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            time(train, markSize: 11)
                .font(.title3.weight(.bold))
            if !minutes.isNow {
                Text("min").font(.footnote.weight(.semibold))
                    .foregroundStyle(train.statusColor(scheduled: .primary))
            }
        }
    }

    /// The two after it, small: "then 6, 12 min".
    private func later(_ trains: ArraySlice<Arrival>) -> some View {
        HStack(spacing: 0) {
            Text("then ").foregroundStyle(.secondary)
            ForEach(Array(trains.enumerated()), id: \.element) { index, train in
                if index > 0 {
                    Text(", ").foregroundStyle(.secondary)
                }
                time(train, markSize: 8)
            }
            Text(" min").foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.medium))
    }

    /// One train's mark and minutes, in its status colour.
    private func time(_ train: Arrival, markSize: CGFloat) -> some View {
        HStack(spacing: 2) {
            StatusMark(isLive: train.isLive, marks: marks, size: markSize)
            Text(MinutesToGo(until: train.time, from: now).number)
        }
        .foregroundStyle(train.statusColor(scheduled: .primary))
    }
}

#Preview {
    LiveView(allowingLocation: .constant(false))
        .environment(WidgetStore())
        .environment(SettingsStore())
}
