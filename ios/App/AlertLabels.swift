import SwiftUI

/// A notice's kind as a heading ("Delays"), with the widgets' symbol and colour.
struct NoticeKindLabel: View {
    let kind: Notice.Kind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(kind.tint)
    }
}

/// Shown on a train's page when there are no alerts.
struct NoAlertsNote: View {
    var body: some View {
        Label("No alerts for this line here right now", systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
    }
}

/// Placeholder for data that failed to load.
struct CouldntLoadNote: View {
    /// "alerts", "elevator status"
    let what: String

    var body: some View {
        Text("Couldn't load \(what) from the MTA").foregroundStyle(.secondary)
    }
}

extension Outage {
    /// Start and end, e.g. "Since Oct 18, 2026 at 9:00 AM. Back Oct 21, 2026 at 5:00 PM
    /// (estimate)", or "<start> to <end>" for planned work. Empty if the MTA gives neither date.
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
