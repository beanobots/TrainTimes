import MapKit
import SwiftUI
import UIKit

/// The app on its side, an iPhone in landscape: each tab's card stands down the left over a map
/// rather than across its foot, the same width on every tab. Walks stay upright (`lockUpright`).
enum Sideways {
    /// The card's width: room for a medium widget (`WidgetLook.medium`) and its margins.
    static let width: CGFloat = 360
    /// In from the side's safe area, and up from the tab bar.
    static let inset: CGFloat = 8
    /// Down from the top, clear of the screen's rounded corner.
    static let top: CGFloat = 16
    /// The map's room on its left for the card, its logo and Legal just past it.
    static let mapLeading: CGFloat = width + inset + 12
    static let card = RoundedRectangle(cornerRadius: 26, style: .continuous)

    /// Whether the app may turn on its side: not under a walk, whose map is drawn upright.
    @MainActor static var orientations: UIInterfaceOrientationMask {
        ActiveWalk.shared.session == nil ? .allButUpsideDown : .portrait
    }

    /// Turns the app upright for a walk, or lets it turn again after one.
    @MainActor static func lockUpright(_ upright: Bool) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            // Each controller up to the walk's cover, which decides
            var controller = scene.keyWindow?.rootViewController
            while let shown = controller {
                shown.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = shown.presentedViewController
            }
            if upright { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        }
    }
}

extension EnvironmentValues {
    /// On its side: an iPhone in landscape, short of height.
    var isSideways: Bool { verticalSizeClass == .compact }
}

extension View {
    /// A tab's page as Nearby's card on its side: down the left over a map. Upright, as it was.
    func sidewaysCard() -> some View {
        modifier(SidewaysCard())
    }
}

/// The card's corners on its side. Upright, far past the page on every side, so the scroll isn't
/// cut at the safe area: a plain rectangle there clips it to a hard line under the bars.
private struct SidewaysClip: Shape {
    var on: Bool

    func path(in rect: CGRect) -> Path {
        on ? Sideways.card.path(in: rect) : Path(rect.insetBy(dx: -10_000, dy: -10_000))
    }
}

/// The same modifiers either way, so turning keeps the page's scroll and state.
private struct SidewaysCard: ViewModifier {
    @Environment(\.isSideways) private var sideways

    func body(content: Content) -> some View {
        content
            .frame(width: sideways ? Sideways.width : nil)
            .frame(maxHeight: .infinity)
            // Upright, nothing clipped: the scroll runs under the bars to their soft edge
            .clipShape(SidewaysClip(on: sideways))
            .glassEffect(sideways ? .regular : .identity, in: Sideways.card)
            .padding(.leading, sideways ? Sideways.inset : 0)
            .padding(.top, sideways ? Sideways.top : 0)
            .padding(.bottom, sideways ? Sideways.inset : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if sideways { SidewaysMap() }
            }
    }
}

/// The map behind Routes' and Settings' cards on its side: around where you were last found,
/// turned Grid North if Settings says. The whole screen, framed past the card, its logo and Legal
/// level with the card's foot, over the tab bar. Held there, with no dot for you: following you,
/// MapKit kept best-accuracy GPS on behind pages that don't need it.
private struct SidewaysMap: View {
    private static let city = CLLocationCoordinate2D(latitude: 40.73, longitude: -73.97)
    @State private var position = MapCameraPosition.region(SidewaysMap.region(around: SidewaysMap.city))
    /// The screen's safe area: the side's and the tab bar's. Measured behind the map, as the map
    /// itself, under `ignoresSafeArea`, has none.
    @State private var room = EdgeInsets()

    private static func region(around center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: 8_000, longitudinalMeters: 8_000)
    }

    /// The last fix any of the app's lookups had, without starting one; nil if none, or if it's
    /// out of the city (the map's always somewhere in it).
    private static var lastFix: CLLocationCoordinate2D? {
        guard let here = PretendLocation.current ?? CLLocationManager().location,
              here.distance(from: CLLocation(latitude: city.latitude, longitude: city.longitude)) < 50_000 else { return nil }
        return here.coordinate
    }

    var body: some View {
        Map(position: $position)
        .onAppear {
            if let here = Self.lastFix { position = .region(Self.region(around: here)) }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .turnsNorth($position)
        .safeAreaPadding(.top, room.top + Sideways.top)
        .safeAreaPadding(.bottom, room.bottom + Sideways.inset)
        .safeAreaPadding(.leading, room.leading + Sideways.mapLeading)
        .safeAreaPadding(.trailing, room.trailing)
        .ignoresSafeArea()
        // Only a backdrop behind the card, nothing on it to read or press
        .accessibilityHidden(true)
        .background {
            Color.clear.onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { room = $0 }
        }
    }
}
