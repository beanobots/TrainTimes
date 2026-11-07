import SwiftUI
import MapKit

// Throwaway mockups: lines of one colour along one track drawn as one line with each line's
// bullet. Delete once the real one's built.

/// The trip in the screenshot: the R from 4 Av-9 St to DeKalb Av, the Q on to 34 St-Herald Sq;
/// or change at Atlantic Av to the N (yellow, along the Q) or the D (orange).
private struct MockTrip {
    let r: [CLLocationCoordinate2D]
    let q: [CLLocationCoordinate2D]
    let n: [CLLocationCoordinate2D]
    let d: [CLLocationCoordinate2D]
    let start: CLLocationCoordinate2D
    let dekalb: CLLocationCoordinate2D
    let atlantic: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D

    init() {
        func at(_ id: String) -> CLLocationCoordinate2D { StationDirectory.station(id: id)?.coordinate ?? .init() }
        func track(_ route: String, _ from: String, _ to: String) -> [CLLocationCoordinate2D] {
            TripMap.densified(TrackShapes.rounded(TrackShapes.track(of: route, from: at(from), to: at(to)) ?? [at(from), at(to)]))
        }
        r = track("R", "R33", "R30")
        q = track("Q", "R30", "R17")
        n = track("N", "R31", "R17")
        d = track("D", "R31", "D17")
        start = at("R33"); dekalb = at("R30"); atlantic = at("R31"); end = at("R17")
    }

    /// The map's area, 34 St to 9 St.
    var rect: MKMapRect {
        let points = [start, end, at(-73.995, 40.705), at(-73.965, 40.705)].map(MKMapPoint.init)
        let xs = points.map(\.x), ys = points.map(\.y)
        return MKMapRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -2_500, dy: -2_500)
    }

    private func at(_ lon: Double, _ lat: Double) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

private enum Style: String {
    /// As now: the N moved out beside the Q.
    case now = "Now"
    /// One yellow line where they run together, both bullets on it.
    case joined = "One line, bullets together"
    /// One yellow line, each bullet on its own stretch.
    case apart = "One line, bullets apart"
}

private struct SameColorMap: View {
    let style: Style
    private let trip = MockTrip()

    var body: some View {
        GeometryReader { geometry in
            let rect = trip.rect
            let perPoint = rect.width / max(geometry.size.width, 1)
            let yellow = LineStyle.of("Q").swiftUIColor
            let orange = LineStyle.of("D").swiftUIColor
            // Moved out beside the trip's line, as `TripMap.beside`
            let besideOut = (7.0 + 4) / 2 + 11.0 / 2
            Map(initialPosition: .rect(rect), interactionModes: []) {
                // The D from Atlantic Av, beside the others as now
                MapPolyline(coordinates: TripMap.offset(trip.d, by: -besideOut * perPoint))
                    .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: TripMap.offset(trip.d, by: -besideOut * perPoint))
                    .stroke(orange, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                if style == .now {
                    MapPolyline(coordinates: TripMap.offset(trip.n, by: besideOut * perPoint))
                        .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: TripMap.offset(trip.n, by: besideOut * perPoint))
                        .stroke(yellow, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array([trip.r, trip.q].enumerated()), id: \.offset) { _, line in
                    MapPolyline(coordinates: line)
                        .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array([trip.r, trip.q].enumerated()), id: \.offset) { _, line in
                    MapPolyline(coordinates: line)
                        .stroke(yellow, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
                Annotation("", coordinate: trip.dekalb) { ring }
                Annotation("", coordinate: trip.atlantic, anchor: .leading) {
                    HStack(spacing: 6) {
                        ring
                        Text("or Atlantic Av").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.background.opacity(0.8), in: Capsule())
                    }
                    .offset(x: -8)
                }
                Annotation("", coordinate: point(on: trip.r, at: 0.5)) { bullets(["R"]) }
                switch style {
                case .now:
                    Annotation("", coordinate: point(on: trip.q, at: 0.4)) { bullets(["Q"]) }
                case .joined:
                    Annotation("", coordinate: point(on: trip.q, at: 0.4)) { bullets(["Q", "N"]) }
                case .apart:
                    Annotation("", coordinate: point(on: trip.q, at: 0.3)) { bullets(["Q"]) }
                    Annotation("", coordinate: point(on: trip.q, at: 0.6)) { bullets(["N"]) }
                }
                Annotation("", coordinate: trip.start) {
                    Circle().fill(.blue).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 2)
                }
                Marker("Work", systemImage: "mappin", coordinate: trip.end).tint(.red)
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .overlay(alignment: .top) {
                Text(style.rawValue)
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect()
                    .padding(.top, 60)
            }
        }
        .ignoresSafeArea()
    }

    private var ring: some View {
        Circle().fill(.white).frame(width: 12, height: 12)
            .overlay(Circle().stroke(.black, lineWidth: 3))
    }

    private func bullets(_ routes: [String]) -> some View {
        HStack(spacing: 2) {
            ForEach(routes, id: \.self) { route in
                LineBullet(route: route, size: 20)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(radius: 1)
            }
        }
    }

    /// The point `part` of the way along `line`, by its points.
    private func point(on line: [CLLocationCoordinate2D], at part: Double) -> CLLocationCoordinate2D {
        line.isEmpty ? .init() : line[min(line.count - 1, Int(Double(line.count - 1) * part))]
    }
}

#Preview("Now") { SameColorMap(style: .now) }
#Preview("One line, bullets together") { SameColorMap(style: .joined) }
#Preview("One line, bullets apart") { SameColorMap(style: .apart) }
