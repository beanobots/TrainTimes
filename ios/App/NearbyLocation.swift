import CoreLocation
import Observation

/// Where you are, for the stations near you: asked for only when you tap to
/// see them, then found once each time the station list opens (the manager
/// reports its authorization as `start()` sets it going, which looks you up).
@MainActor
@Observable
final class NearbyLocation: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    private(set) var location: CLLocation?
    /// The last try to find you didn't, e.g. indoors or with no location set in the simulator.
    private(set) var failed = false
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Starts listening, which finds you if you've allowed it. Called as its view
    /// appears rather than in `init`: SwiftUI makes a view's `@State` value again
    /// each time the view is rebuilt and throws the extra ones away, and those
    /// mustn't look you up.
    func start() {
        guard manager.delegate == nil else { return }
        manager.delegate = self
    }

    var isAllowed: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    /// Asks the first time; after that, finds you if you've allowed it.
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
        Task { @MainActor in
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
            // Without a fix to fall back on, say so rather than keep looking
            if self.location == nil { self.failed = true }
        }
    }
}
