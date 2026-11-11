import MapKit
import SwiftUI
import Testing
import UIKit
@testable import Leeway

/// Nearby's card laid out as before: `FirstThatFits` as the `ViewThatFits` it replaced, drawn
/// pixel for pixel the same (ImageRenderer), at a range of widths and text sizes. `PairedRows`
/// against the `Grid` it replaced is checked on the screen (ScreenTests): ImageRenderer draws
/// the Grid's tiles, which fill their rows, cut off at their tops, as the app doesn't.
@MainActor
struct NearbyLayoutTests {
    /// `view`'s pixels, laid out `width` wide.
    private static func pixels(_ view: some View, width: CGFloat, size: DynamicTypeSize = .large) -> (Data, CGSize)? {
        let renderer = ImageRenderer(content: view.environment(\.dynamicTypeSize, size).frame(width: width))
        renderer.scale = 2
        guard let image = renderer.cgImage, let data = image.dataProvider?.data as Data? else { return nil }
        return (data, CGSize(width: image.width, height: image.height))
    }

    /// A bus row as the tile has it, with the name in `fitted`.
    private static func row(_ fitted: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            fitted.font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("12 min").font(.subheadline.weight(.bold)).monospacedDigit().fixedSize()
        }
    }

    /// Where each cell went, and the whole's size, as laid out on screen.
    private final class Frames {
        var cells: [Int: CGRect] = [:]
        var whole: CGSize = .zero
    }

    /// A tile as Nearby's has it: a bullet, a place and its walk, its ways each a name and a time
    /// that's never cut; filling its row, as the tiles do.
    private struct Cell: View {
        let index: Int
        let place: String
        let ways: [String]
        /// A time never cut, this wide, to make its column wider than the other at least.
        var fixed = ""
        let frames: Frames

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(place).font(.caption.weight(.semibold)).lineLimit(1)
                        Text("1 min walk").font(.caption2).lineLimit(1)
                    }
                }
                if !fixed.isEmpty { Text(fixed).font(.subheadline.weight(.bold)).fixedSize() }
                ForEach(ways, id: \.self) { way in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        FittedBusName(name: way).font(.caption)
                        Spacer(minLength: 4)
                        Text("12 min").font(.subheadline.weight(.bold)).monospacedDigit().fixedSize()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("rows")) } action: { frames.cells[index] = $0 }
        }
    }

    private static let places: [(String, [String])] = [
        ("4 Av-9 St", ["Manhattan", "Brooklyn"]), ("4 Av-9 St", ["Queens", "Brooklyn"]),
        ("Prospect Av", ["Manhattan", "Coney Island"]), ("9 St & 4 Av", ["Park Slope 20 St via 5 Av", "Downtown Bklyn Fulton Mall"]),
        ("4 Av & 10 St", ["Wlmsbrg Wythe Av via Flushing Av"]), ("Smith-9 Sts", ["Manhattan", "Church Av", "Bay Ridge"]),
        ("Atlantic Av-Barclays Ctr", ["Red Hook Beard St"]),
    ]

    /// `rows`' cells' frames and size, laid out `width` wide at `size` in a window.
    private static func laidOut(count: Int, width: CGFloat, size: DynamicTypeSize, fixed: [Int: String] = [:],
                                rows: @escaping (Frames, [Cell]) -> AnyView) async -> Frames {
        let frames = Frames()
        let cells = (0..<count).map {
            Cell(index: $0, place: places[$0 % places.count].0, ways: places[$0 % places.count].1, fixed: fixed[$0] ?? "",
                 frames: frames)
        }
        let view = rows(frames, cells)
            .coordinateSpace(.named("rows"))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { frames.whole = $0 }
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.dynamicTypeSize, size)
        let controller = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 1400, height: 4000)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        controller.view.layoutIfNeeded()
        window.isHidden = true
        return frames
    }

    /// The same but for rounding, a thousandth of a point.
    private static func same(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    /// The same size, and within a pixel (a third of a point) of the same place: a tile that
    /// can't be as narrow as its column, the Grid centred on it, by a sixth of a point.
    private static func same(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return a == b }
        return abs(a.minX - b.minX) < 0.34 && abs(a.minY - b.minY) < 0.001 && same(a.size, b.size)
    }

    /// `PairedRows` laying its tiles out as the two-column `Grid` it replaced did: each in the
    /// same place, the same size, the whole the same size, at a range of widths and text sizes,
    /// with an odd one out on its own.
    /// Tiles, and one in each that can't be narrower than so wide (a long time), by its index.
    static let layouts: [(count: Int, fixed: [Int: String])] = [
        (1, [:]), (2, [:]), (5, [:]), (7, [:]), (2, [1: "12 min · 15 min"]), (2, [0: "12 min · 15 min · 20 min"]),
        (5, [3: "12 min · 15 min · 20 min · 25 min"]), (4, [0: "12 min", 3: "12 min · 15 min · 20 min"]), (3, [2: "12 min · 15 min · 20 min"]),
    ]

    @Test(arguments: layouts.indices)
    func pairedRowsAsGrid(layout: Int) async {
        let (count, fixed) = Self.layouts[layout]
        for width in [260.0, 320, 338, 354, 370, 440] {
            for size in [DynamicTypeSize.large, .xxxLarge, .accessibility2, .accessibility5] {
                let grid = await Self.laidOut(count: count, width: width, size: size, fixed: fixed) { _, cells in
                    AnyView(Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(Array(stride(from: 0, to: cells.count, by: 2)), id: \.self) { index in
                            GridRow {
                                cells[index]
                                if index + 1 < cells.count {
                                    cells[index + 1]
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    })
                }
                let rows = await Self.laidOut(count: count, width: width, size: size, fixed: fixed) { _, cells in
                    AnyView(PairedRows(items: cells, spacing: 8) { $0 })
                }
                #expect(grid.cells.count == count)
                #expect(Self.same(rows.whole, grid.whole), "\(count) at \(width), \(size): \(rows.whole) not \(grid.whole)")
                for index in 0..<count {
                    #expect(Self.same(rows.cells[index], grid.cells[index]),
                            "\(count) at \(width), \(size): cell \(index) \(String(describing: rows.cells[index])) not \(String(describing: grid.cells[index]))")
                }
            }
        }
    }

    @Test(arguments: ["Wlmsbrg Wythe Av via Flushing Av", "Downtown Bklyn Fulton Mall", "Red Hook Beard St",
                      "Canarsie - Williamsburg Bridge Plaza", "Bay Ridge", "Park Slope 20 St via 5 Av"])
    func firstThatFitsAsViewThatFits(name: String) throws {
        let names = FittedBusName.shortenings(of: name)
        for width in stride(from: 40.0, through: 260, by: 9) {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let old = ViewThatFits(in: .horizontal) { ForEach(names, id: \.self) { Text($0).lineLimit(1) } }
                let a = try #require(Self.pixels(Self.row(old), width: width, size: size))
                let b = try #require(Self.pixels(Self.row(FittedBusName(name: name)), width: width, size: size))
                #expect(a.1 == b.1, "\(name) at \(width), \(size): size \(a.1) became \(b.1)")
                #expect(a.0 == b.0, "\(name) at \(width), \(size): drawn differently")
            }
        }
    }
}

/// The subway's lines drawn with fewer points the further out the map is (`SubwayDetail`,
/// `NearbyLinesLayer.subwayLines`): each kept within its tolerance of its track and lane,
/// whole close in, and named the same each time for MapKit to keep them.
struct SubwayDetailTests {
    private static let tracks = NearbyLines.allTracks
    private static let latitude = 40.73
    private static var perMeter: Double { MKMapPointsPerMeterAtLatitude(latitude) }

    /// How far `point` is from `line`, in map points.
    private static func distance(_ point: MKMapPoint, to line: [MKMapPoint]) -> Double {
        guard line.count > 1 else { return line.first.map { point.distance(to: $0) } ?? .infinity }
        return zip(line, line.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y
            let squared = dx * dx + dy * dy
            let along = squared == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared))
            return hypot(a.x + along * dx - point.x, a.y + along * dy - point.y)
        }.min() ?? .infinity
    }

    private static func points(_ detail: SubwayDetail) -> Int {
        NearbyLinesLayer.subwayLines(of: tracks, tracksID: 1, detail: detail, latitude: latitude)
            .reduce(0) { $0 + ($1?.coordinates.count ?? 0) }
    }

    @Test func zoomSteps() {
        #expect(SubwayDetail(metersPerPoint: 0.5) == .full)
        #expect(SubwayDetail(metersPerPoint: 3.9) == .full)
        #expect(SubwayDetail(metersPerPoint: 4) == .simplified(step: 0))
        #expect(SubwayDetail(metersPerPoint: 30) == .simplified(step: 2))
        #expect(SubwayDetail(metersPerPoint: 90) == .simplified(step: 4))
        #expect(SubwayDetail(metersPerPoint: 1_000) == .simplified(step: 5))
        #expect(SubwayDetail(metersPerPoint: 0) == .full)
        // Kept within 10% of the zoom it was drawn for, not flickering between two
        #expect(SubwayDetail(metersPerPoint: 8.5, from: .simplified(step: 0)) == .simplified(step: 0))
        #expect(SubwayDetail(metersPerPoint: 7.5, from: .simplified(step: 1)) == .simplified(step: 1))
        #expect(SubwayDetail(metersPerPoint: 3.8, from: .simplified(step: 0)) == .simplified(step: 0))
        #expect(SubwayDetail(metersPerPoint: 9.5, from: .simplified(step: 0)) == .simplified(step: 1))
        #expect(SubwayDetail(metersPerPoint: 4.3, from: .full) == .full)
        #expect(SubwayDetail(metersPerPoint: 0, from: .simplified(step: 3)) == .simplified(step: 3))
        // A quarter of a point at its closest
        #expect(SubwayDetail.full.tolerance == nil)
        #expect(SubwayDetail.simplified(step: 0).tolerance == 1)
        #expect(SubwayDetail.simplified(step: 3).tolerance == 8)
    }

    @Test func simplifiedKeepsEndsAndStaysClose() throws {
        let tolerance = 8 * Self.perMeter
        for track in Self.tracks where track.coordinates.count > 2 {
            let kept = NearbyLinesLayer.simplified(track.coordinates, tolerance: tolerance)
            #expect(kept.first?.latitude == track.coordinates.first?.latitude && kept.first?.longitude == track.coordinates.first?.longitude)
            #expect(kept.last?.latitude == track.coordinates.last?.latitude && kept.last?.longitude == track.coordinates.last?.longitude)
            #expect(kept.count <= track.coordinates.count)
            let line = kept.map(MKMapPoint.init)
            let farthest = track.coordinates.map { Self.distance(MKMapPoint($0), to: line) }.max() ?? 0
            #expect(farthest <= tolerance * 1.0001, "\(track.route) \(farthest / Self.perMeter) m off")
        }
    }

    @Test func simplifiedLeavesShortLinesAndStraightensStraightOnes() {
        let a = CLLocationCoordinate2D(latitude: 40.70, longitude: -73.99)
        let b = CLLocationCoordinate2D(latitude: 40.71, longitude: -73.98)
        let c = CLLocationCoordinate2D(latitude: 40.71, longitude: -73.99)
        #expect(NearbyLinesLayer.simplified([a, b], tolerance: 10).count == 2)
        let straight = TripMap.densified([a, b])
        #expect(straight.count > 10)
        #expect(NearbyLinesLayer.simplified(straight, tolerance: 1).count == 2)
        // A corner kept
        #expect(NearbyLinesLayer.simplified(TripMap.densified([a, b, c]), tolerance: 1).count == 3)
        // Nothing off, nothing left out
        #expect(NearbyLinesLayer.simplified(straight, tolerance: 0).count == straight.count)
    }

    @Test func fewerPointsFurtherOut() {
        let whole = Self.points(.full)
        let counts = (0..<SubwayDetail.steps).map { Self.points(.simplified(step: $0)) }
        print("Subway points whole \(whole), by step \(counts)")
        #expect(whole > 10_000)
        // Each step out fewer: about a seventh just past close in, a twelfth at a borough's zoom,
        // a twentieth at the city's
        for (a, b) in zip(counts, counts.dropFirst()) { #expect(b <= a) }
        #expect(Double(counts[0]) < Double(whole) * 0.2)
        #expect(Double(counts[3]) < Double(whole) * 0.1)
        #expect(Double(counts[5]) < Double(whole) * 0.06)
    }

    @Test func wholeCloseInAsBefore() {
        let apart = NearbyLinesLayer.subwaySpacing * Self.perMeter
        let lines = NearbyLinesLayer.subwayLines(of: Self.tracks, tracksID: 1, detail: SubwayDetail(metersPerPoint: 2),
                                                 latitude: Self.latitude)
        for (index, track) in Self.tracks.enumerated() where track.coordinates.count > 1 {
            let line = lines[index]
            let lanes = track.lanes.count == track.coordinates.count ? track.lanes : Array(repeating: 0, count: track.coordinates.count)
            let before = TripMap.offset(track.coordinates, by: lanes.map { $0 * apart })
            #expect(line?.id == "line-1-\(index)")
            #expect(line?.coordinates.map(\.latitude) == before.map(\.latitude))
            #expect(line?.coordinates.map(\.longitude) == before.map(\.longitude))
        }
    }

    /// Each line, on its lane, within a quarter of a point of where it's drawn whole at the
    /// closest of each step: so two side by side no more than half a point nearer or further apart.
    @Test(arguments: [0, 2, 4])
    func lanesStayWhereTheyWere(step: Int) {
        let detail = SubwayDetail.simplified(step: step)
        let mapPointsPerPoint = 4 * pow(2, Double(step)) * Self.perMeter
        let whole = NearbyLinesLayer.subwayLines(of: Self.tracks, tracksID: 1, detail: .full, latitude: Self.latitude)
        let simple = NearbyLinesLayer.subwayLines(of: Self.tracks, tracksID: 1, detail: detail, latitude: Self.latitude)
        var worst = 0.0
        for (index, track) in Self.tracks.enumerated() where track.isBeside {
            guard let a = whole[index], let b = simple[index] else { continue }
            let line = b.coordinates.map(MKMapPoint.init)
            let off = a.coordinates.map { Self.distance(MKMapPoint($0), to: line) }.max() ?? 0
            worst = max(worst, off / mapPointsPerPoint)
        }
        #expect(worst <= 0.25, "A lane drawn \(worst) pt off")
    }

    @Test func idsTheSameEachTime() {
        let detail = SubwayDetail.simplified(step: 2)
        let a = NearbyLinesLayer.subwayLines(of: Self.tracks, tracksID: 7, detail: detail, latitude: Self.latitude).compactMap { $0?.id }
        let b = NearbyLinesLayer.subwayLines(of: Self.tracks, tracksID: 7, detail: detail, latitude: Self.latitude).compactMap { $0?.id }
        let other = NearbyLinesLayer.subwayLines(of: Self.tracks, tracksID: 7, detail: .simplified(step: 3), latitude: Self.latitude)
            .compactMap { $0?.id }
        #expect(a == b)
        #expect(Set(a).count == a.count)
        #expect(Set(a).isDisjoint(with: other))
    }
}

/// Bus stops' tags on Nearby's map placed clear of each other where they can be
/// (`BusTagLayout`): as they are, else in a stop's tag just by them, else moved along their
/// street, else (past close in) over others as long as most shows, close in hidden.
struct BusTagLayoutTests {
    private static func tag(_ id: String, x: CGFloat, y: CGFloat = 0, width: CGFloat = 40, angle: Double = 0,
                            lines: [String], serves: [String]? = nil) -> BusTagLayout.Tag {
        BusTagLayout.Tag(id: id, rect: CGRect(x: x - width / 2, y: y - 12, width: width, height: 24),
                         stop: CGPoint(x: x, y: y + 14), angle: angle, lines: lines, serves: Set(serves ?? lines))
    }

    /// `tags` placed one after another, with `others` (other marks) placed first.
    private static func placed(_ tags: [BusTagLayout.Tag], others: [CGRect] = [], close: Bool = false)
        -> (decisions: [String: BusTagLayout.Decision], shown: [BusTagLayout.Shown], extra: [String: [String]]) {
        var placed = others
        var shown: [BusTagLayout.Shown] = []
        var extra: [String: [String]] = [:]
        var decisions: [String: BusTagLayout.Decision] = [:]
        for tag in tags {
            decisions[tag.id] = BusTagLayout.place(tag, placed: &placed, shown: &shown, extra: &extra, close: close,
                                                   width: { CGFloat($0.count) * 30 })
        }
        return (decisions, shown, extra)
    }

    @Test func clearShowsAsIs() {
        let result = Self.placed([Self.tag("a", x: 0, lines: ["B61"]), Self.tag("b", x: 100, lines: ["B103"])])
        #expect(result.decisions["a"] == .shown(nudge: .zero))
        #expect(result.decisions["b"] == .shown(nudge: .zero))
    }

    @Test func overAStopByItGoingTheSameWayJoinsIt() {
        // B103 over the B61's tag, stopping there too: in its tag
        let result = Self.placed([Self.tag("a", x: 0, lines: ["B61"], serves: ["B61", "B103"]),
                                  Self.tag("b", x: 20, lines: ["B103"])])
        #expect(result.decisions["b"] == .joined(into: "a"))
        #expect(result.extra["a"] == ["B103"])
        #expect(result.shown.count == 1)
        #expect(result.shown[0].rect.width == 70)
    }

    @Test func notJoinedTheOtherWayOrWhereItDoesntStop() {
        // Going the other way: moved along its street instead
        let opposite = Self.placed([Self.tag("a", x: 0, lines: ["B61"], serves: ["B61", "B103"]),
                                    Self.tag("b", x: 20, angle: .pi, lines: ["B103"])])
        guard case .shown(let nudge) = opposite.decisions["b"] else {
            Issue.record("Not shown: \(String(describing: opposite.decisions["b"]))")
            return
        }
        #expect(nudge.width != 0 && abs(nudge.width) <= 24)
        #expect(!opposite.shown[0].rect.intersects(opposite.shown[1].rect))
        // Its buses not stopping at the other: not joined
        let elsewhere = Self.placed([Self.tag("a", x: 0, lines: ["B61"]), Self.tag("b", x: 20, lines: ["B103"])])
        #expect(elsewhere.decisions["b"] != .joined(into: "a"))
    }

    @Test func nudgedTheShortestWayAlongItsStreet() {
        // Up the screen (y down): moved along y only
        let result = Self.placed([Self.tag("a", x: 0, lines: ["B61"]),
                                  Self.tag("b", x: 10, y: 20, angle: -.pi / 2, lines: ["B63"])])
        guard case .shown(let nudge) = result.decisions["b"] else {
            Issue.record("Not shown")
            return
        }
        #expect(abs(nudge.width) < 0.001)
        #expect(nudge.height == 8)
    }

    @Test func crowdedPastCloseInShowsIfMostShowsCloseInHides() {
        // Boxed in by marks either way along its street
        let others = (-3...3).map { CGRect(x: -20, y: CGFloat($0) * 26 - 12, width: 40, height: 24) }
        let boxed = Self.tag("b", x: 30, angle: .pi / 2, lines: ["B63"])
        #expect(Self.placed([boxed], others: others).decisions["b"] == .shown(nudge: .zero))
        #expect(Self.placed([boxed], others: others, close: true).decisions["b"] == .hidden)
        let under = Self.tag("c", x: 0, angle: .pi / 2, lines: ["B63"])
        #expect(Self.placed([under], others: others).decisions["c"] == .hidden)
        // Over most of a small mark, if not most of itself: hidden
        let dot = CGRect(x: 18, y: -6, width: 12, height: 12)
        #expect(Self.placed([Self.tag("d", x: 40, width: 60, angle: .pi / 2, lines: ["B63"])], others: others + [dot])
            .decisions["d"] == .hidden)
    }

    /// The tags round a place, as Nearby names them (each line once at its stop nearest; close
    /// in, once each way), placed as before and now, at each zoom: how many overlap.
    @Test(arguments: [("4 Av-9 St", 40.6708, -73.9883), ("Jay St-MetroTech", 40.6923, -73.9873),
                      ("Flatbush/Atlantic", 40.6843, -73.9776)])
    func fewerOverlapsRoundRealStops(place: String, latitude: Double, longitude: Double) {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let near = TrackShapes.busStops
            .map { (stop: $0, meters: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: here)) }
            .filter { $0.meters < 500 }
            .sorted { $0.meters < $1.meters }
        let drawn = Set(near.filter { $0.meters < 400 }.flatMap { $0.stop.lines.map(TrackShapes.busKey) })
        var report: [String] = []
        for metersPerPoint in [1.2, 2.5, 3.5, 6.0] {
            let close = metersPerPoint < 1.5, arrow = metersPerPoint <= 4
            var named: Set<String> = [], firstWay: [String: Double] = [:]
            var tags: [BusTagLayout.Tag] = []
            for (index, (stop, _)) in near.enumerated() {
                var fresh: [String] = []
                for line in stop.lines {
                    let key = TrackShapes.busKey(line)
                    guard drawn.contains(key) else { continue }
                    var name = key
                    if close, let angle = stop.angle {
                        if let first = firstWay[key] { if cos(angle - first) < 0 { name = key + " other" } } else { firstWay[key] = angle }
                    }
                    if named.insert(name).inserted { fresh.append(line) }
                }
                guard !fresh.isEmpty else { continue }
                let east = (stop.coordinate.longitude - longitude) * Earth.metresPerDegree * cos(latitude * .pi / 180)
                let north = (stop.coordinate.latitude - latitude) * Earth.metresPerDegree
                let point = CGPoint(x: east / metersPerPoint, y: -north / metersPerPoint)
                let size = BusTagLayout.size(lines: fresh, arrow: arrow)
                let angle = stop.angle ?? 0
                let out = arrow ? BusTagLayout.kerbOffset(angle: angle, size: size) : 0
                let middle = CGPoint(x: point.x - sin(angle) * out, y: point.y + cos(angle) * out)
                let rect = CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2,
                                  width: size.width, height: size.height).insetBy(dx: -3, dy: -3)
                // On a phone's screen of map
                guard abs(point.x) < 200, abs(point.y) < 250 else { continue }
                tags.append(BusTagLayout.Tag(id: "\(index)", rect: rect, stop: point, angle: angle, lines: fresh,
                                             serves: Set(stop.lines.map(TrackShapes.busKey))))
            }
            // Before: shown if no mark covered much of it, whatever it covered
            var before: [CGRect] = []
            for tag in tags where before.allSatisfy({ other in
                let overlap = other.intersection(tag.rect)
                return overlap.isNull || overlap.width * overlap.height <= tag.rect.width * tag.rect.height * 0.35
            }) { before.append(tag.rect) }
            var placed: [CGRect] = [], shown: [BusTagLayout.Shown] = [], extra: [String: [String]] = [:]
            var hidden = 0, joined = 0
            for tag in tags {
                switch BusTagLayout.place(tag, placed: &placed, shown: &shown, extra: &extra, close: close,
                                          width: { BusTagLayout.badgesWidth($0) + CGFloat($0.count) * 2 }) {
                case .hidden: hidden += 1
                case .joined: joined += 1
                case .shown: break
                }
            }
            /// Pairs of tags drawn over each other, as drawn (without the room round them)
            func overlaps(_ rects: [CGRect]) -> Int {
                let drawn = rects.map { $0.insetBy(dx: 3, dy: 3) }
                return drawn.indices.reduce(0) { total, a in
                    total + drawn.indices.filter { $0 > a && drawn[a].intersects(drawn[$0]) }.count
                }
            }
            let was = overlaps(before), now = overlaps(shown.map(\.rect))
            report.append("\(metersPerPoint) m/pt: \(tags.count) tags, overlapping \(was) → \(now), "
                          + "shown \(before.count) → \(shown.count), joined \(joined), hidden \(hidden)")
            #expect(now <= was, "\(place) at \(metersPerPoint) m/pt")
            if close { #expect(now == 0, "\(place) close in") }
        }
        print("Bus tags round \(place): " + report.joined(separator: "; "))
    }
}
