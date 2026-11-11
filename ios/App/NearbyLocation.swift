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
    /// Location permission as last seen, for reloading the Nearby widget once when it changes.
    private static let seenStatusKey = "nearbyLocationStatus"

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
        // Prototyping's Pretend Location: its spot as each fix while set, real ones once it's cleared
        PretendLocation.shared.listen(self) { [weak self] pretend in
            guard let self else { return }
            if let pretend {
                self.location = pretend
                self.failed = false
            } else {
                // Kept till the real fix comes, unless none can
                if !self.isAllowed { self.location = nil }
                self.find()
            }
        }
    }

    var isAllowed: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    private nonisolated static func precise(_ manager: CLLocationManager) -> Bool {
        manager.authorizationStatus == .notDetermined || manager.accuracyAuthorization == .fullAccuracy
    }

    /// Asks permission the first time; afterwards locates you if allowed. Pretend Location's
    /// spot instead, while set.
    func find() {
        // CoreLocation aborts on `requestLocation()` without a delegate, and callers can come
        // before `start()` (e.g. an `onChange(initial:)` firing ahead of `onAppear`)
        start()
        if let pretend = PretendLocation.current {
            location = pretend
            failed = false
        } else if status == .notDetermined {
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
            // The Nearby widget uses the same permission: reloaded once when it changes, however
            // many of these are listening, by the last any saw (in the App Group's defaults)
            let defaults = UserDefaults(suiteName: SharedStore.groupID)
            let last = defaults?.object(forKey: Self.seenStatusKey) as? Int ?? Int(self.status.rawValue)
            if Int(status.rawValue) != last {
                defaults?.set(Int(status.rawValue), forKey: Self.seenStatusKey)
                WidgetCenter.shared.reloadTimelines(ofKind: Nearby.widgetKind)
            }
            self.status = status
            if self.isAllowed { self.find() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Not one CoreLocation marks invalid (a negative accuracy) over a good one
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        Task { @MainActor in
            guard PretendLocation.shared.coordinate == nil else { return }
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
