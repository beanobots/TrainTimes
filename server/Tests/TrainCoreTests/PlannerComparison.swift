import Foundation
import Testing
@testable import TrainCore

/// The server's own trips (`TransitPlanner`) beside Google's for the same trips around the city,
/// on the real timetables, to tell whether the planner is as good before Google's let go. Only
/// with LEEWAY_COMPARE_GOOGLE=1 and GOOGLE_ROUTES_API_KEY set: it downloads the MTA's GTFS (kept
/// in /tmp/leeway-gtfs) and asks Google about 70 times. Writes /tmp/leeway-compare.txt.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LEEWAY_COMPARE_GOOGLE"] == "1"))
struct PlannerComparison {
    static let trips: [(String, (Double, Double), String, (Double, Double))] = [
        ("Park Slope", (40.6668, -73.9800), "Times Sq", (40.7580, -73.9855)),
        ("Astoria", (40.7750, -73.9120), "Wall St", (40.7060, -74.0090)),
        ("Williamsburg", (40.7170, -73.9570), "UWS 86 St", (40.7880, -73.9768)),
        ("Bay Ridge", (40.6224, -74.0282), "Borough Hall", (40.6930, -73.9900)),
        ("Flushing", (40.7590, -73.8300), "Jamaica Ctr", (40.7020, -73.8010)),
        ("Harlem 125", (40.8080, -73.9450), "Fordham Rd", (40.8615, -73.8905)),
        ("Red Hook", (40.6760, -74.0110), "5 Av/9 St", (40.6700, -73.9850)),
        ("Greenpoint", (40.7300, -73.9540), "Court Sq", (40.7470, -73.9440)),
        ("Co-op City", (40.8740, -73.8290), "Pelham Bay", (40.8520, -73.8280)),
        ("St George", (40.6430, -74.0740), "Tottenville", (40.5120, -74.2510)),
        ("Crown Heights", (40.6700, -73.9580), "Myrtle-Wyckoff", (40.6995, -73.9120)),
        ("Sunset Park", (40.6350, -74.0110), "Coney Island", (40.5770, -73.9810)),
        ("East Village", (40.7270, -73.9810), "3 Av/50 St", (40.7550, -73.9700)),
        ("UES 79 St", (40.7720, -73.9500), "UWS 81 St", (40.7830, -73.9740)),
        ("LaGuardia", (40.7730, -73.8720), "74 St-Bway", (40.7466, -73.8913)),
        ("Riverdale", (40.8900, -73.9100), "181 St", (40.8510, -73.9370)),
        ("Canarsie", (40.6460, -73.9020), "Kings Plaza", (40.6100, -73.9210)),
        ("Bed-Stuy", (40.6800, -73.9500), "PPW/9 St", (40.6670, -73.9750)),
        ("Ridgewood", (40.7040, -73.9040), "Forest Hills", (40.7215, -73.8440)),
        ("Hunts Point", (40.8200, -73.8900), "149 St/3 Av", (40.8160, -73.9180)),
        ("Midwood", (40.6250, -73.9610), "Sheepshead Bay", (40.5870, -73.9540)),
        ("Chinatown", (40.7170, -73.9960), "Battery Park City", (40.7120, -74.0160)),
        ("Rockaway 116", (40.5800, -73.8370), "Howard Beach", (40.6600, -73.8300)),
        ("Fresh Meadows", (40.7350, -73.7930), "Flushing", (40.7590, -73.8300)),
        ("Throgs Neck", (40.8200, -73.8200), "Parkchester", (40.8330, -73.8610)),
        ("Inwood", (40.8680, -73.9200), "Columbia", (40.8075, -73.9640)),
        ("Gowanus", (40.6780, -73.9890), "Grand Army Plaza", (40.6750, -73.9710)),
        ("Murray Hill", (40.7440, -73.9760), "10 Av/23 St", (40.7470, -74.0050)),
        ("Brighton Beach", (40.5780, -73.9600), "Jay St", (40.6920, -73.9870)),
        ("Bayside", (40.7630, -73.7700), "Jamaica 165 St", (40.7070, -73.7940)),
        ("Woodside", (40.7456, -73.9030), "Grand St Bklyn", (40.7110, -73.9400)),
        ("Kew Gardens", (40.7090, -73.8300), "Lefferts Blvd", (40.6860, -73.8250)),
        ("East New York", (40.6650, -73.8940), "Rockaway Av", (40.6620, -73.9090)),
        ("Grand Central", (40.7527, -73.9772), "Navy Yard", (40.6990, -73.9730)),
        ("New Dorp", (40.5730, -74.1170), "St George", (40.6430, -74.0740)),
    ]

    /// When the walk from a trip's last ride gets to `end`, by the app's walking time; nil for a
    /// trip the app can't use: over two rides, a walk over its 1.2 km to or from them, or no times.
    static func arrival(of route: TransitRoute, from start: (Double, Double), to end: (Double, Double)) -> Int? {
        guard let first = route.legs.first, let last = route.legs.last, route.legs.count <= 2,
              TransitNetwork.meters(start, (first.from.latitude, first.from.longitude)) <= 1200,
              TransitNetwork.meters(end, (last.to.latitude, last.to.longitude)) <= 1200,
              let leaves = last.leaves, let seconds = last.seconds else { return nil }
        return leaves + seconds + TransitNetwork.walkSeconds(TransitNetwork.meters((last.to.latitude, last.to.longitude), end))
    }

    static func describe(_ route: TransitRoute?) -> String {
        guard let route else { return "-" }
        return route.legs.map { "\($0.line)@\($0.from.name.prefix(14))" }.joined(separator: " > ")
    }

    @Test func comparesWithGoogle() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["GOOGLE_ROUTES_API_KEY"])
        let kept = URL(fileURLWithPath: "/tmp/leeway-gtfs")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let subway = try await TimetableBuilder.downloadSubway(now: .now, keptIn: kept)
        let buses = try await TimetableBuilder.downloadBuses(now: .now, keptIn: kept)
        let clock = ContinuousClock()
        let built = clock.now
        let network = TransitNetwork(subway: subway, buses: buses)
        var report = "Network: \(network.stops.count) stops, \(network.patterns.count) patterns, built in \(clock.now - built)\n"

        // Monday 8:30 in New York, or the next weekday morning
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimetableBuilder.newYork
        var departure = calendar.nextDate(after: .now, matching: DateComponents(hour: 8, minute: 30), matchingPolicy: .nextTime)!
        while calendar.isDateInWeekend(departure) { departure = departure.addingTimeInterval(86400) }
        report += "Leaving \(departure)\n\n"

        var tally: [String: Int] = [:]
        var differences: [Int] = []
        var planning: [Duration] = []
        for bus in [false, true] {
            let modes: Set<TransitRoute.Mode> = bus ? [.subway, .bus] : [.subway]
            report += bus ? "== Subway and bus ==\n" : "== Subway ==\n"
            for (fromName, from, toName, to) in Self.trips {
                let started = clock.now
                let ours = TransitPlanner.routes(on: network, from: from, to: to, departure: departure, modes: modes)
                planning.append(clock.now - started)
                let (data, status) = try await Web.fetch(GoogleRoutes.request(from: from, to: to, departure: departure,
                                                                              key: key, bus: bus))
                let google = status == 200 ? GoogleRoutes.routes(in: data, bus: bus) ?? [] : []
                let best = { (routes: [TransitRoute]) in
                    routes.compactMap { route in Self.arrival(of: route, from: from, to: to).map { (route, $0) } }
                        .min { $0.1 < $1.1 }
                }
                let ourBest = best(ours), googleBest = best(google)
                let verdict: String
                switch (ourBest, googleBest) {
                case let (o?, g?):
                    let minutes = (o.1 - g.1) / 60
                    verdict = minutes <= -2 ? "ours sooner" : minutes >= 2 ? "Google sooner" : "same"
                    differences.append(minutes)
                case (_?, nil): verdict = "only ours"
                case (nil, _?): verdict = "only Google"
                case (nil, nil): verdict = "neither"
                }
                tally[verdict, default: 0] += 1
                let time = { (found: (TransitRoute, Int)?) in
                    found.map { Date(timeIntervalSince1970: TimeInterval($0.1)).formatted(.dateTime.hour().minute()) } ?? "-"
                }
                report += "\(fromName) → \(toName): \(verdict) [\(ours.count) vs \(google.count) \(status)]\n"
                report += "   ours   \(time(ourBest))  \(Self.describe(ourBest?.0))\n"
                report += "   Google \(time(googleBest))  \(Self.describe(googleBest?.0))\n"
            }
            report += "\n"
        }
        report += "Tally: " + tally.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n"
        report += "Minutes ours minus Google, where both: \(differences.sorted())\n"
        let sorted = planning.sorted()
        report += "Planning: median \(sorted[sorted.count / 2]), slowest \(sorted.last!)\n"
        try report.write(toFile: "/tmp/leeway-compare.txt", atomically: true, encoding: .utf8)
        print(report)
    }
}
