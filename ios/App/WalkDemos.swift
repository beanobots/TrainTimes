#if DEBUG
import CoreLocation
import Foundation

// Throwaway: real walks started as from Go, for looking at the walking screen in the simulator.
// `-walkdemo N` starts walk N; the console says where along it to put the simulator's location.
// Delete this and its hook in LeewayApp once reviewed.

enum WalkDemos {
    struct Demo {
        let title: String
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
        let endName: String
    }

    static let all: [Demo] = [
        Demo(title: "Park Slope, down 4th Ave", from: .init(latitude: 40.67385, longitude: -73.98640),
             to: .init(latitude: 40.67080, longitude: -73.98880), endName: "4 Av–9 St"),
        Demo(title: "Midtown grid", from: .init(latitude: 40.75800, longitude: -73.98550),
             to: .init(latitude: 40.75270, longitude: -73.97720), endName: "Grand Central"),
        Demo(title: "West Village tangle", from: .init(latitude: 40.73220, longitude: -74.00050),
             to: .init(latitude: 40.73590, longitude: -74.00500), endName: "Magnolia Bakery"),
        Demo(title: "Financial District", from: .init(latitude: 40.70460, longitude: -74.01410),
             to: .init(latitude: 40.71010, longitude: -74.00760), endName: "Fulton St"),
        Demo(title: "Jackson Heights, Queens", from: .init(latitude: 40.74660, longitude: -73.89140),
             to: .init(latitude: 40.75010, longitude: -73.88350), endName: "82 St & 35 Av"),
        Demo(title: "Harlem, 125th St", from: .init(latitude: 40.80790, longitude: -73.94540),
             to: .init(latitude: 40.81000, longitude: -73.95000), endName: "Apollo Theater"),
        Demo(title: "Into Central Park", from: .init(latitude: 40.76810, longitude: -73.98190),
             to: .init(latitude: 40.77400, longitude: -73.97120), endName: "Bethesda Terrace"),
    ]

    static var launchIndex: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-walkdemo"), index + 1 < args.count else { return nil }
        return Int(args[index + 1])
    }

    /// Plans demo `index` as Go would and starts it, printing a point a third of the way along.
    @MainActor
    static func start(_ index: Int) async {
        guard all.indices.contains(index) else { return }
        let demo = all[index]
        do {
            let walk = try await WalkingDirections.walk(from: demo.from, to: demo.to)
            let session = WalkSession(walk: walk, endName: demo.endName,
                                      end: CLLocation(latitude: demo.to.latitude, longitude: demo.to.longitude))
            ActiveWalk.shared.begin(session)
            let point = walk.path(last: walk.meters * 0.67).first ?? walk.points[0]
            print("DEMO \(index) \(demo.title): \(Int(walk.meters)) m, \(walk.steps.count) steps, "
                  + "\(walk.crossings?.count ?? 0) crossings, fitted \(walk.crossings != nil)")
            print("DEMO AT \(point.lat),\(point.lon)")
        } catch {
            print("DEMO \(index) failed: \(error)")
        }
    }
}
#endif
