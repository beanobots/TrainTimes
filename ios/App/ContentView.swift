import SwiftUI
import WidgetKit

struct ContentView: View {
    @State private var selection = SharedStore.load()
    @State private var trains: [Arrival] = []
    @State private var loadState = LoadState.loading

    private enum LoadState { case loading, loaded, failed }

    private var station: Station? { selection.station }

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
            .refreshable { await loadTrains() }
            .onChange(of: selection) { _, new in
                SharedStore.save(new)
                WidgetCenter.shared.reloadAllTimelines()
            }
            .task(id: selection) { await loadTrains() }
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

    private func loadTrains() async {
        loadState = .loading
        do {
            trains = try await TrainService.upcoming(for: selection)
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
                .foregroundStyle(train.isLive ? Color.green : Color.primary)
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
