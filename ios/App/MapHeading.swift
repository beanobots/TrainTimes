import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftUI

/// Which way up the walking map is, the compass button going between them: your heading (the
/// way the route runs while walking it, the compass otherwise), or north, as Settings' NY
/// Special has it (`MapNorth`).
enum MapTurn {
    case heading
    case north

    /// Degrees east of true north Manhattan's avenues run: the grid's 29°.
    static let manhattanNorth: Double = 29

    /// The next, as the button's tapped.
    var next: MapTurn {
        switch self {
        case .heading: .north
        case .north: .heading
        }
    }

    func label(ny: Bool) -> String {
        switch self {
        case .heading: "The way you're going"
        case .north: ny ? "Grid North, the avenues up" : "North up"
        }
    }
}

/// Which way up every map is: north, or with Settings' Grid North on, Grid North, Manhattan's
/// avenues up the screen as New Yorkers think of uptown.
enum MapNorth {
    static let key = "nyNorth"

    static func heading(ny: Bool) -> Double { ny ? MapTurn.manhattanNorth : 0 }

    /// Metres a camera shows top to bottom, per metre it's up, looking straight down: the same
    /// whatever the map's size (measured from MapKit).
    static let metresTallPerDistance = 0.537

    /// Whether `heading` is off `north` by more than a degree, the shorter way round.
    static func isOff(_ heading: Double, from north: Double) -> Bool {
        abs((heading - north + 540).truncatingRemainder(dividingBy: 360) - 180) > 1
    }

    /// `rect` framed on a map turned to `heading`, in `room` with `covered` points more over its
    /// foot (a card) to keep it clear of. Nil north up, where `.rect` and `.region` do it: they
    /// always turn the map north, so turned, it's a camera fitting the rect's corners as turned,
    /// its middle the room's. `northUp` makes the camera north up too, rather than nil.
    static func position(fitting rect: MKMapRect, heading: Double, in room: MapRoom,
                         covered: CGFloat = 0, northUp: Bool = false) -> MapCameraPosition? {
        let wide = room.size.width - room.insets.leading - room.insets.trailing
        let tall = room.size.height - room.insets.top - room.insets.bottom - covered
        guard heading != 0 || northUp, wide > 0, tall > 0, !rect.isNull, rect.width > 0 || rect.height > 0 else { return nil }
        let middle = MKMapPoint(x: rect.midX, y: rect.midY)
        let angle = heading * .pi / 180, c = cos(angle), s = sin(angle)
        // Each corner as screen right and up from the middle, in map points
        let corners = [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.minX, rect.maxY), (rect.maxX, rect.maxY)]
            .map { x, y in
                let east = x - middle.x, north = middle.y - y
                return (right: east * c - north * s, up: east * s + north * c)
            }
        let rights = corners.map(\.right), ups = corners.map(\.up)
        guard let minRight = rights.min(), let maxRight = rights.max(), let minUp = ups.min(), let maxUp = ups.max() else { return nil }
        let pointsPerMetre = MKMapPointsPerMeterAtLatitude(middle.coordinate.latitude)
        // Map points per screen point, the turned box just fitting
        let scale = max((maxRight - minRight) / Double(wide), (maxUp - minUp) / Double(tall))
        guard scale > 0 else { return nil }
        // The camera's middle is the safe area's; the box goes in the room's, above the cover
        let right = (minRight + maxRight) / 2
        let up = (minUp + maxUp) / 2 - Double(covered) / 2 * scale
        let east = right * c + up * s, north = -right * s + up * c
        let center = MKMapPoint(x: middle.x + east, y: middle.y - north).coordinate
        let distance = scale / pointsPerMetre * Double(room.size.height) / metresTallPerDistance
        return .camera(MapCamera(centerCoordinate: center, distance: distance, heading: heading))
    }

    /// The map points a screen point covers on a map `height` tall, from where it came to rest:
    /// its visible rect's height, north up; turned, that's the rect round the turned view, so
    /// from the camera's distance.
    static func mapPointsPerPoint(_ context: MapCameraUpdateContext, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        guard isOff(context.camera.heading, from: 0) else { return context.rect.height / Double(height) }
        return context.camera.distance * metresTallPerDistance
            * MKMapPointsPerMeterAtLatitude(context.camera.centerCoordinate.latitude) / Double(height)
    }

    /// The same, measured off the map itself: the map points between two screen points 100 apart
    /// at its middle. Turned, the camera's distance gave about twice what it is on a phone, and
    /// bus stems ran twice as far, through their tags and out the other side. Nil till it's laid out.
    static func mapPointsPerPoint(_ proxy: MapProxy, middle: CGPoint) -> Double? {
        guard let top = proxy.convert(middle, from: .local),
              let bottom = proxy.convert(CGPoint(x: middle.x, y: middle.y + 100), from: .local) else { return nil }
        let a = MKMapPoint(top), b = MKMapPoint(bottom)
        let scale = hypot(b.x - a.x, b.y - a.y) / 100
        return scale > 0 ? scale : nil
    }
}

/// The round glass buttons down a map's side, on every page: their size, and their icons'.
enum MapButton {
    static let size: CGFloat = 54
    static let icon: CGFloat = 20
}

/// A map's compass, always on it, as MapKit's is only once it's turned: its needle pointing
/// north as the map's turned. Tapped, the map's put north up; with Settings' Grid North on,
/// between North and Grid North, Grid North from any other way.
struct NorthButton: View {
    /// Which way the map's turned, degrees from north.
    let heading: Double
    /// Turns the map to the heading given.
    let turn: (Double) -> Void
    @AppStorage(MapNorth.key) private var nyNorth = false

    var body: some View {
        Button { turn(Self.next(from: heading, ny: nyNorth)) } label: {
            CompassNeedle(heading: heading, ny: nyNorth)
                .animation(.smooth, value: heading)
                .frame(width: MapButton.size, height: MapButton.size)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map direction")
        .accessibilityValue(value)
        .accessibilityHint(nyNorth ? "Switches between North and Grid North" : "Turns the map north up")
    }

    /// Where a tap turns a map turned `heading`.
    static func next(from heading: Double, ny: Bool) -> Double {
        ny && !MapNorth.isOff(heading, from: MapTurn.manhattanNorth) ? 0 : MapNorth.heading(ny: ny)
    }

    private var value: String {
        if !MapNorth.isOff(heading, from: 0) { return "North up" }
        if !MapNorth.isOff(heading, from: MapTurn.manhattanNorth) { return "Grid North, the avenues up" }
        return "Turned"
    }
}

/// A compass button's needle for a map turned `heading`: north's arrow; with Grid North on and
/// the map within `gridSnap` of it, Manhattan (`ManhattanIcon`) as the island lies on the map.
/// The two blur and scale into each other as the map crosses `gridSnap`.
struct CompassNeedle: View {
    let heading: Double
    let ny: Bool

    /// How near Grid North the map's to be turned for Manhattan to show, degrees either way.
    static let gridSnap: Double = 5

    /// Whether the map's turned near enough Grid North for Manhattan.
    private var atGrid: Bool {
        ny && abs(Self.turn(heading - MapTurn.manhattanNorth)) < Self.gridSnap
    }

    var body: some View {
        ZStack {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: MapButton.icon, weight: .semibold))
                .foregroundStyle(.red)
                .rotationEffect(.degrees(Self.turn(heading)))
                .opacity(atGrid ? 0 : 1)
                .scaleEffect(atGrid ? 0.6 : 1)
                .blur(radius: atGrid ? 3 : 0)
            ManhattanIcon()
                .fill(.red)
                .frame(width: 10, height: 26)
                .rotationEffect(.degrees(Self.turn(heading - MapTurn.manhattanNorth)))
                .opacity(atGrid ? 1 : 0)
                .scaleEffect(atGrid ? 1 : 0.6)
                .blur(radius: atGrid ? 0 : 3)
        }
        .animation(.smooth(duration: 0.35), value: atGrid)
    }

    /// -`degrees` put between -180 and 180, so it doesn't spin the long way round past upright.
    static func turn(_ degrees: Double) -> Double {
        -((degrees + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}

/// A map's size and the safe area MapKit frames in, for `MapNorth.position(fitting:)`.
struct MapRoom: Equatable {
    var size: CGSize = .zero
    var insets = EdgeInsets()
}

extension GeometryProxy {
    /// The whole view's size, its safe area too: `size` is only what's inside the safe area, so
    /// taking it for the map's whole size took the safe area off twice, and with the cards up
    /// framed the trips in a few points, zoomed right out.
    var wholeSize: CGSize {
        CGSize(width: size.width + safeAreaInsets.leading + safeAreaInsets.trailing,
               height: size.height + safeAreaInsets.top + safeAreaInsets.bottom)
    }
}

extension MKMapRect {
    /// The rect round `region`.
    init(_ region: MKCoordinateRegion) {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                                                  longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                                                  longitude: region.center.longitude + region.span.longitudeDelta / 2))
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

extension View {
    /// The map's size and safe area, kept in `room`. On the `Map` itself, inside any
    /// `safeAreaPadding`, to see it.
    func measuresRoom(_ room: Binding<MapRoom>) -> some View {
        onGeometryChange(for: MapRoom.self) { MapRoom(size: $0.wholeSize, insets: $0.safeAreaInsets) } action: {
            room.wrappedValue = $0
        }
    }

    /// Keeps a map turned as Settings has it (`MapNorth`): put north up by `.region`, `.rect`,
    /// `.automatic` or following you, it's turned where it rests, `widening` times as far out;
    /// and turned where it is as the setting changes. Not once you've moved or turned it, nor
    /// where it rests while `kept`, the page keeping it the way you turned it.
    func turnsNorth(_ position: Binding<MapCameraPosition>, widening: Double = 1, unless kept: Bool = false) -> some View {
        modifier(TurnsNorth(position: position, widening: widening, kept: kept))
    }
}

private struct TurnsNorth: ViewModifier {
    @Binding var position: MapCameraPosition
    let widening: Double
    let kept: Bool
    @AppStorage(MapNorth.key) private var nyNorth = false
    /// Where the map last came to rest.
    @State private var shown: MapCamera?

    func body(content: Content) -> some View {
        content
            .onMapCameraChange(frequency: .onEnd) { context in
                shown = context.camera
                let north = MapNorth.heading(ny: nyNorth)
                guard !kept, !position.positionedByUser, MapNorth.isOff(context.camera.heading, from: north) else { return }
                position = .camera(turned(context.camera, widening: widening))
            }
            .onChange(of: nyNorth) {
                guard let shown else { return }
                withAnimation(.smooth) { position = .camera(turned(shown, widening: 1)) }
            }
    }

    private func turned(_ camera: MapCamera, widening: Double) -> MapCamera {
        MapCamera(centerCoordinate: camera.centerCoordinate, distance: camera.distance * widening,
                  heading: MapNorth.heading(ny: nyNorth), pitch: camera.pitch)
    }
}

/// Which way the phone's pointing, from its compass, for turning the walking map. Raw: the map
/// smooths it (`MapHeading.smoothed(_:toward:over:)`).
@MainActor
@Observable
final class CompassHeading: NSObject, CLLocationManagerDelegate {
    /// Degrees from true north (magnetic where true can't be had); nil until the compass says.
    private(set) var heading: Double?
    @ObservationIgnored private let manager = CLLocationManager()

    /// Called on appear, not in `init`, as `NearbyLocation` is.
    func start() {
        manager.delegate = self
        // No finer than the map turns for (`MapHeading.still`): every degree was a wake-up and
        // a redraw for nothing
        manager.headingFilter = MapHeading.still
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard newHeading.headingAccuracy >= 0 else { return }
        Task { @MainActor in self.heading = heading }
    }

    /// No figure-of-eight screen over the map mid-walk.
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }
}

enum MapHeading {
    /// Degrees either way the phone may waver without the map turning at all.
    static let still: Double = 3
    /// Degrees within which a turn's taken slowly: a phone held as you walk, swinging with your
    /// steps or glanced at, not you turning a corner.
    static let smallArc: Double = 35
    /// Seconds to turn most of the way through a small arc, and a big one.
    static let slowly: TimeInterval = 4
    static let quickly: TimeInterval = 0.5

    /// `shown` turned toward `heading` for `seconds`: slowly through a small arc, quickly
    /// through a big one, not at all through a waver. `turning` is a big turn under way, taken
    /// quickly all the way round rather than slowing for its last small arc; kept between calls.
    static func smoothed(_ shown: Double, toward heading: Double, over seconds: TimeInterval,
                         turning: inout Bool) -> Double {
        // The shorter way round, -180 to 180
        let gap = (heading - shown + 540).truncatingRemainder(dividingBy: 360) - 180
        if abs(gap) >= smallArc { turning = true }
        guard abs(gap) > still else {
            turning = false
            return shown
        }
        let part = 1 - exp(-seconds / (turning ? quickly : slowly))
        return (shown + gap * part + 360).truncatingRemainder(dividingBy: 360)
    }
}
