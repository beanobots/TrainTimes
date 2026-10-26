import SwiftUI
import WidgetKit

/// The Share sheet for directions from Apple Maps or Google Maps: the trip worked out from them,
/// drawn as the Transit Directions widget will show it, to show there for an hour.
struct ShareView: View {
    let model: ShareModel
    /// Closes the sheet.
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                switch model.state {
                case .loading:
                    Section {
                        ProgressView("Finding your train…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                case .failed(let title, let message):
                    Section {
                        ContentUnavailableView(title, systemImage: "tram.fill", description: Text(message))
                    }
                case .ready:
                    if let trip = model.trip {
                        ready(trip)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Show in Leeway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: done)
                }
                if case .ready = model.state {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show", role: .confirm) {
                            model.show()
                            done()
                        }
                    }
                }
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private func ready(_ trip: SharedTrip) -> some View {
        Section {
            source(model.app)
        }

        Section {
            SharedTripPreview(trip: trip)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())

        if model.options.count > 1 {
            Section {
                ForEach(model.options.indices, id: \.self) { index in
                    optionRow(model.options[index], index: index, picked: index == model.picked)
                }
            } header: {
                Text("Options")
            } footer: {
                Text("Soonest first. Maps doesn't say which trains its directions take, so pick the one it shows.")
            }
        }

        let option = trip.option
        Section {
            row(title: "Depart from", name: option.selection.station?.name ?? "",
                routes: option.selection.routes, detail: option.selection.heading)
            if model.lines.count > 1 {
                lineToggles
            }
            if let change = option.change {
                row(title: "Then change at", name: change.stationNames(for: option.selection),
                    routes: change.allRoutes, detail: change.heading(for: option.selection))
            }
            if let destination = option.endStation {
                row(title: "Arrive at", name: destination.name, routes: [], detail: nil)
            }
        } footer: {
            Text(option.change == nil ? "Matched from the directions' start and end."
                 : "Matched from the directions' start and end. They change trains, so the widget shows the change.")
        }

        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Until \(Date.now.addingTimeInterval(SharedTrip.duration), format: .dateTime.hour().minute())")
                        .font(.headline)
                    Text("Then back to your default train")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "timer")
            }
        } header: {
            Text("Transit Directions widget")
        } footer: {
            Text("Shows on your Transit Directions widgets for an hour. To add one, touch and hold the Home Screen, then Edit › Add Widget › Leeway.")
        }
    }

    /// One of the trips found. A tap picks it.
    private func optionRow(_ option: SharedTrip.Option, index: Int, picked: Bool) -> some View {
        Button {
            model.choose(index)
        } label: {
            TripOptionRow(option: option, picked: picked)
        }
        .buttonStyle(.plain)
    }

    /// Where the trip came from.
    private func source(_ app: MapsApp) -> some View {
        HStack(spacing: 12) {
            Image(systemName: app == .google ? "g.circle.fill" : "map.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(app == .google ? Color.blue : Color.green,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(model.startName) → \(model.endName)")
                    .font(.headline)
                Text("Transit directions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The lines from the start that go there: tap one to take it off the widget or back on.
    private var lineToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lines that go there").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(model.lines, id: \.self) { route in
                    let on = model.isOn(route)
                    Button {
                        model.toggle(route)
                    } label: {
                        LineBullet(route: route, size: 32)
                            .opacity(on ? 1 : 0.35)
                            .padding(3)
                            .overlay(Circle().strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Lines.spokenName(of: route))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func row(title: String, name: String, routes: [String], detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(name).font(.headline)
            if !routes.isEmpty || detail != nil {
                HStack(spacing: 6) {
                    if !routes.isEmpty { LineBullets(routes: routes, size: 18) }
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let options = [
        SharedTrip.Option(selection: Selection(stationID: "R31", routes: ["D", "N", "R"], direction: .north), destinationID: "R17"),
        SharedTrip.Option(selection: Selection(stationID: "D24", routes: ["B", "Q"], direction: .north), destinationID: "D17"),
    ]
    ShareView(model: ShareModel(options: options, app: .apple, startName: "Home", endName: "Macy's Herald Square")) {}
}
