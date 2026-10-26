import CoreLocation
import MapKit
import Observation
import WidgetKit

/// Reads shared directions and works out the trips they could be (`TripPlanner`), then shows the
/// one picked on the Transit Directions widget for an hour (`SharedTrip`).
@MainActor @Observable
final class ShareModel {
    enum State {
        case loading
        case ready
        /// Why there's no trip to show.
        case failed(title: String, message: String)
    }

    private(set) var state = State.loading
    /// The trips found, soonest first, with lines tapped off dropped.
    private(set) var options: [SharedTrip.Option] = []
    /// Which of `options` to show.
    private(set) var picked = 0
    private(set) var app = MapsApp.apple
    /// Each option's lines from the start that go its way, to tap on and off.
    private var optionLines: [[String]] = []
    private(set) var startName = ""
    private(set) var endName = ""

    private let attachments: [NSItemProvider]

    init(attachments: [NSItemProvider]) {
        self.attachments = attachments
    }

    /// Trips ready to show, for previews.
    init(options: [SharedTrip.Option], app: MapsApp, startName: String, endName: String) {
        attachments = []
        self.options = options
        self.app = app
        optionLines = options.map(\.selection.routes)
        self.startName = startName
        self.endName = endName
        state = options.isEmpty ? .loading : .ready
    }

    /// The picked trip, as the widget will show it.
    var trip: SharedTrip? {
        options.indices.contains(picked) ? SharedTrip(option: options[picked], app: app, shared: .now) : nil
    }

    /// The picked option's lines to tap on and off.
    var lines: [String] {
        optionLines.indices.contains(picked) ? optionLines[picked] : []
    }

    func load() async {
        guard case .loading = state else { return }
        var link: MapsLink?
        for url in await sharedLinks(in: attachments) {
            if let found = await Self.directions(in: url) {
                link = found
                break
            }
        }
        guard let link else {
            return fail("Not Transit Directions", "Share directions or a place from Apple Maps or Google Maps.")
        }
        async let start = Self.location(of: link.origin ?? .currentLocation)
        async let end = Self.location(of: link.destination)
        guard let start = await start else {
            return fail("Couldn't Find the Start",
                        link.origin == nil || link.origin == .currentLocation
                            ? "Turn on Location Services for Leeway, or share directions with a starting point."
                            : "Leeway couldn't find where these directions start.")
        }
        guard let end = await end else {
            return fail("Couldn't Find the Destination", "Leeway couldn't find where these directions go.")
        }
        let planned = await ServerRoutes.plan(from: start, to: end)
        guard let first = planned.first else {
            return fail("No Subway on This Trip",
                        "Leeway couldn't find a subway trip between these places. Share transit directions in New York City.")
        }
        options = planned.map { SharedTrip.Option(selection: $0.selection, change: $0.change, destinationID: $0.destination.id) }
        optionLines = options.map(\.selection.routes)
        picked = 0
        app = link.app
        startName = (link.origin ?? .currentLocation).name ?? first.selection.station?.name ?? ""
        endName = link.destination.name ?? first.destination.name
        state = .ready
    }

    /// Picks which option to show.
    func choose(_ index: Int) {
        guard options.indices.contains(index) else { return }
        picked = index
    }

    /// Whether `route` is one of the picked option's lines.
    func isOn(_ route: String) -> Bool {
        options.indices.contains(picked) && options[picked].selection.routes.contains(route)
    }

    /// Takes `route` on or off the picked option's train. The last line stays, as does one the
    /// change needs.
    func toggle(_ route: String) {
        guard options.indices.contains(picked) else { return }
        var option = options[picked]
        var selection = option.selection
        selection.routes = isOn(route) ? selection.routes.filter { $0 != route }
            : lines.filter { selection.routes.contains($0) || $0 == route }
        guard !selection.routes.isEmpty else { return }
        if let change = option.change {
            guard let valid = change.validated(for: selection) else { return }
            option.change = valid
        }
        option.selection = selection
        options[picked] = option
    }

    /// Shows the picked trip on the Transit Directions widget for an hour from now, replacing any
    /// other.
    func show() {
        trip?.show()
    }

    private func fail(_ title: String, _ message: String) {
        state = .failed(title: title, message: message)
    }

    /// The directions in `url`, expanding a short link first.
    private static func directions(in url: URL) async -> MapsLink? {
        guard MapsLink.isShortLink(url) else { return MapsLink(url: url) }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        var candidates = [response.url].compactMap { $0 }
        // Google's consent page carries on to the directions
        if let final = response.url, let next = URLComponents(url: final, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "continue" })?.value.flatMap(URL.init(string:)) {
            candidates.append(next)
        }
        // Or a page that links on to them
        candidates += urls(in: String(decoding: data.prefix(200_000), as: UTF8.self))
        return candidates.lazy.compactMap(MapsLink.init(url:)).first
    }

    /// New York City, to look up addresses in.
    private static let city = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.73, longitude: -73.94),
                                                 latitudinalMeters: 60_000, longitudinalMeters: 60_000)

    /// How old a fix the Nearby widgets found (`SharedStore.loadNearbyFix`) can be and still stand
    /// for where the directions start.
    private static let nearbyFixLife: TimeInterval = 30 * 60

    /// Where `place` is: looked up for an address; for your location, where you are now or else
    /// where the Nearby widgets found you within `nearbyFixLife`.
    private static func location(of place: MapsLink.Place) async -> CLLocation? {
        switch place {
        case .coordinate(let latitude, let longitude, _):
            return CLLocation(latitude: latitude, longitude: longitude)
        case .address(let address):
            guard let request = MKGeocodingRequest(addressString: address) else { return nil }
            request.region = city
            return try? await request.mapItems.first?.location
        case .currentLocation:
            if let here = await currentLocation() { return here }
            return SharedStore.loadNearbyFix(within: nearbyFixLife).map {
                CLLocation(coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                           altitude: 0, horizontalAccuracy: $0.accuracy, verticalAccuracy: -1, timestamp: $0.taken)
            }
        }
    }

    /// Where you are, if Leeway may know, waiting at most a few seconds.
    private static func currentLocation() async -> CLLocation? {
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
