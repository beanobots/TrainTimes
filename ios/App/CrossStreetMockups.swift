import MapKit
import SwiftUI

// Throwaway mockups: street signs at the streets a walk crosses. Map tiles don't draw in
// previews, so it's run in the simulator with `-signs a|b|c` (and `-dark`), a hook in
// LeewayApp. Delete this and the hook once one's picked and built.

struct CrossStreetMockup: View {
    enum Style: String {
        case a, b, c

        var title: String {
            switch self {
            case .a: "A · NYC blade"
            case .b: "B · Cross pill"
            case .c: "C · On the road"
            }
        }
    }

    static var launchStyle: Style? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-signs"), index + 1 < args.count else { return nil }
        return Style(rawValue: args[index + 1])
    }

    let style: Style

    private struct Crossing: Identifiable {
        let id: Int
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
        var name: String
        /// Degrees from north the crossing runs.
        var bearing: Double { Self.bearing(from, to) }

        static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            let north = b.latitude - a.latitude
            let east = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180)
            return (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }
    }

    @State private var route: [CLLocationCoordinate2D] = []
    @State private var crossings: [Crossing] = []
    @State private var heading: Double = 0
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        map
            .ignoresSafeArea()
            .overlay(alignment: .top) { turnCard }
            .overlay(alignment: .bottom) { trainCard }
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-dark") ? .dark : .light)
            .task { await load() }
    }

    private var map: some View {
        Map(position: $position) {
            MapPolyline(coordinates: route)
                .stroke(.white, style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: route)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: route)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 9]))
            ForEach(crossings) { crossing in
                MapPolyline(coordinates: [crossing.from, crossing.to])
                    .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .butt, dash: [2, 2.5]))
                sign(crossing)
            }
            if let you = route.first {
                Annotation("", coordinate: you, anchor: .center) { walker }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {}
    }

    // MARK: The signs

    @MapContentBuilder
    private func sign(_ crossing: Crossing) -> some MapContent {
        switch style {
        case .a:
            // At the near curb, on a pole, as the city's own green signs are
            Annotation("", coordinate: crossing.from, anchor: .bottom) {
                VStack(spacing: 0) {
                    Text(crossing.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color(red: 0.0, green: 0.42, blue: 0.25), in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 1.5).stroke(.white, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    Rectangle().fill(.secondary).frame(width: 2, height: 24)
                }
            }
        case .b:
            // Over the crosswalk's middle
            Annotation("", coordinate: middle(crossing), anchor: .center) {
                HStack(spacing: 5) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(.tint))
                    Text("Cross \(crossing.name)").font(.footnote.weight(.semibold))
                }
                .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                .glassEffect(.regular, in: Capsule())
            }
        case .c:
            // Along the street crossed, beside the crosswalk, as if painted on it
            Annotation("", coordinate: alongside(crossing), anchor: .center) {
                Text(crossing.name.uppercased())
                    .font(.system(size: 13, weight: .heavy)).kerning(1.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .rotationEffect(.degrees(upright(crossing.bearing + 90 - heading)))
            }
        }
    }

    private func middle(_ crossing: Crossing) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (crossing.from.latitude + crossing.to.latitude) / 2,
                               longitude: (crossing.from.longitude + crossing.to.longitude) / 2)
    }

    /// The crossing's middle, moved 14 m along the street crossed to the side away from the line.
    private func alongside(_ crossing: Crossing) -> CLLocationCoordinate2D {
        let center = middle(crossing)
        let angle = (crossing.bearing - 90) * .pi / 180
        return CLLocationCoordinate2D(
            latitude: center.latitude + 14 * cos(angle) / 111_000,
            longitude: center.longitude + 14 * sin(angle) / (111_000 * cos(center.latitude * .pi / 180)))
    }

    /// Screen degrees turned so text never reads upside down.
    private func upright(_ degrees: Double) -> Double {
        var d = (degrees + 360).truncatingRemainder(dividingBy: 360)
        if d > 90 && d < 270 { d -= 180 }
        return d
    }

    // MARK: The walk

    /// A real walk down 4th Ave from 5th St to the R at 9th St, put on the sidewalk as walks are,
    /// its crossings named by Apple's reverse geocoder where it can (logged), by order otherwise.
    private func load() async {
        let request = MKDirections.Request()
        let start = CLLocationCoordinate2D(latitude: 40.67385, longitude: -73.98640)
        let end = CLLocationCoordinate2D(latitude: 40.67080, longitude: -73.98880)
        request.source = MKMapItem(location: CLLocation(latitude: start.latitude, longitude: start.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: end.latitude, longitude: end.longitude), address: nil)
        request.transportType = .walking
        guard let found = try? await MKDirections(request: request).calculate().routes.first else {
            print("MOCK: no route")
            return
        }
        var walk = WalkingDirections.walk(of: found)
        if let fitted = await SidewalkStore.shared.fit(walk, from: Walk.Point(start), to: Walk.Point(end)) {
            walk = fitted
        } else {
            print("MOCK: not fitted")
        }
        let points = walk.points.map(\.coordinate)
        // You just round the corner onto 4th Ave, so the crossings down it are ahead
        let turn = walk.steps.first?.points.last?.coordinate ?? points[0]
        let from = points.firstIndex { $0.latitude == turn.latitude && $0.longitude == turn.longitude } ?? 0
        route = Array(points[from...])
        let known = ["6th St", "7th St", "8th St", "9th St"]
        var found2: [Crossing] = []
        for (index, crossing) in (walk.crossings ?? []).enumerated() {
            guard let a = crossing.first?.coordinate, let b = crossing.last?.coordinate else { continue }
            var item = Crossing(id: index, from: a, to: b, name: "")
            let mid = middle(item)
            var geocoded = "?"
            if let request = MKReverseGeocodingRequest(location: CLLocation(latitude: mid.latitude, longitude: mid.longitude)),
               let items = try? await request.mapItems, let first = items.first {
                geocoded = first.address?.shortAddress ?? first.name ?? "?"
            }
            print("MOCK crossing \(index) at \(mid.latitude),\(mid.longitude) bearing \(Int(item.bearing)): \(geocoded)")
            item.name = geocoded
            found2.append(item)
        }
        // Those down 4th Ave, named by order for the look (the geocoder's are in the log)
        let ahead = found2.filter { crossing in
            route.contains { abs($0.latitude - crossing.from.latitude) < 1e-9 && abs($0.longitude - crossing.from.longitude) < 1e-9 }
        }
        crossings = ahead.enumerated().map { offset, crossing in
            var named = crossing
            named.name = offset < known.count ? known[offset] : crossing.name
            return named
        }
        print("MOCK: \(found2.count) crossings, \(crossings.count) ahead")
        guard route.count > 1 else { return }
        let you = route[0]
        let next = route.first { CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            .distance(from: CLLocation(latitude: you.latitude, longitude: you.longitude)) > 8 } ?? route[1]
        heading = Crossing.bearing(you, next)
        let angle = heading * .pi / 180
        let lead = 75.0
        let center = CLLocationCoordinate2D(
            latitude: you.latitude + lead * cos(angle) / 111_000,
            longitude: you.longitude + lead * sin(angle) / (111_000 * cos(you.latitude * .pi / 180)))
        position = .camera(MapCamera(centerCoordinate: center, distance: 330, heading: heading, pitch: 45))
    }

    // MARK: Around the map

    private var walker: some View {
        Image(systemName: "figure.walk")
            .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(.tint))
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }

    private var turnCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.up")
                .font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("320 m").font(.title.weight(.bold))
                Text("Down the stairs at 4 Av & 9 St").font(.title3.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var trainCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("R to 49 St").font(.headline)
                Text("Leaves in 6 min · 4 min walk").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(style.title).font(.caption.weight(.bold)).padding(8)
                .background(.yellow.opacity(0.9), in: Capsule()).foregroundStyle(.black)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
    }
}
