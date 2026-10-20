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
        return board?.elevatorsOut ?? []
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
                            NoAlertsNote()
                        }
                        ForEach(elevatorsOut) { outage in
                            ElevatorDetail(outage: outage)
                        }
                        if elevatorsUnknown {
                            CouldntLoadNote(what: "elevator status")
                        }
                        if let alerts = board.alerts {
                            ForEach(alerts) { alert in
                                AlertDetail(alert: alert)
                            }
                        } else {
                            CouldntLoadNote(what: "alerts")
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
            NoticeKindLabel(kind: .alert(alert.kind))
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

/// An elevator out: what it serves, how to get around it, and since and until when.
private struct ElevatorDetail: View {
    let outage: Outage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NoticeKindLabel(kind: .elevator)
            Text(outage.serving)
                .font(.body.weight(.semibold))
            if !outage.alternative.isEmpty {
                Text(outage.alternative)
                    .font(.subheadline)
            }
            if !outage.when.isEmpty {
                Label(outage.when, systemImage: "calendar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A notice's kind, as an alert or an elevator out is headed in the app:
/// "Delays", with its symbol and in its colour, as on the widgets.
struct NoticeKindLabel: View {
    let kind: Notice.Kind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(kind.tint)
    }
}

/// "No alerts for this line here right now", in a train's page or its alerts.
struct NoAlertsNote: View {
    var body: some View {
        Label("No alerts for this line here right now", systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
    }
}

/// In place of what couldn't be had: "Couldn't load alerts from the MTA".
struct CouldntLoadNote: View {
    /// "alerts", "elevator status"
    let what: String

    var body: some View {
        Text("Couldn't load \(what) from the MTA").foregroundStyle(.secondary)
    }
}

extension Outage {
    /// When it began and is to end, as far as the MTA says: "Since Oct 18,
    /// 2026 at 9:00 AM. Back Oct 21, 2026 at 5:00 PM (estimate)", or for
    /// planned work, "Oct 30, 2026 at 10:00 PM to Oct 31, 2026 at 5:00 AM".
    /// Empty where it gives neither date.
    var when: String {
        let start = self.start?.formatted(date: .abbreviated, time: .shortened)
        let end = estimatedReturn?.formatted(date: .abbreviated, time: .shortened)
        // The MTA can leave either date blank
        switch (isPlanned, start, end) {
        case (true, let start?, let end?): return "\(start) to \(end)"
        case (true, let start?, nil): return "From \(start)"
        case (true, nil, let end?): return "Until \(end)"
        case (false, let start?, let end?): return "Since \(start). Back \(end) (estimate)"
        case (false, let start?, nil): return "Since \(start)"
        case (false, nil, let end?): return "Back \(end) (estimate)"
        case (_, nil, nil): return ""
        }
    }
}
