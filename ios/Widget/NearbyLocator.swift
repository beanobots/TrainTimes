import CoreLocation

/// Your location for the Nearby widget, found on each reload using the app's permission
/// (While Using the App or Widgets).
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
    /// Gives up after `locate(waiting:)`'s wait; cancelled once there's an answer.
    private var timeout: Task<Void, Never>?

    /// Max age of iOS's cached location to use instead of a new fix; younger than this, the
    /// widget treats it as current.
    nonisolated static let recent: TimeInterval = 2 * 60

    /// How long the widget waits for the place name after the trains load.
    nonisolated static let nameWait: TimeInterval = 1

    /// How old a fix found by either widget (`savedFix`) can be and still stand for where you
    /// are, rather than finding you again: Transit Directions' Nearby. The widgets' processes
    /// don't share iOS's cached fix, nor keep it long.
    nonisolated static let savedFixLife: TimeInterval = 5 * 60

    /// How long the widgets wait for a new fix. iOS serves one widget's timeline at a time,
    /// so a long wait here holds up the others' taps too.
    nonisolated static let wait: TimeInterval = 3

    /// What `atOnce()` says if it can say without waiting, else a new fix within `wait`, else
    /// one from the last hour.
    static func locateQuickly() async -> Outcome {
        if let outcome = atOnce() { return outcome }
        return await locate(waiting: wait)
    }

    /// Waits up to `wait` seconds for a new fix, then falls back to one from the last hour.
    static func locate(waiting wait: TimeInterval = 10) async -> Outcome {
        await NearbyLocator().locate(waiting: wait)
    }

    /// What `locate()` would say without waiting: location off, or iOS's recent accurate fix, or
    /// one either widget found within `savedFixLife`; nil if it would have to wait for a new one.
    static func atOnce() -> Outcome? {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .notDetermined: return .notAllowed(asked: false)
        case .denied, .restricted: return .notAllowed(asked: true)
        default: break
        }
        if let last = manager.location, Date.now.timeIntervalSince(last.timestamp) < recent,
           last.horizontalAccuracy >= 0, last.horizontalAccuracy <= 100 {
            return .found(last)
        }
        return savedFix(at: .now).map(Outcome.found)
    }

    private func locate(waiting wait: TimeInterval) async -> Outcome {
        switch manager.authorizationStatus {
        case .notDetermined: return .notAllowed(asked: false)
        case .denied, .restricted: return .notAllowed(asked: true)
        default: break
        }
        // A recent, accurate cached fix is as good as a new one and avoids the wait
        if let last = manager.location, Date.now.timeIntervalSince(last.timestamp) < Self.recent,
           last.horizontalAccuracy >= 0, last.horizontalAccuracy <= 100 {
            Self.save(last)
            return .found(last)
        }
        if manager.isAuthorizedForWidgetUpdates, let location = await requestLocation(waiting: wait) {
            Self.save(location)
            return .found(location)
        }
        // Fall back to a fix from the last hour, iOS's or either widget's; the widgets show its age
        if let last = manager.location, Date.now.timeIntervalSince(last.timestamp) < 60 * 60 {
            return .found(last)
        }
        if let saved = Self.savedFix(at: .now, within: 60 * 60) {
            return .found(saved)
        }
        return .notFound
    }

    /// Nil if there's no fix within `wait` seconds.
    private func requestLocation(waiting wait: TimeInterval) async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestLocation()
            timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait))
                if !Task.isCancelled { self.finish(nil) }
            }
        }
    }

    // MARK: Saved fix

    private nonisolated static let fixFile = SharedStore.url(named: "nearby-fix.json")

    /// The last new fix either widget found, if taken within `life` (`savedFixLife`) of `date`.
    nonisolated static func savedFix(at date: Date, within life: TimeInterval = savedFixLife) -> CLLocation? {
        guard let fix = SharedStore.loadNearbyFix(at: date, within: life) else { return nil }
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude),
                          altitude: 0, horizontalAccuracy: fix.accuracy, verticalAccuracy: -1, timestamp: fix.taken)
    }

    private static func save(_ location: CLLocation) {
        let fix = SharedStore.NearbyFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                        accuracy: location.horizontalAccuracy, taken: location.timestamp)
        guard let fixFile, let data = try? JSONEncoder().encode(fix) else { return }
        try? data.write(to: fixFile, options: .atomic)
    }

    private func finish(_ location: CLLocation?) {
        timeout?.cancel()
        timeout = nil
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

    /// The neighborhood name, e.g. "Park Slope", or nil. Only re-geocoded after you've moved
    /// 250 m from the saved place, since Apple rate-limits lookups.
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
