#if DEBUG
import CoreLocation
import Foundation
import ObjectiveC
import Synchronization
import UIKit

/// The UI tests' launch (LeewayUITests), with `-UITest` among the launch arguments: past
/// first-run setup, at 4 Av-9 St in Brooklyn (Pretend Location), with Work at Times Sq for New
/// Trip, and no request reaching a real server. The MTA's feeds are answered from the saved ones
/// in the folder named by the environment's `LEEWAY_FIXTURES` (Tests/LeewayTests/Fixtures);
/// everything else fails as with no signal. MapKit's tiles and search aren't stopped.
///
/// The clock's set back to when the feeds were read (`AppClock`), with their trains kept live
/// for it (`AppClock.feedsAreAtPretendTime`), so Nearby shows them as it did then.
///
/// With `-UITestRecordRequests <path>`, each request (method, address, header names, body size),
/// each call made of a location manager, each move between foreground and background and the
/// CPU time used every 5 s are added to the file as lines of JSON, for the tests to count; with
/// `-UITestFrames` too, the frames shown late each second (`UITestFrames`).
///
/// Nothing's saved: the defaults it sets are this launch's alone (the argument domain), so the
/// simulator's own Leeway keeps its setup and places.
@MainActor
enum UITestLaunch {
    static let isOn = !TestHost.isUnitTesting && ProcessInfo.processInfo.arguments.contains("-UITest")

    /// 4 Av-9 St (F G R), Brooklyn.
    static let here = CLLocationCoordinate2D(latitude: 40.6705, longitude: -73.9888)
    /// New Trip's Work: Times Sq-42 St, an R ride from 4 Av-9 St.
    static let work = TripPlace(name: "Times Sq", detail: "Times Sq-42 St",
                                point: TripPlace.Point(latitude: 40.7559, longitude: -73.9871))

    /// The record's file, if asked for one.
    private static var record: UITestRecord?

    /// Sets it all up, before anything's drawn or fetched. Does nothing without `-UITest`.
    static func start() {
        guard isOn else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-UITestRecordRequests"), index + 1 < arguments.count {
            record = UITestRecord(path: arguments[index + 1])
        }
        let record = record
        record?.write(["kind": "launch"])
        setDefaults()
        PretendLocation.shared.set(here, name: "4 Av-9 St")

        let folder = ProcessInfo.processInfo.environment["LEEWAY_FIXTURES"].map { URL(fileURLWithPath: $0) }
        let names = Set(FixtureFeeds.feeds.values).union(["weekday1030-alerts.json", "weekday1030-outages.json"])
        let files: [String: Data] = names.reduce(into: [:]) { files, name in
            files[name] = folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) }
        }
        record?.write(["kind": "fixtures", "found": files.count, "wanted": names.count])
        let trainFeeds = FixtureFeeds.feeds.values.compactMap { files[$0] }
        if let read = SubwayFeed.newest(trainFeeds) {
            AppClock.offset = read.timeIntervalSinceNow
            AppClock.feedsAreAtPretendTime = true
        }
        TestNetwork.start({ request in
            guard let url = request.url, let name = FixtureFeeds.fixture(for: url), let body = files[name] else {
                return nil
            }
            return .ok(body)
        }, seen: { made, cancelled in
            record?.write([
                "kind": cancelled ? "cancelled" : "request", "method": made.method, "url": made.url.absoluteString,
                "host": made.url.host ?? "", "path": made.url.path,
                "headers": made.headers.keys.sorted(), "bodyBytes": made.body?.count ?? 0,
                "answered": FixtureFeeds.fixture(for: made.url).flatMap { files[$0] } != nil,
            ])
        })
        guard let record else { return }
        UITestLocationLog.install(record)
        // The CPU time used so far, every 5 s while running (suspended, none): for the tests'
        // idle checks
        cpuSampler.setEventHandler { record.write(["kind": "cpu", "seconds": Self.cpuSeconds()]) }
        cpuSampler.schedule(deadline: .now(), repeating: 5, leeway: .seconds(1))
        cpuSampler.resume()
        // Frames shown late, for the smoothness tests: only when asked, as it wakes the main
        // thread every frame, which the idle tests would count
        if arguments.contains("-UITestFrames") { UITestFrames.shared.start(record) }
        let center = NotificationCenter.default
        for (name, phase) in [(UIApplication.didEnterBackgroundNotification, "background"),
                              (UIApplication.willEnterForegroundNotification, "foreground"),
                              (UIApplication.didBecomeActiveNotification, "active"),
                              (UIApplication.willResignActiveNotification, "inactive")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                record.write(["kind": "phase", "phase": phase])
            }
        }
    }

    private static let cpuSampler = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    /// The process's CPU time, user and system, in seconds.
    nonisolated static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (time: timeval) in Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// First-run setup done and Work set, in the argument domain: read over what's saved, and
    /// gone when the app quits.
    private static func setDefaults() {
        /// As SavedPlaces' own key, encoded the same.
        enum Kind: String, Codable { case work }
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[AppTabs.firstRunDoneKey] = true
        domain["savedPlaces"] = try? JSONEncoder().encode([Kind.work: work])
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}

/// Hitches as the main thread sees them (`-UITestFrames`): each frame that started later than
/// the one before was due to end, by how late, added to the record once a second. In the
/// simulator, where XCTHitchMetric and the scrolling metric's hitch ratio aren't measured.
/// Only the app's own thread: not the render server's own hitches.
@MainActor
final class UITestFrames: NSObject {
    static let shared = UITestFrames()

    private var record: UITestRecord?
    private var link: CADisplayLink?
    /// When the last frame was due to end.
    private var due: CFTimeInterval = 0
    private var frames = 0
    private var late: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var since: CFTimeInterval = 0

    func start(_ record: UITestRecord) {
        self.record = record
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let frame = link.targetTimestamp - link.timestamp
        // Half a frame's grace, for the timestamps' own jitter
        if due > 0, now - due > frame / 2 {
            late += now - due
            worst = max(worst, now - due)
        }
        due = link.targetTimestamp
        frames += 1
        if since == 0 { since = now }
        guard now - since >= 1 else { return }
        record?.write(["kind": "frames", "frames": frames, "lateMs": late * 1000, "worstMs": worst * 1000,
                       "spanMs": (now - since) * 1000, "frameMs": frame * 1000])
        frames = 0
        late = 0
        worst = 0
        since = now
    }
}

/// The UI tests' record: one line of JSON for each thing seen, with the real time it was.
final class UITestRecord: Sendable {
    private let file: Mutex<FileHandle>

    init?(path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        file = Mutex(handle)
    }

    func write(_ entry: [String: Any]) {
        var entry = entry
        entry["at"] = Date.now.timeIntervalSince1970
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        file.withLock { $0.write(line) }
    }
}

/// Each call the app makes of a location manager, added to the record: which, what accuracy it
/// asked for, whether in the background, and the app's state then. Swapped in for this launch.
enum UITestLocationLog {
    nonisolated(unsafe) fileprivate static var record: UITestRecord?

    static func install(_ record: UITestRecord) {
        self.record = record
        let swaps: [(Selector, Selector)] = [
            (#selector(CLLocationManager.startUpdatingLocation), #selector(CLLocationManager.uiTestStartUpdatingLocation)),
            (#selector(CLLocationManager.stopUpdatingLocation), #selector(CLLocationManager.uiTestStopUpdatingLocation)),
            (#selector(CLLocationManager.requestLocation), #selector(CLLocationManager.uiTestRequestLocation)),
            (#selector(CLLocationManager.startUpdatingHeading), #selector(CLLocationManager.uiTestStartUpdatingHeading)),
            (#selector(CLLocationManager.stopUpdatingHeading), #selector(CLLocationManager.uiTestStopUpdatingHeading)),
            (#selector(CLLocationManager.requestWhenInUseAuthorization),
             #selector(CLLocationManager.uiTestRequestWhenInUseAuthorization)),
            (#selector(CLLocationManager.requestAlwaysAuthorization), #selector(CLLocationManager.uiTestRequestAlwaysAuthorization)),
            (#selector(CLLocationManager.startMonitoringSignificantLocationChanges),
             #selector(CLLocationManager.uiTestStartMonitoringSignificantLocationChanges)),
            (#selector(setter: CLLocationManager.desiredAccuracy), #selector(CLLocationManager.uiTestSetDesiredAccuracy(_:))),
            (#selector(setter: CLLocationManager.allowsBackgroundLocationUpdates),
             #selector(CLLocationManager.uiTestSetAllowsBackgroundLocationUpdates(_:))),
        ]
        for (original, logged) in swaps {
            guard let a = class_getInstanceMethod(CLLocationManager.self, original),
                  let b = class_getInstanceMethod(CLLocationManager.self, logged) else { continue }
            method_exchangeImplementations(a, b)
        }
    }

    fileprivate static func note(_ call: String, _ manager: CLLocationManager, _ extra: [String: Any] = [:]) {
        guard let record else { return }
        let state: String
        if Thread.isMainThread {
            state = MainActor.assumeIsolated {
                switch UIApplication.shared.applicationState {
                case .active: "active"
                case .inactive: "inactive"
                case .background: "background"
                @unknown default: "unknown"
                }
            }
        } else {
            state = "offMain"
        }
        // Who called: the first frame past this one and the swap ("MapKit", "Leeway"), and the
        // first of the app's own, if any
        let frames = Thread.callStackSymbols.dropFirst(2).map { $0.split(separator: " ", omittingEmptySubsequences: true) }
            .filter { $0.count > 3 && !$0[3].contains("uiTest") }
        let module = frames.first { $0[1] != "CoreLocation" }.map { String($0[1]) } ?? ""
        let caller = frames.first { $0[1] == "Leeway" }.map { String($0.dropFirst(3).joined(separator: " ").prefix(200)) } ?? ""
        var entry: [String: Any] = [
            "kind": "location", "call": call, "manager": String(UInt(bitPattern: ObjectIdentifier(manager).hashValue), radix: 16),
            "accuracy": manager.desiredAccuracy, "background": manager.allowsBackgroundLocationUpdates,
            "appState": state, "module": module, "caller": caller,
        ]
        entry.merge(extra) { $1 }
        record.write(entry)
    }
}

/// The logged versions: once swapped, each name here runs the original.
extension CLLocationManager {
    @objc fileprivate func uiTestStartUpdatingLocation() {
        UITestLocationLog.note("startUpdatingLocation", self)
        uiTestStartUpdatingLocation()
    }

    @objc fileprivate func uiTestStopUpdatingLocation() {
        UITestLocationLog.note("stopUpdatingLocation", self)
        uiTestStopUpdatingLocation()
    }

    @objc fileprivate func uiTestRequestLocation() {
        UITestLocationLog.note("requestLocation", self)
        uiTestRequestLocation()
    }

    @objc fileprivate func uiTestStartUpdatingHeading() {
        UITestLocationLog.note("startUpdatingHeading", self)
        uiTestStartUpdatingHeading()
    }

    @objc fileprivate func uiTestStopUpdatingHeading() {
        UITestLocationLog.note("stopUpdatingHeading", self)
        uiTestStopUpdatingHeading()
    }

    @objc fileprivate func uiTestRequestWhenInUseAuthorization() {
        UITestLocationLog.note("requestWhenInUseAuthorization", self)
        uiTestRequestWhenInUseAuthorization()
    }

    @objc fileprivate func uiTestRequestAlwaysAuthorization() {
        UITestLocationLog.note("requestAlwaysAuthorization", self)
        uiTestRequestAlwaysAuthorization()
    }

    @objc fileprivate func uiTestStartMonitoringSignificantLocationChanges() {
        UITestLocationLog.note("startMonitoringSignificantLocationChanges", self)
        uiTestStartMonitoringSignificantLocationChanges()
    }

    @objc fileprivate func uiTestSetDesiredAccuracy(_ accuracy: CLLocationAccuracy) {
        UITestLocationLog.note("setDesiredAccuracy", self, ["to": accuracy])
        uiTestSetDesiredAccuracy(accuracy)
    }

    @objc fileprivate func uiTestSetAllowsBackgroundLocationUpdates(_ allows: Bool) {
        UITestLocationLog.note("setAllowsBackgroundLocationUpdates", self, ["to": allows])
        uiTestSetAllowsBackgroundLocationUpdates(allows)
    }
}
#endif
