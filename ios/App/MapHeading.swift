import CoreLocation
import Foundation
import Observation

/// Which way up the walking map is, the compass button going round them: your heading (the way
/// the route runs while walking it, the compass otherwise), north,
/// then "NY North", Manhattan's avenues up the screen as New Yorkers think of uptown.
enum MapTurn {
    case heading
    case north
    case manhattan

    /// Degrees east of true north Manhattan's avenues run: the grid's 29°.
    static let manhattanNorth: Double = 29

    /// The next, as the button's tapped.
    var next: MapTurn {
        switch self {
        case .heading: .north
        case .north: .manhattan
        case .manhattan: .heading
        }
    }

    var label: String {
        switch self {
        case .heading: "The way you're going"
        case .north: "North up"
        case .manhattan: "NY North, the avenues up"
        }
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
        manager.headingFilter = 1
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
