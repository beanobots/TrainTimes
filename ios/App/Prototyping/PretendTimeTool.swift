import SwiftUI

/// Pretend Time: the app's clock (`AppClock`) set to another time, running on from there, for
/// this run of the app only. Never saved, so a relaunch is always the real time.
@Observable @MainActor
final class PretendTime {
    static let shared = PretendTime()

    /// `AppClock.offset`, kept here so what shows it redraws as it's changed.
    private(set) var offset: TimeInterval = 0
    /// The quick pick's name, if it was one.
    private(set) var name: String?

    /// As `AppClock.isPretending`, read from `offset` so it's observed.
    var isOn: Bool { abs(offset) >= 1 }

    /// The app's clock reading `date` now, and running on from it.
    func set(_ date: Date, name: String? = nil) {
        offset = date.timeIntervalSinceNow
        AppClock.offset = offset
        self.name = name
    }

    func reset() {
        offset = 0
        AppClock.offset = 0
        name = nil
    }

    /// For the Prototyping card's row: "Sun 8:00 AM", as set; nil at the real time.
    var status: String? {
        guard isOn else { return nil }
        return name ?? AppClock.now.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct PretendTimeTool: View {
    private var pretend = PretendTime.shared
    /// What the picker shows: the app's time when opened, then as picked.
    @State private var picked = AppClock.now
    /// Whether the downloaded timetable has trains at the app's time; nil while finding out.
    @State private var hasTimetable: Bool?

    /// Times are the city's, as the timetables are.
    private static let zone = TimeZone(identifier: "America/New_York") ?? .current

    var body: some View {
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = AppClock.pretend(context.date)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(now.formatted(Self.format(seconds: true)))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text(pretend.isOn ? "Real time \(context.date.formatted(Self.format(seconds: false)))"
                                          : "The real time")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if pretend.isOn, hasTimetable == false {
                    Label("The downloaded timetable has no trains then: only live times would show, and they're left out.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("The App's Time")
            }

            Section {
                DatePicker("Pretend It's", selection: $picked)
                    .onChange(of: picked) { _, date in
                        // Not for the picker catching up with a quick pick
                        guard abs(date.timeIntervalSince(AppClock.now)) >= 60 else { return }
                        pretend.set(date)
                    }
                ForEach(Self.quickPicks(from: Date.now)) { pick in
                    Button {
                        pretend.set(pick.date, name: pick.name)
                        picked = pick.date
                    } label: {
                        LabeledContent(pick.name, value: pick.date.formatted(Self.format(seconds: false)))
                    }
                }
            } footer: {
                Text("Time runs on from what's set. Lasts until the app quits.")
            }

            Section {
                Button("Reset to Real Time", role: .destructive) {
                    pretend.reset()
                    picked = .now
                }
                .disabled(!pretend.isOn)
            } footer: {
                Text("""
                    While pretending, live trains and buses are left out, as they're the real time's: times, \
                    Nearby and New Trip come from the downloaded timetables, as offline. Widgets, the Lock \
                    Screen countdown and Siri keep the real time.
                    """)
            }
        }
        .environment(\.timeZone, Self.zone)
        .task(id: pretend.offset) {
            hasTimetable = nil
            let at = AppClock.now
            hasTimetable = await Task.detached(priority: .utility) { TimetableStore.load(now: at) != nil }.value
        }
    }

    private static func format(seconds: Bool) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        if seconds { style = style.second() }
        style.timeZone = zone
        return style
    }

    /// A time worth testing the timetables at, by name.
    private struct QuickPick: Identifiable {
        let name: String
        let date: Date
        var id: String { name }
    }

    /// The quick picks, the next of each after `now`.
    private static func quickPicks(from now: Date) -> [QuickPick] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        /// The next `hour`:`minute` after `now`, on a weekday if `weekday`, or on day `on` (1 Sunday).
        func next(_ hour: Int, _ minute: Int = 0, weekday: Bool = false, on day: Int? = nil) -> Date {
            var components = DateComponents(hour: hour, minute: minute)
            components.weekday = day
            var date = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now
            while weekday, calendar.isDateInWeekend(date) {
                date = calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime) ?? date
            }
            return date
        }
        return [
            QuickPick(name: "In 10 Minutes", date: now.addingTimeInterval(10 * 60)),
            QuickPick(name: "Morning Rush, 8:30 AM", date: next(8, 30, weekday: true)),
            QuickPick(name: "Midday, 1 PM", date: next(13, weekday: true)),
            QuickPick(name: "Evening Rush, 5:30 PM", date: next(17, 30, weekday: true)),
            QuickPick(name: "Tonight, 11 PM", date: next(23)),
            QuickPick(name: "Late Night, 3 AM", date: next(3)),
            QuickPick(name: "Saturday, Noon", date: next(12, on: 7)),
            QuickPick(name: "Sunday, 8 AM", date: next(8, on: 1)),
        ]
    }
}

#Preview {
    NavigationStack {
        PretendTimeTool()
            .navigationTitle("Pretend Time")
            .navigationBarTitleDisplayMode(.inline)
    }
}
