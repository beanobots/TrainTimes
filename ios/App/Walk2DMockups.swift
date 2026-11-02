import MapKit
import SwiftUI

// Throwaway mockups: the walking map in 2D, against the 3D over-the-shoulder view it has now.
// Map tiles don't draw in previews, so it's run in the simulator with `-walk2d now|a|b` (and
// `-dark`), a hook in LeewayApp. Delete this and the hook once one's picked and built.

/// The preview walk's: along 9th St to 4th Ave, then left onto it.
private enum MockWalk {
    static let corner = CLLocationCoordinate2D(latitude: 40.6725, longitude: -73.9880)
    static let entrance = CLLocationCoordinate2D(latitude: 40.6700, longitude: -73.9898)
    /// You, a third of the way to the corner.
    static let you = CLLocationCoordinate2D(latitude: 40.6725, longitude: -73.9853)
    static var route: [CLLocationCoordinate2D] { [you, corner, entrance] }

    static var heading: Double {
        let north = corner.latitude - you.latitude
        let east = (corner.longitude - you.longitude) * cos(you.latitude * .pi / 180)
        return (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The map's centre `meters` ahead of you the way it's turned.
    static func ahead(_ meters: Double) -> CLLocationCoordinate2D {
        let angle = heading * .pi / 180
        return CLLocationCoordinate2D(
            latitude: you.latitude + meters * cos(angle) / 111_000,
            longitude: you.longitude + meters * sin(angle) / (111_000 * cos(you.latitude * .pi / 180)))
    }
}

struct Walk2DMockup: View {
    enum Look: String {
        case now, a, b

        var title: String {
            switch self {
            case .now: "Now · 3D"
            case .a: "A · 2D flat"
            case .b: "B · 2D tipped"
            }
        }
        var flat: Bool { self != .now }
        var distance: Double {
            switch self {
            case .now: 90
            case .a: 400
            case .b: 330
            }
        }
        var pitch: Double {
            switch self {
            case .now: 75
            case .a: 0
            case .b: 45
            }
        }
        /// Metres ahead of you the centre is, so you're low on the screen.
        var lead: Double {
            switch self {
            case .now: 9
            case .a: 70
            case .b: 75
            }
        }
    }

    static var launchLook: Look? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-walk2d"), index + 1 < args.count else { return nil }
        return Look(rawValue: args[index + 1])
    }

    let look: Look

    var body: some View {
        map
            .ignoresSafeArea()
            .overlay(alignment: .top) { turnCard }
            .overlay(alignment: .bottom) { trainCard }
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-dark") ? .dark : .light)
    }

    private var map: some View {
        Map(initialPosition: .camera(MapCamera(centerCoordinate: MockWalk.ahead(look.lead), distance: look.distance,
                                                heading: MockWalk.heading, pitch: look.pitch))) {
            MapPolyline(coordinates: MockWalk.route)
                .stroke(.white, style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: MockWalk.route)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: MockWalk.route)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 9]))
            Annotation("", coordinate: MockWalk.corner, anchor: .bottom) { sign }
            Annotation("", coordinate: MockWalk.you, anchor: .center) { walker }
        }
        .mapStyle(.standard(elevation: look.flat ? .flat : .realistic, pointsOfInterest: .excludingAll))
        .mapControls {}
    }

    private var sign: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.up.left")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Circle().fill(.tint))
                Text("4th Ave").font(.subheadline.weight(.semibold))
            }
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            // Standing on its pole only when tipped back; flat, it lies at the corner
            if look.pitch > 30 {
                Rectangle().fill(.secondary).frame(width: 2, height: 34)
            }
        }
    }

    /// You, with the cone the way you face, laid on the street as it's tipped.
    private var walker: some View {
        ZStack {
            Path { path in
                let c = CGPoint(x: 46, y: 46)
                path.move(to: c)
                path.addArc(center: c, radius: 46, startAngle: .degrees(-122), endAngle: .degrees(-58), clockwise: false)
                path.closeSubpath()
            }
            .fill(RadialGradient(colors: [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: 46))
            .frame(width: 92, height: 92)
            .scaleEffect(x: 1, y: cos(look.pitch * .pi / 180))
            Image(systemName: "figure.walk")
                .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.tint))
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
    }

    private var turnCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.turn.up.left")
                .font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("210 m").font(.title.weight(.bold))
                Text("Take a left onto 4th Ave").font(.title3.weight(.semibold))
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
            Text(look.title).font(.caption.weight(.bold)).padding(8)
                .background(.yellow.opacity(0.9), in: Capsule()).foregroundStyle(.black)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
    }
}
