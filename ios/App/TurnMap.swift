import MapKit
import UIKit

/// The Lock Screen's map of the next turn while walking: a light or dark, heading-up Apple Maps picture
/// with the way left to walk drawn on, you at the foot and the turn up and right of the middle,
/// clear of the turn's words over its left. Saved in the App Group for the countdown to show,
/// as a Live Activity can't draw a map itself, and its state can't carry a picture.
enum TurnMap {
    /// What to draw.
    struct Scene: Equatable {
        /// What's left of the walk, from where you are.
        var path: [Walk.Point]
        /// Where the next instruction's done.
        var turn: Walk.Point
        /// Degrees clockwise from north up the picture: the way into the turn.
        var heading: Double
        /// The walk's end: stairs down at an entrance, else a pin.
        var end: Walk.Point
        var endsAtStairs: Bool
    }

    /// The Lock Screen countdown's points, at its widest: the map's the whole of it, the
    /// Lock Screen's tallest. Drawn filling it, so a little's cut off either side on a narrower
    /// phone.
    static let size = CGSize(width: 360, height: WalkState.mapHeight)
    /// Metres a point covers at the closest: 60 m to 78 pt, as the strip was before it filled the
    /// countdown. Zoomed out from that until you and the way to the turn fit (`metresPerPoint`),
    /// as far as `farthest`.
    private static let nearest = 60.0 / 78
    /// Metres a point covers at the farthest: 320 m top to bottom. Farther from the turn than
    /// that shows, you're below the picture, the way into the turn coming up from its foot.
    private static let farthest = 2.0
    /// Where the turn is in the picture, as fractions of its size.
    private static let turnAt = CGPoint(x: 0.8, y: 0.42)
    /// Where you're kept in the picture: right of the words over its left, in from the edges
    /// (a little's cut off either side on a narrower phone).
    private static let youIn = CGRect(x: 0.74, y: 0.07, width: 0.21, height: 0.86)
    /// Where the rest of the way to the turn's kept: it may pass under the words.
    private static let wayIn = CGRect(x: 0.55, y: 0.07, width: 0.42, height: 0.86)
    /// Metres from the turn within which you're in the picture, about: nearer, it's drawn again
    /// as you walk on, so you move along it and it zooms in.
    static let showsYouWithin = farthest * size.height * (youIn.maxY - turnAt.y)
    /// Camera metres per metre a point covers, at `size`: in proportion to the picture's height,
    /// as the camera sees the same span top to bottom whatever the height (measured at 160 pt:
    /// 400 m up, 100 m is 74.5 pt; at 78 pt it was 36.3).
    private static let cameraPerMetrePerPoint = 1.8635 * size.height
    static let prefix = "turn-map-"

    /// Draws `scene`, light and dark, and saves them, returning their App Group name
    /// (`WalkState.mapFile(dark:)`): a new one each time, so the countdown redraws. The others
    /// are deleted, but `previous`'s, which it may be drawing still. Nil if Apple Maps couldn't
    /// draw either.
    static func draw(_ scene: Scene, keeping previous: String?) async -> String? {
        let name = "\(prefix)\(UUID().uuidString.prefix(8))"
        // Both: the Lock Screen follows Light and Dark Mode, and is dark whenever the
        // Always-On display dims it
        async let light = save(scene, dark: false, as: name)
        async let dark = save(scene, dark: true, as: name)
        let drawn = await (light, dark)
        guard drawn.0 && drawn.1 else { return nil }
        let keeping = [name, previous].compactMap { $0 }.flatMap { [
            WalkState.mapFile(named: $0, dark: false), WalkState.mapFile(named: $0, dark: true),
        ] }
        clear(keeping: Set(keeping))
        return name
    }

    /// Draws `scene` in light or dark and saves it as `name`'s picture for that.
    private static func save(_ scene: Scene, dark: Bool, as name: String) async -> Bool {
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = 3
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        let metresPerPoint = metresPerPoint(for: scene)
        options.camera = MKMapCamera(lookingAtCenter: centre(of: scene, metresPerPoint: metresPerPoint),
                                     fromDistance: metresPerPoint * cameraPerMetrePerPoint,
                                     pitch: 0, heading: scene.heading)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start(),
              let data = picture(of: scene, on: snapshot).jpegData(compressionQuality: 0.85),
              let url = SharedStore.url(named: WalkState.mapFile(named: name, dark: dark)) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Deletes the saved pictures, but those `keeping`.
    static func clear(keeping: Set<String> = []) {
        guard let folder = SharedStore.url(named: ""),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) && !keeping.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Metres per point to draw `scene` at: as close as `nearest`, out as far as `farthest` to
    /// fit you in `youIn` and the way from you to the turn in `wayIn`, with the turn at `turnAt`
    /// and `heading` up.
    static func metresPerPoint(for scene: Scene) -> Double {
        let upTo = scene.path.firstIndex(of: scene.turn) ?? 0
        let angle = scene.heading * .pi / 180
        let cosLat = cos(scene.turn.lat * .pi / 180)
        var needed = nearest
        for (index, point) in scene.path.prefix(upTo + 1).enumerated() {
            // Metres right and up the picture from the turn
            let east = (point.lon - scene.turn.lon) * Earth.metresPerDegree * cosLat
            let north = (point.lat - scene.turn.lat) * Earth.metresPerDegree
            let right = east * cos(angle) - north * sin(angle)
            let up = east * sin(angle) + north * cos(angle)
            let box = index == 0 ? youIn : wayIn
            // Points from the turn to the box's edge, each way
            let room = (right: (right >= 0 ? box.maxX - turnAt.x : turnAt.x - box.minX) * size.width,
                        up: (up >= 0 ? turnAt.y - box.minY : box.maxY - turnAt.y) * size.height)
            needed = max(needed, abs(right) / room.right, abs(up) / room.up)
        }
        return min(needed, farthest)
    }

    /// The camera's centre, so the turn's at `turnAt` with `heading` up.
    private static func centre(of scene: Scene, metresPerPoint: Double) -> CLLocationCoordinate2D {
        // From the turn to the middle, in metres right and up the picture
        let right = (0.5 - turnAt.x) * size.width * metresPerPoint
        let up = -(0.5 - turnAt.y) * size.height * metresPerPoint
        let angle = scene.heading * .pi / 180
        let east = right * cos(angle) + up * sin(angle)
        let north = -right * sin(angle) + up * cos(angle)
        let lat = scene.turn.lat + north / Earth.metresPerDegree
        let lon = scene.turn.lon + east / (Earth.metresPerDegree * cos(scene.turn.lat * .pi / 180))
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The map with the walk on it, as on the walking screen: the route in blue with a darker
    /// edge, the stairs or pin at its end, you as a blue dot in a white ring.
    private static func picture(of scene: Scene, on snapshot: MKMapSnapshotter.Snapshot) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            snapshot.image.draw(at: .zero)
            let context = renderer.cgContext
            let points = scene.path.map { snapshot.point(for: $0.coordinate) }
            if points.count > 1 {
                let route = UIBezierPath()
                route.move(to: points[0])
                for point in points.dropFirst() { route.addLine(to: point) }
                route.lineCapStyle = .round
                route.lineJoinStyle = .round
                route.lineWidth = 7
                UIColor(red: 0, green: 0.28, blue: 0.62, alpha: 1).setStroke()
                route.stroke()
                route.lineWidth = 5
                UIColor(red: 0, green: 0.48, blue: 1, alpha: 1).setStroke()
                route.stroke()
            }
            let end = snapshot.point(for: scene.end.coordinate)
            if scene.endsAtStairs {
                circle(at: end, radius: 7, in: context, colour: .white)
                circle(at: end, radius: 5.6, in: context, colour: UIColor(red: 0, green: 0.55, blue: 0.3, alpha: 1))
                let symbol = UIImage(systemName: "stairs", withConfiguration: UIImage.SymbolConfiguration(pointSize: 6.5, weight: .bold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                if let symbol {
                    symbol.draw(at: CGPoint(x: end.x - symbol.size.width / 2, y: end.y - symbol.size.height / 2))
                }
            } else {
                let pin = UIImage(systemName: "mappin.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)
                    .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed])))
                if let pin {
                    pin.draw(at: CGPoint(x: end.x - pin.size.width / 2, y: end.y - pin.size.height / 2))
                }
            }
            if let you = points.first {
                circle(at: you, radius: 6, in: context, colour: .white)
                circle(at: you, radius: 4.3, in: context, colour: UIColor(red: 0, green: 0.48, blue: 1, alpha: 1))
            }
        }
    }

    private static func circle(at centre: CGPoint, radius: CGFloat, in context: CGContext, colour: UIColor) {
        context.setFillColor(colour.cgColor)
        context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    }

    /// The way into the turn: from about `approach` metres back along the path to it, or from
    /// where you are when it's nearer. Nil when you're on it, too close to say.
    static func heading(into turn: Walk.Point, along path: [Walk.Point]) -> Double? {
        guard let at = path.firstIndex(of: turn) else { return nil }
        var index = at
        while index > 0, path[index].metres(to: turn) < approach { index -= 1 }
        guard path[index].metres(to: turn) >= closest else { return nil }
        return path[index].heading(to: turn)
    }

    /// Metres back from the turn the way into it is taken from.
    private static let approach = 30.0
    /// Metres from the turn under which the way into it is kept, not taken again.
    private static let closest = 6.0
}
