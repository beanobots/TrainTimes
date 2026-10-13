import MapKit
import SwiftUI
import WidgetKit

struct ContentView: View {
    @State private var selection = SharedStore.load()
    @State private var board: Board?
    @State private var loadState = LoadState.loading

    private enum LoadState { case loading, loaded, failed }

    private var station: Station? { selection.station }
    private var trains: [Arrival] { board?.trains ?? [] }

    var body: some View {
        NavigationStack {
            List {
                stationSection
                if let station {
                    Section("Line") {
                        LinePicker(routes: station.routes, selection: $selection.route)
                    }
                    Section("Direction") {
                        Picker("Direction", selection: $selection.direction) {
                            ForEach(Direction.allCases, id: \.self) { direction in
                                Text(station.directionLabel(direction)).tag(direction)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                trainsSection
                if loadState == .loaded, let board {
                    alertsSection(board.alerts)
                }
                if let station {
                    accessibilitySection(station)
                    mapSection(station)
                }
                if !SharedStore.isAvailable {
                    Section {
                        Label("The widget can't see your choice on this install, so it keeps showing Prospect Av (R) toward Manhattan.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } footer: {
                        Text("The shared storage the app and widget use wasn't set up when this was installed. Reinstalling with AltStore should fix it.")
                    }
                }
            }
            .navigationTitle("Train Times")
            .refreshable { await loadBoard() }
            .onChange(of: selection) { _, new in
                SharedStore.save(new)
                WidgetCenter.shared.reloadAllTimelines()
            }
            .task(id: selection) { await loadBoard() }
        }
    }

    private var stationSection: some View {
        Section {
            NavigationLink {
                StationPicker(selection: $selection)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(station?.name ?? "Choose a station").font(.headline)
                    if let station {
                        Text(station.borough).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Station")
        } footer: {
            Text("The widget shows this station, line and direction.")
        }
    }

    private var trainsSection: some View {
        Section {
            if loadState == .failed {
                Text("Couldn't reach the MTA").foregroundStyle(.secondary)
            } else if loadState == .loading && trains.isEmpty {
                ProgressView()
            } else if trains.isEmpty {
                Text("No \(LineStyle.of(selection.route).label) trains predicted").foregroundStyle(.secondary)
            } else {
                ForEach(trains.prefix(5), id: \.self) { train in
                    TrainRow(train: train)
                }
            }
        } header: {
            Text("Next trains")
        } footer: {
            Text("Green times are live predictions. The rest are timetable times, which can change.")
        }
    }

    private func alertsSection(_ alerts: [ServiceAlert]) -> some View {
        Section {
            if alerts.isEmpty {
                Label("No alerts for this line here right now", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(alerts) { alert in
                    AlertRow(alert: alert)
                }
            }
        } header: {
            Text("Service alerts")
        } footer: {
            Text("Delays, service changes and notices from the MTA that affect this line at this station.")
        }
    }

    private func accessibilitySection(_ station: Station) -> some View {
        Section {
            Label(station.accessibility ?? "No step-free access", systemImage: station.ada == 0 ? "figure.stairs" : "figure.roll")
            if EquipmentDirectory.hasEquipment(atComplex: station.complex) {
                let outages = board?.outages ?? []
                if loadState == .loaded && outages.isEmpty {
                    Label("All elevators and escalators are working", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(outages) { outage in
                    OutageRow(outage: outage)
                }
                Toggle("Show elevator outages on the widget", isOn: $selection.elevatorAlerts)
            } else {
                Text("No elevators or escalators at this station").foregroundStyle(.secondary)
            }
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Elevator and escalator status from the MTA.")
        }
    }

    private func mapSection(_ station: Station) -> some View {
        Section {
            StationMap(station: station, route: selection.route)
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            Link(destination: URL(string: "https://maps.apple.com/?daddr=\(station.lat),\(station.lon)&dirflg=w")!) {
                Label("Walking directions in Maps", systemImage: "figure.walk")
            }
        } header: {
            Text("Map")
        } footer: {
            if station.entrances.isEmpty {
                Text("The MTA doesn't list this station's entrances.")
            } else {
                Text("Dots are entrances; blue ones have an elevator. Hollow dots are exit only.")
            }
        }
    }

    private func loadBoard() async {
        loadState = .loading
        do {
            board = try await TrainService.board(for: selection)
            loadState = .loaded
        } catch {
            // a newer choice cancels this load; that isn't a failure
            if !Task.isCancelled { loadState = .failed }
        }
    }
}

private struct TrainRow: View {
    let train: Arrival

    var body: some View {
        HStack(spacing: 8) {
            Text(train.time, format: .dateTime.hour().minute())
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(train.isLive ? Color.liveText : Color.primary)
            if let terminal = train.terminal {
                Text(terminal).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(train.time, style: .timer)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlertRow: View {
    let alert: ServiceAlert

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let period = alert.period {
                    Label(period, systemImage: "calendar")
                }
                if !alert.details.isEmpty {
                    Text(alert.details)
                }
            }
            .font(.subheadline)
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(alert.kind.label, systemImage: alert.kind.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(alert.kind.tint)
                Text(alert.header)
            }
        }
    }
}

private struct OutageRow: View {
    let outage: Outage

    private var title: String {
        let machine = outage.isElevator ? "elevator" : "escalator"
        return outage.isPlanned ? "Planned \(machine) work" : (outage.isElevator ? "Elevator out" : "Escalator out")
    }

    private var when: String {
        let start = outage.start?.formatted(date: .abbreviated, time: .shortened)
        let end = outage.estimatedReturn?.formatted(date: .abbreviated, time: .shortened)
        switch (outage.isPlanned, start, end) {
        case (true, let start?, let end?): return "\(start) to \(end)"
        case (false, let start?, let end?): return "Since \(start). Back \(end) (estimate)"
        case (false, let start?, nil): return "Since \(start)"
        default: return ""
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !outage.reason.isEmpty {
                    Text("Reason: \(outage.reason)")
                }
                if outage.isAccessibilityElevator && !outage.alternative.isEmpty {
                    Text(outage.alternative)
                }
            }
            .font(.subheadline)
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: outage.isElevator ? "arrow.up.arrow.down.square" : "stairs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(outage.isPlanned ? Color.secondary : Color.orange)
                Text(outage.serving)
                if !when.isEmpty {
                    Text(when).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The station on a map, with its entrances.
private struct StationMap: View {
    let station: Station
    let route: String

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: station.lat, longitude: station.lon),
            latitudinalMeters: 350,
            longitudinalMeters: 350
        ))) {
            Marker(station.name, systemImage: "tram.fill", coordinate: CLLocationCoordinate2D(latitude: station.lat, longitude: station.lon))
                .tint(Color(hex: LineStyle.of(route).color))
            ForEach(Array(station.entrances.enumerated()), id: \.offset) { _, entrance in
                Annotation(entrance.isElevator ? "Elevator" : "", coordinate: CLLocationCoordinate2D(latitude: entrance.lat, longitude: entrance.lon)) {
                    EntranceMark(entrance: entrance)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .id(station.id)
        .accessibilityLabel("Map of \(station.name) and its entrances")
    }
}

private struct EntranceMark: View {
    let entrance: Station.Entrance

    var body: some View {
        if entrance.isElevator {
            Image(systemName: "figure.roll")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(4)
                .background(Circle().fill(Color.blue))
        } else if entrance.exitOnly == true {
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 2))
        } else {
            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
        }
    }
}

/// The bullets of the lines that stop at the station; tap one to choose it.
private struct LinePicker: View {
    let routes: [String]
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 12) {
            ForEach(routes, id: \.self) { route in
                Button {
                    selection = route
                } label: {
                    LineBullet(route: route, size: 40)
                        .padding(4)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: selection == route ? 3 : 0))
                        .opacity(selection == route ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == route ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}
