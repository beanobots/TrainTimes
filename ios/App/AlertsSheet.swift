import SwiftUI

/// A train's alerts in full, opened from "More ›" on a widget: each one's
/// headline, the MTA's description and when it applies, and, where the widget
/// mentions them, the elevators out.
struct AlertsSheet: View {
    /// The train the sheet is for, as `sheet(item:)` needs it.
    struct Train: Identifiable {
        /// New each time, so tapping "More ›" again shows the sheet again.
        let id = UUID()
        let selection: Selection
    }

    let selection: Selection
    @Environment(\.dismiss) private var dismiss
    @State private var board: Board?
    @State private var failed = false

    /// Elevators out now, as the widget counts them.
    private var elevatorsOut: [Outage] {
        guard selection.elevatorAlerts else { return [] }
        return (board?.outages ?? []).filter { !$0.isPlanned && $0.isAccessibilityElevator }
    }

    /// Whether elevators were to be mentioned but their status couldn't be had.
    private var elevatorsUnknown: Bool {
        selection.elevatorAlerts && board != nil && board?.outages == nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let board {
                        if board.alerts?.isEmpty == true && elevatorsOut.isEmpty && !elevatorsUnknown {
                            Label("No alerts for this line here right now", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(elevatorsOut) { outage in
                            ElevatorDetail(outage: outage)
                        }
                        if elevatorsUnknown {
                            Text("Couldn't load elevator status from the MTA").foregroundStyle(.secondary)
                        }
                        if let alerts = board.alerts {
                            ForEach(alerts) { alert in
                                AlertDetail(alert: alert)
                            }
                        } else {
                            Text("Couldn't load alerts from the MTA").foregroundStyle(.secondary)
                        }
                    } else if failed {
                        Text("Couldn't reach the MTA").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                } header: {
                    if let station = selection.station {
                        Text("\(station.name) · \(selection.caption)")
                    }
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    /// Alerts and outages only, so a train feed that's down doesn't keep them
    /// from showing. What's shown stays up if neither comes.
    private func load() async {
        let fetched = await TrainService.notices(for: selection, includingOutages: selection.elevatorAlerts)
        guard !Task.isCancelled else { return }
        if fetched.alerts == nil && fetched.outages == nil {
            failed = board == nil
        } else {
            board = fetched
            failed = false
        }
    }
}

/// An alert with nothing folded away: its kind, headline, details and when it applies.
private struct AlertDetail: View {
    let alert: ServiceAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(alert.kind.label, systemImage: alert.kind.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(alert.kind.tint)
            Text(alert.header)
                .font(.body.weight(.semibold))
            if !alert.details.isEmpty {
                Text(alert.details)
                    .font(.subheadline)
            }
            if let period = alert.period {
                Label(period, systemImage: "calendar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // Read as one, not a piece at a time
        .accessibilityElement(children: .combine)
    }
}

/// An elevator out: what it serves, and how to get around it.
private struct ElevatorDetail: View {
    let outage: Outage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Elevator out", systemImage: "figure.roll")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(outage.serving)
                .font(.body.weight(.semibold))
            if !outage.alternative.isEmpty {
                Text(outage.alternative)
                    .font(.subheadline)
            }
            if let back = outage.estimatedReturn {
                Label("Back \(back.formatted(date: .abbreviated, time: .shortened)) (estimate)", systemImage: "calendar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
