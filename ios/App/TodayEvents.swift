import CoreGraphics
import EventKit
import Foundation
import Observation

/// An event on your calendar today with somewhere to be, to pick as where a New Trip goes.
struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    /// The place's name, when the location has one over its address ("Smile NYC").
    let placeName: String?
    /// The address to look up, or the location as typed.
    let address: String
    /// Where it is, when the event's location was picked from the map in Calendar.
    let point: TripPlace.Point?
    let color: CGColor?

    /// The place's name and address on one line, for under the title.
    var placeLine: String {
        [placeName, address].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Today's events with a location, for New Trip's To. Asks for your calendar only when told to
/// (first-run setup, or New Trip's row); reads it only on this iPhone. Calendar can only be read
/// with full access: there's no read-only kind.
@MainActor
@Observable
final class TodayEvents {
    private(set) var status = EKEventStore.authorizationStatus(for: .event)
    /// Those not over yet, soonest first.
    private(set) var events: [CalendarEvent] = []

    @ObservationIgnored private lazy var store = EKEventStore()

    /// How long after it starts an event is still offered: you may be running late.
    private static let lateBy: TimeInterval = 30 * 60

    /// Whether Leeway hasn't asked for your calendar yet.
    var mayAsk: Bool { status == .notDetermined }
    var isAllowed: Bool { status == .fullAccess }
    var isDenied: Bool { status == .denied || status == .restricted || status == .writeOnly }

    /// Asks for your calendar, then reads today's events.
    func ask() async {
        _ = try? await store.requestFullAccessToEvents()
        refresh()
    }

    /// Reads today's events, then again when Calendar changes or one listed goes past `lateBy`,
    /// for as long as the task calling it runs (the To list's `.task`): no reading on a timer.
    func watch() async {
        refresh()
        await withDiscardingTaskGroup { group in
            group.addTask { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    self.refresh()
                }
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    // Till the soonest listed is over, or `recheck` with none
                    let over = self.events.map { $0.start.addingTimeInterval(Self.lateBy) }.min()
                    let wait = min(over?.timeIntervalSinceNow ?? Self.recheck, Self.recheck)
                    guard (try? await Task.sleep(for: .seconds(max(1, wait)))) != nil else { return }
                    if self.events.contains(where: { $0.start.addingTimeInterval(Self.lateBy) <= .now }) {
                        self.refresh()
                    }
                }
            }
        }
    }

    /// At most this long between looks at whether an event listed is over.
    private static let recheck: TimeInterval = 10 * 60

    /// Reads today's events again, from those started a little while ago to midnight.
    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard isAllowed else {
            events = []
            return
        }
        let now = Date.now
        let calendar = Calendar.current
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-Self.lateBy), end: midnight,
                                                 calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= now.addingTimeInterval(-Self.lateBy) && $0.status != .canceled }
            .compactMap(Self.event)
            .sorted { $0.start < $1.start }
    }

    /// An event as one to go to: nil without a location, or with only a link (a video call).
    private static func event(_ event: EKEvent) -> CalendarEvent? {
        let typed = (event.structuredLocation?.title ?? event.location ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains("://") else { return nil }
        // A place picked in Calendar is its name, then its address on the next line
        let lines = typed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let named = lines.count > 1
        let coordinate = event.structuredLocation?.geoLocation?.coordinate
        return CalendarEvent(
            id: event.calendarItemIdentifier + "\(event.startDate.timeIntervalSinceReferenceDate)",
            title: event.title ?? "Event",
            start: event.startDate,
            placeName: named ? lines[0] : nil,
            address: named ? lines.dropFirst().joined(separator: ", ") : lines.joined(separator: ", "),
            point: coordinate.map { TripPlace.Point(latitude: $0.latitude, longitude: $0.longitude) },
            color: event.calendar?.cgColor)
    }
}
