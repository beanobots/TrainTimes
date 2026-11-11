import CoreLocation
import MapKit
import SwiftUI

/// Where the app's to think the phone is, for this run only: while set, every reader of your
/// location (Nearby, New Trip, walks, rides) takes it as a fresh, precise fix and ignores real
/// ones; cleared, they go back to real fixes. The compass heading stays real, and so does
/// MapKit's own blue dot where a map shows it.
@MainActor
@Observable
final class PretendLocation {
    static let shared = PretendLocation()

    /// The pretend spot, or nil for the real one.
    private(set) var coordinate: CLLocationCoordinate2D?
    /// The quick pick's name, if it was one.
    private(set) var name: String?

    @ObservationIgnored private var listeners: [Listener] = []

    private struct Listener {
        weak var owner: AnyObject?
        let moved: @MainActor (CLLocation?) -> Void
    }

    private init() {}

    /// The pretend spot as a fix just taken, good to a few metres; nil if not pretending.
    static var current: CLLocation? {
        shared.coordinate.map {
            CLLocation(coordinate: $0, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now)
        }
    }

    /// Pretends the phone's at `coordinate`, or back to real with nil.
    func set(_ coordinate: CLLocationCoordinate2D?, name: String? = nil) {
        self.coordinate = coordinate
        self.name = coordinate == nil ? nil : name
        let fix = Self.current
        listeners.removeAll { $0.owner == nil }
        for listener in listeners { listener.moved(fix) }
    }

    /// Tells `moved` each time the spot's set (the new fix) or cleared (nil), for as long as
    /// `owner` is around.
    func listen(_ owner: AnyObject, moved: @escaping @MainActor (CLLocation?) -> Void) {
        listeners.removeAll { $0.owner == nil || $0.owner === owner }
        listeners.append(Listener(owner: owner, moved: moved))
    }
}

/// Pick a spot on the map (tap, or drag the pin) or a quick pick, and the app acts as if you're
/// there; Back to Real Location to stop.
struct PretendLocationTool: View {
    @State private var pretend = PretendLocation.shared
    @State private var camera: MapCameraPosition = .region(Self.startRegion)
    /// Where the pin's being dragged, before it's let go.
    @State private var dragging: CLLocationCoordinate2D?

    private struct Pick: Identifiable {
        let name: String
        let latitude: Double
        let longitude: Double
        var id: String { name }
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    private static let picks = [
        Pick(name: "Times Sq", latitude: 40.75800, longitude: -73.98550),
        Pick(name: "Atlantic Av–Barclays", latitude: 40.68380, longitude: -73.97880),
        Pick(name: "Jackson Heights", latitude: 40.74690, longitude: -73.89140),
        Pick(name: "Harlem 125 St", latitude: 40.80790, longitude: -73.94550),
        Pick(name: "St George, Staten Island", latitude: 40.64350, longitude: -74.07400),
    ]

    private static var startRegion: MKCoordinateRegion {
        let center = PretendLocation.shared.coordinate ?? CLLocationCoordinate2D(latitude: 40.73, longitude: -73.96)
        let span = PretendLocation.shared.coordinate == nil ? 0.25 : 0.03
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    var body: some View {
        List {
            Section {
                MapReader { proxy in
                    Map(position: $camera) {
                        UserAnnotation()
                        if let spot = dragging ?? pretend.coordinate {
                            Annotation("Pretend", coordinate: spot, anchor: .bottom) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.white, .purple)
                                    .highPriorityGesture(DragGesture(coordinateSpace: .named("pretendMap"))
                                        .onChanged { drag in
                                            dragging = proxy.convert(drag.location, from: .named("pretendMap"))
                                        }
                                        .onEnded { drag in
                                            dragging = nil
                                            if let spot = proxy.convert(drag.location, from: .named("pretendMap")) {
                                                pretend.set(spot)
                                            }
                                        })
                            }
                        }
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .coordinateSpace(.named("pretendMap"))
                    .onTapGesture { point in
                        if let spot = proxy.convert(point, from: .named("pretendMap")) { pretend.set(spot) }
                    }
                }
                .frame(height: 320)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Tap the map or drag the pin. The blue dot is still the real you.")
            }

            Section("Quick Picks") {
                ForEach(Self.picks) { pick in
                    Button {
                        pretend.set(pick.coordinate, name: pick.name)
                        withAnimation(.smooth) {
                            camera = .region(MKCoordinateRegion(center: pick.coordinate, latitudinalMeters: 2_000,
                                                                longitudinalMeters: 2_000))
                        }
                    } label: {
                        HStack {
                            Text(pick.name)
                            Spacer()
                            if pretend.name == pick.name {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }

            Section {
                if let spot = pretend.coordinate {
                    LabeledContent("Pretending", value: pretend.name
                        ?? String(format: "%.5f, %.5f", spot.latitude, spot.longitude))
                }
                Button("Back to Real Location", role: .destructive) { pretend.set(nil) }
                    .disabled(pretend.coordinate == nil)
            } footer: {
                Text("Lasts until the app's relaunched. Widgets and the compass still use the real location.")
            }
        }
    }
}
