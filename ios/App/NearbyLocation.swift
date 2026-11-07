import CoreLocation
import Observation
import WidgetKit

/// Your location for nearby stations. Permission is asked only on tap; then it's looked up once
/// each time the station list opens (`start()` sets the delegate, which reports authorization
/// and triggers a lookup).
@MainActor
@Observable
final class NearbyLocation: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    private(set) var location: CLLocation?
    /// The last lookup failed (e.g. indoors, or no simulator location).
    private(set) var failed = false
    /// Precise Location is on, or not asked yet: off, a fix is only good to a few miles.
    private(set) var isPrecise: Bool
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        isPrecise = Self.precise(manager)
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Starts listening (and locating, if allowed). Called on appear, not in `init`: SwiftUI
    /// recreates and discards `@State` values on rebuilds, and those mustn't look you up.
    func start() {
        guard manager.delegate == nil else { return }
        manager.delegate = self
    }

    var isAllowed: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    private nonisolated static func precise(_ manager: CLLocationManager) -> Bool {
        manager.authorizationStatus == .notDetermined || manager.accuracyAuthorization == .fullAccuracy
    }

    /// Asks permission the first time; afterwards locates you if allowed.
    func find() {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAllowed {
            failed = false
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let precise = Self.precise(manager)
        Task { @MainActor in
            self.isPrecise = precise
            // The Nearby widget uses the same permission
            if status != self.status {
                WidgetCenter.shared.reloadTimelines(ofKind: Nearby.widgetKind)
            }
            self.status = status
            if self.isAllowed { self.find() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.location = location
            self.failed = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // Report failure only if there's no earlier fix to fall back on
            if self.location == nil { self.failed = true }
        }
    }
}
