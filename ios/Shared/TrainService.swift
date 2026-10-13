import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Everything shown for a selection: its trains, and what might get in the way.
struct Board: Sendable {
    var trains: [Arrival]
    /// Alerts in effect for the line at this station and direction, most important first.
    var alerts: [ServiceAlert]
    /// Elevator and escalator outages at the station, current ones first.
    var outages: [Outage]

    /// The one thing the widget has room to mention, and how many more there are.
    func notice(includingElevators: Bool) -> Notice? {
        var notices: [Notice] = []
        let elevatorsOut = outages.filter { !$0.isPlanned && $0.isAccessibilityElevator }
        if includingElevators, let first = elevatorsOut.first {
            let label = elevatorsOut.count == 1 ? "Elevator out" : "\(elevatorsOut.count) elevators out"
            notices.append(Notice(kind: .elevator, label: label, text: first.serving, others: 0))
        }
        notices += alerts.map { Notice(kind: .alert($0.kind), label: $0.kind.label, text: $0.header, others: 0) }
        guard let first = notices.first else { return nil }
        return Notice(kind: first.kind, label: first.label, text: first.text, others: notices.count - 1)
    }
}

struct Notice: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case alert(ServiceAlert.Kind)
        case elevator
    }

    let kind: Kind
    /// "Delays", "Service change", "Elevator out"
    let label: String
    /// The alert's headline, or what the elevator serves.
    let text: String
    let others: Int
}

enum TrainService {
    /// Trains, alerts and (when asked for) elevator outages for `selection`, fetched
    /// together. Only the trains are required: without alerts or outages the
    /// board just has none.
    static func board(for selection: Selection, includingOutages: Bool = true, now: Date = Date()) async throws -> Board {
        async let trainData = data(from: Lines.feedURL(for: selection.route))
        async let alertData = optionalData(from: AlertsFeed.url)
        async let outageData = optionalData(from: includingOutages ? OutagesFeed.url : nil)

        let trains = try SubwayFeed.upcoming(stopID: selection.stopID, route: selection.route, from: await trainData, now: now)
        let alerts = await alertData.flatMap { try? AlertsFeed.alerts(for: selection, in: $0, now: now) } ?? []
        var outages: [Outage] = []
        if let complex = selection.station?.complex, let data = await outageData {
            outages = (try? OutagesFeed.outages(atComplex: complex, in: data)) ?? []
        }
        return Board(trains: trains, alerts: alerts, outages: outages)
    }

    private static func data(from url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func optionalData(from url: URL?) async -> Data? {
        guard let url else { return nil }
        return try? await data(from: url)
    }
}
