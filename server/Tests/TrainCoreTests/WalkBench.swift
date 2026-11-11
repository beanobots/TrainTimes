#if canImport(MapKit) && canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation
import MapKit
import Testing
@testable import TrainCore

/// The walking router's benchmark: every walk in tools/walkbench/walks.json routed Fastest,
/// Balanced and Safest, against Apple Maps' walk, drawn on the city's sidewalks and reported,
/// to look over and tune `WalkCosts` by. Apple's walks are kept in tools/walkbench/apple so a
/// run is the same each time. Off unless asked for:
///
///     WALKBENCH=1 swift test --filter WalkBench
///
/// Pictures and report.md go to ~/Desktop/Leeway walk bench (or WALKBENCH_OUT). Walked at
/// noon, or at WALKBENCH_HOUR (0–23) for the night costs; the walks in walks.json, or
/// WALKBENCH_WALKS (night_walks.json: parks, waterfronts and industrial blocks).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WALKBENCH"] != nil))
struct WalkBench {
    struct Bench: Decodable {
        let name: String
        let note: String
        var from: [Double] = []
        var to: [Double] = []
    }

    /// Apple Maps' walk, as kept.
    struct AppleWalk: Codable {
        let points: [[Double]]
        let metres: Double
        let seconds: Double
    }

    static let tools = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("tools/walkbench")
    static let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WALKBENCH_OUT"]
        ?? NSHomeDirectory() + "/Desktop/Leeway walk bench")

    static let hour = ProcessInfo.processInfo.environment["WALKBENCH_HOUR"].flatMap(Int.init) ?? 12

    @Test func bench() async throws {
        let router = try #require(WalkRouterTests.router, "ios/App/walkgraph.sqlite")
        let walks = try JSONDecoder().decode([Bench].self, from: Data(contentsOf: Self.tools.appendingPathComponent(
            ProcessInfo.processInfo.environment["WALKBENCH_WALKS"] ?? "walks.json")))
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        var report = "# Walk bench\n\n| Walk | Route | m | min | crossings | no light | wide, no light | ramps | ms |\n"
            + "|---|---|---|---|---|---|---|---|---|\n"
        for walk in walks {
            let start = Walk.Point(lat: walk.from[0], lon: walk.from[1]), end = Walk.Point(lat: walk.to[0], lon: walk.to[1])
            let apple = try await Self.apple(walk.name, from: start, to: end)
            var routes: [(WalkPreference, WalkRouter.Route)] = []
            var timings: [WalkPreference: Int] = [:]
            for preference in WalkPreference.allCases {
                let began = Date()
                var options = WalkRouter.Options(preference: preference)
                options.time = .init(hour: Self.hour)
                if let route = router.route(from: start, to: end, options: options) {
                    routes.append((preference, route))
                }
                timings[preference] = Int(Date().timeIntervalSince(began) * 1000)
            }
            if let apple {
                report += "| \(walk.name) | Apple | \(Int(apple.metres)) | \(Int(apple.seconds / 60)) | | | | | |\n"
            }
            for (preference, route) in routes {
                let s = route.stats
                report += "| \(walk.name) | \(preference) | \(Int(s.metres)) | \(Int((s.seconds / 60).rounded())) | \(s.crossings) | "
                    + "\(s.unsignalled) | \(s.unsignalledWide) | \(s.ramps) | \(timings[preference] ?? 0) |\n"
            }
            if routes.isEmpty { report += "| \(walk.name) | no route | | | | | | | |\n" }
            try Self.draw(walk, apple: apple, routes: routes, router: router, start: start, end: end)
        }
        try report.write(to: Self.output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print(report)
    }

    /// Apple Maps' walk for `name`, from tools/walkbench/apple, or asked for and kept there.
    static func apple(_ name: String, from start: Walk.Point, to end: Walk.Point) async throws -> AppleWalk? {
        let folder = tools.appendingPathComponent("apple")
        let file = folder.appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: file) { return try JSONDecoder().decode(AppleWalk.self, from: data) }
        // The server package builds for older macOS; asking Apple Maps here needs this one
        guard #available(macOS 26.0, *) else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: start.lat, longitude: start.lon), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: end.lat, longitude: end.lon), address: nil)
        request.transportType = .walking
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
        route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: route.polyline.pointCount))
        let walk = AppleWalk(points: coordinates.map { [$0.latitude, $0.longitude] }, metres: route.distance,
                             seconds: route.expectedTravelTime)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(walk).write(to: file)
        // Apple Maps limits how fast it's asked
        try await Task.sleep(for: .seconds(1.5))
        return walk
    }

    // MARK: Drawing

    static func draw(_ walk: Bench, apple: AppleWalk?, routes: [(WalkPreference, WalkRouter.Route)],
                     router: WalkRouter, start: Walk.Point, end: Walk.Point) throws {
        let lines = routes.map { ($0.0, router.points(of: $0.1)) }
        let applePoints = apple?.points.map { Walk.Point(lat: $0[0], lon: $0[1]) } ?? []
        let all = [start, end] + applePoints + lines.flatMap(\.1)
        let margin = 60.0
        let south = all.map(\.lat).min()! - margin / 111_320, north = all.map(\.lat).max()! + margin / 111_320
        let eastPerDegree = 111_320 * cos(start.lat * .pi / 180)
        let west = all.map(\.lon).min()! - margin / eastPerDegree, east = all.map(\.lon).max()! + margin / eastPerDegree
        let widthMetres = (east - west) * eastPerDegree, heightMetres = (north - south) * 111_320
        let scale = min(2.0, 2400 / max(widthMetres, heightMetres))
        let width = Int(widthMetres * scale), height = Int(heightMetres * scale) + 150
        func p(_ point: Walk.Point) -> CGPoint {
            CGPoint(x: (point.lon - west) * eastPerDegree * scale, y: (point.lat - south) * 111_320 * scale)
        }
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Sidewalks
        let sidewalks = try Self.sidewalks(south: south, west: west, north: north, east: east)
        let shape = CGMutablePath()
        for rings in sidewalks {
            for ring in rings where ring.count > 2 {
                shape.addLines(between: ring.map(p))
                shape.closeSubpath()
            }
        }
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0.84, alpha: 1))
        context.fillPath(using: .evenOdd)
        // The graph's streets faintly
        let graph = router.graph
        for block in 0..<graph.blockCount {
            let s = Int(graph.geomStart[block])
            let lat = Double(graph.geomLat[s]) / 1e6, lon = Double(graph.geomLon[s]) / 1e6
            guard lat > south - 0.003, lat < north + 0.003, lon > west - 0.004, lon < east + 0.004 else { continue }
            let line = graph.line(of: block)
            context.setStrokeColor(graph.class(of: block) == .arm ? CGColor(red: 0.9, green: 0.5, blue: 0.5, alpha: 0.6)
                                   : CGColor(gray: 0.6, alpha: 0.6))
            context.setLineWidth(1)
            context.addLines(between: line.map(p))
            context.strokePath()
        }
        func stroke(_ points: [Walk.Point], _ color: CGColor, _ lineWidth: CGFloat, dash: [CGFloat] = []) {
            guard points.count > 1 else { return }
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.setLineDash(phase: 0, lengths: dash)
            context.addLines(between: points.map(p))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }
        stroke(applePoints, CGColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 0.55), 7)
        let colors: [WalkPreference: CGColor] = [
            .fastest: CGColor(gray: 0.25, alpha: 0.9),
            .balanced: CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 0.9),
            .safest: CGColor(red: 0.05, green: 0.65, blue: 0.25, alpha: 0.9),
        ]
        for (preference, points) in lines.reversed() {
            stroke(points, colors[preference]!, preference == .balanced ? 3.5 : 2.5,
                   dash: preference == .fastest ? [6, 5] : [])
        }
        // The balanced route's crossings by their light
        if let balanced = routes.first(where: { $0.0 == .balanced })?.1 {
            for leg in balanced.legs {
                guard case let .cross(node, arm, from, to) = leg else { continue }
                let block = Int(graph.armBlock[arm])
                guard graph.class(of: block) != .path else { continue }
                let signal = Sidewalks.Signal.Kind(rawValue: Int(graph.nodeSignal[node]))
                if graph.class(of: block) == .arm && graph.nodeLevel[node] != 13 { continue }
                let color = graph.class(of: block) == .arm && ![8, 13].contains(graph.blockRW[block])
                    ? CGColor(gray: 0, alpha: 1)
                    : signal.contains(.signal) ? CGColor(red: 0.1, green: 0.75, blue: 0.2, alpha: 1)
                    : CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1)
                let middle = p(Walk.Point(lat: (from.lat + to.lat) / 2, lon: (from.lon + to.lon) / 2))
                context.setFillColor(color)
                context.fillEllipse(in: CGRect(x: middle.x - 5, y: middle.y - 5, width: 10, height: 10))
            }
        }
        for (point, color) in [(start, CGColor(red: 0, green: 0.7, blue: 0, alpha: 1)), (end, CGColor(red: 0.7, green: 0, blue: 0.7, alpha: 1))] {
            let at = p(point)
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: at.x - 8, y: at.y - 8, width: 16, height: 16))
        }
        // The legend, at the top
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphics
        var lines2 = ["\(walk.name)  \(walk.note)"]
        if let apple { lines2.append("Apple (red): \(Int(apple.metres)) m, \(Int(apple.seconds / 60)) min") }
        for (preference, route) in routes {
            let s = route.stats
            lines2.append("\(preference.rawValue.capitalized): \(Int(s.metres)) m, \(Int((s.seconds / 60).rounded())) min, "
                          + "\(s.crossings) crossings, \(s.unsignalled) with no light (\(s.unsignalledWide) wide), \(s.ramps) ramps")
        }
        let text = lines2.joined(separator: "\n")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                         .foregroundColor: NSColor.black]
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: height - 140, width: width, height: 140).fill()
        NSAttributedString(string: text, attributes: attributes).draw(in: NSRect(x: 12, y: height - 136, width: width - 24, height: 130))
        NSGraphicsContext.current = nil
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(walk.name).png"))
    }

    /// The city's sidewalks in a box, from the app's copy.
    static func sidewalks(south: Double, west: Double, north: Double, east: Double) throws -> [Sidewalks.Rings] {
        let file = tools.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/App/sidewalks.sqlite")
        let database = try SQLite(path: file.path)
        let rows = try database.query("""
            SELECT s.rings FROM sidewalk_boxes b JOIN sidewalks s ON s.id = b.id
            WHERE b.min_lat <= ? AND b.max_lat >= ? AND b.min_lon <= ? AND b.max_lon >= ?
            """, [.real(north), .real(south), .real(east), .real(west)])
        return rows.compactMap { $0.first?.blob.flatMap(Sidewalks.rings(from:)) }
    }
}
#endif
