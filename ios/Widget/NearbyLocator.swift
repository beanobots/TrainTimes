import CoreLocation

/// Where you are, for the Nearby widget: found afresh each time it reloads,
/// with the app's permission (While Using the App or Widgets).
@MainActor
final class NearbyLocator: NSObject, CLLocationManagerDelegate {
    enum Outcome {
        case found(CLLocation)
        /// Location is off for the app, or (`asked` false) it hasn't asked yet.
        case notAllowed(asked: Bool)
        case notFound
    }

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    static func locate() async -> Outcome {
        await NearbyLocator().locate()
    }

    private func locate() async -> Outcome {
        switch manager.authorizationStatus {
        case .notDetermined: return .notAllowed(asked: false)
        case .denied, .restricted: return .notAllowed(asked: true)
        default: break
        }
        if manager.isAuthorizedForWidgetUpdates, let location = await requestLocation() {
            return .found(location)
        }
        // Where iOS last found you, if it was lately
        if let last = manager.location, Date.now.timeIntervalSince(last.timestamp) < 60 * 60 {
            return .found(last)
        }
        return .notFound
    }

    /// Nil when there's no finding you within 10 seconds.
    private func requestLocation() async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self.finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    /// What the place you're in is called, "Park Slope", looked up only once
    /// you've moved on from where it last was: Apple limits how often an app
    /// can. Nil when there's no name for it.
    static func placeName(for location: CLLocation) async -> String? {
        if let saved = SharedStore.loadPlace(), saved.name != nil,
           CLLocation(latitude: saved.latitude, longitude: saved.longitude).distance(from: location) < 250 {
            return saved.name
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        let name = placemark?.subLocality ?? placemark?.locality
        SharedStore.savePlace(SharedStore.Place(latitude: location.coordinate.latitude,
                                                longitude: location.coordinate.longitude, name: name))
        return name
    }
}
