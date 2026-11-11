import Foundation

/// The city's walking graph, bundled as walkgraph.sqlite (`tools/make_walk_graph.py`), for
/// routing walks by how safe their crossings are (`WalkRouter`). From NYC's Street Centerline:
/// every block of every street, path and walkway, and OpenStreetMap's paths in parks.
///
/// Junctions are where blocks' ends meet at the same level, each with its arms (the blocks
/// leaving it) clockwise. Between each arm and the next clockwise is a corner: where the two
/// streets' sidewalks meet, or a path's line, or a median between a divided road's halves.
/// Walking a street's side goes from a corner at one end to a corner at the other; crossing a
/// street goes from the corner on one side of its arm to the corner on the other.
struct WalkGraph: Sendable {
    /// The file layout this reads (`make_walk_graph.py`'s `FORMAT`).
    static let format = "5"

    /// Metres in a degree of latitude, and of longitude at the graph's own latitude: corners
    /// are placed in that plane.
    static let metresNorth = Earth.metresPerDegree
    static let metresEast = Earth.metresPerDegree * cos(40.7 * .pi / 180)

    enum Class: UInt8, Sendable {
        /// A street, with a side each way to walk along.
        case walk
        /// A path, walkway, plaza or step street: one way along, nothing to cross.
        case path
        /// A highway, ramp, tunnel, driveway or vehicle-only bridge: crossed, never walked along.
        case arm
    }

    struct BlockFlags: OptionSet, Sendable {
        let rawValue: UInt16
        static let oneWay = BlockFlags(rawValue: 1 << 0)
        static let truckLocal = BlockFlags(rawValue: 1 << 1)
        static let truckThrough = BlockFlags(rawValue: 1 << 2)
        static let bikeLane = BlockFlags(rawValue: 1 << 3)
        static let carFree = BlockFlags(rawValue: 1 << 4)
        /// An expressway or ramp runs over it.
        static let underElevated = BlockFlags(rawValue: 1 << 5)
        /// The bit of a cross street between a divided road's halves.
        static let median = BlockFlags(rawValue: 1 << 6)
        static let steps = BlockFlags(rawValue: 1 << 7)
        static let fromOSM = BlockFlags(rawValue: 1 << 8)
        /// A short link the build made, from a path's loose end to the street it stops at.
        static let connector = BlockFlags(rawValue: 1 << 9)
        static let alley = BlockFlags(rawValue: 1 << 10)
        /// An OSM sidewalk runs along its left (right) side: walked on OSM's, not this side.
        static let coveredLeft = BlockFlags(rawValue: 1 << 11)
        static let coveredRight = BlockFlags(rawValue: 1 << 12)
        /// One of OSM's sidewalks, its traffic its street's.
        static let osmSidewalk = BlockFlags(rawValue: 1 << 13)
        /// One of OSM's crosswalks, over the street it names (`Crossing`).
        static let crosswalk = BlockFlags(rawValue: 1 << 14)
        /// One of OSM's traffic islands, a refuge in the street.
        static let island = BlockFlags(rawValue: 1 << 15)
    }

    /// What one of OSM's crosswalks has.
    struct Crossing: OptionSet, Sendable {
        let rawValue: UInt8
        static let signal = Crossing(rawValue: 1 << 0)
        /// The walk signal comes first.
        static let leading = Crossing(rawValue: 1 << 1)
        /// Every car stops.
        static let exclusive = Crossing(rawValue: 1 << 2)
        static let marked = Crossing(rawValue: 1 << 3)
        static let unmarked = Crossing(rawValue: 1 << 4)
        static let island = Crossing(rawValue: 1 << 5)
        /// Over a highway's ramp.
        static let ramp = Crossing(rawValue: 1 << 6)
    }

    /// A junction's safety, from NYC DOT's Vision Zero lists.
    struct Safety: OptionSet, Sendable {
        let rawValue: UInt8
        static let priority = Safety(rawValue: 1 << 0)
    }

    /// A block's safety: on a Vision Zero priority corridor; a crosswalk at a priority
    /// intersection, and its curb ramps.
    struct BlockSafety: OptionSet, Sendable {
        let rawValue: UInt8
        static let corridor = BlockSafety(rawValue: 1 << 0)
        static let priority = BlockSafety(rawValue: 1 << 1)
        static let rampAtStart = BlockSafety(rawValue: 1 << 2)
        static let rampAtEnd = BlockSafety(rawValue: 1 << 3)
    }

    /// The parts of the day crime's counted in, by the hour it started: day 6–18, evening
    /// 18–23, late 23–6.
    enum Band: Int, CaseIterable, Hashable, Sendable {
        case day, evening, late

        init(hour: Int) {
            self = 6..<18 ~= hour ? .day : 18..<23 ~= hour ? .evening : .late
        }
    }

    /// A path at night: away from the street lights and not tagged lit (or tagged unlit), or
    /// in a park, which closes 1–6.
    struct Night: OptionSet, Sendable {
        let rawValue: UInt8
        static let dark = Night(rawValue: 1 << 0)
        static let park = Night(rawValue: 1 << 1)
    }

    enum CornerKind: UInt8, Sendable {
        /// In the street, or off the city's sidewalks.
        case none
        case sidewalk
        /// In the median of a divided road.
        case refuge
        /// Where paths meet, on their line.
        case path
    }

    // Junctions
    let nodeLat: [Int32]
    let nodeLon: [Int32]
    /// The city's level code: `grade` on the ground, more up on a bridge or a viaduct, less
    /// down in a tunnel.
    let nodeLevel: [UInt8]
    static let grade: UInt8 = 13
    /// What the signals there do (`Sidewalks.Signal.Kind`'s bits); 0 for none.
    let nodeSignal: [UInt8]
    /// The walkable part it's in, 0 the biggest: a walk's ends must be in the same one.
    let nodePart: [UInt32]
    // Arms, each junction's from `armStart[node]`, clockwise, and the corner after each
    let armStart: [UInt32]
    let armBlock: [UInt32]
    /// 0 where the arm is its block's start, 1 its end.
    let armEnd: [UInt8]
    /// Decimetres east and north of the junction.
    let cornerDX: [Int16]
    let cornerDY: [Int16]
    let cornerKind: [UInt8]
    /// The OSM sidewalk junction a city corner's linked to (`noLink` for none): where a walk
    /// steps between the city's streets and OSM's sidewalks.
    let cornerLink: [UInt32]
    static let noLink = UInt32.max
    // Blocks
    let blockA: [UInt32]
    let blockB: [UInt32]
    /// Its arm's place in each end's arms.
    let blockSlotA: [UInt16]
    let blockSlotB: [UInt16]
    let blockClass: [UInt8]
    /// The city's roadway type (CSCL RW_TYPE).
    let blockRW: [UInt8]
    let blockFlags: [UInt16]
    let blockName: [UInt32]
    /// Decimetres curb to curb.
    let blockWidth: [UInt16]
    let blockLanes: [UInt8]
    /// Miles per hour; 0 where not known.
    let blockSpeed: [UInt8]
    /// Decimetres.
    let blockLength: [UInt32]
    /// Quarter metres from its line to each side's sidewalk middle, left and right going from
    /// its start to its end; 0 for no sidewalk.
    let blockOffsetLeft: [UInt8]
    let blockOffsetRight: [UInt8]
    // Lines, each block's from `geomStart[block]`, millionths of a degree
    let geomStart: [UInt32]
    let geomLat: [Int32]
    let geomLon: [Int32]
    /// A crosswalk's `Crossing` bits; 0 for any other block.
    let blockCrossing: [UInt8]
    /// A street's sides OSM maps sidewalks round but not along (1 left, 2 right).
    let blockSides: [UInt8]
    /// What's known of a junction's safety (`Safety` bits) and the pedestrians hurt there in
    /// five years, each killed as five (`make_walk_graph.py`'s `safety_at`), at most 255.
    let nodeSafety: [UInt8]
    let nodeCrashes: [UInt8]
    /// 1 where a corner has a curb ramp.
    let cornerRamp: [UInt8]
    /// A block's `BlockSafety` bits, and a crosswalk's pedestrians hurt, as `nodeCrashes`.
    let blockSafety: [UInt8]
    let blockCrashes: [UInt8]
    /// Crime against people outdoors over the average of the streets within 400 m, in quarter
    /// crimes over three years, by part of the day (`Band`): a junction's at its corners, a
    /// block's per 100 m, a crosswalk's its junction's (`make_walk_graph.py`'s `add_night`).
    let nodeCrime: [[UInt8]]
    let blockCrime: [[UInt8]]
    /// Shops per 100 m along a street, and its sidewalks, at most 255.
    let blockShops: [UInt8]
    /// A path's `Night` bits.
    let blockNight: [UInt8]
    /// Street names as the city has them ("4 AVE", "W 43 ST"), by `blockName`.
    let names: [String]
    /// The blocks running off the loaded tiles.
    let blockCut: Set<Int>

    enum LoadError: Error {
        case missing(String)
        case size(String)
    }

    /// The graph from tiles of its file (`make_walk_graph.py`'s `tile_arrays`), each a tile's
    /// arrays (raw-deflated little-endian, by name), and the names: only those tiles' junctions
    /// and blocks, by ids of its own. A block leading off them is a street to cross, not to walk.
    init(tiles: [[String: Data]], names: [Int: String]) throws {
        func array<T: FixedWidthInteger>(_ tile: [String: Data], _ name: String, _: T.Type = T.self) throws -> [T] {
            guard let packed = tile[name] else { throw LoadError.missing(name) }
            let data = try (packed as NSData).decompressed(using: .zlib) as Data
            guard data.count % MemoryLayout<T>.size == 0 else { throw LoadError.size(name) }
            return data.withUnsafeBytes { raw in
                (0..<(data.count / MemoryLayout<T>.size)).map {
                    T(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self))
                }
            }
        }
        var nodeLat: [Int32] = [], nodeLon: [Int32] = [], nodeLevel: [UInt8] = [], nodeSignal: [UInt8] = []
        var nodePart: [UInt32] = [], nodeSafety: [UInt8] = [], nodeCrashes: [UInt8] = [], cornerRamp: [UInt8] = []
        var blockSafety: [UInt8] = [], blockCrashes: [UInt8] = []
        var nodeCrime: [[UInt8]] = [[], [], []], blockCrime: [[UInt8]] = [[], [], []]
        var blockShops: [UInt8] = [], blockNight: [UInt8] = []
        var armStart: [UInt32] = [], armBlock: [UInt32] = [], armEnd: [UInt8] = []
        var cornerDX: [Int16] = [], cornerDY: [Int16] = [], cornerKind: [UInt8] = [], cornerLink: [UInt32] = []
        var blockA: [UInt32] = [], blockB: [UInt32] = [], blockSlotA: [UInt16] = [], blockSlotB: [UInt16] = []
        var blockClass: [UInt8] = [], blockRW: [UInt8] = [], blockFlags: [UInt16] = [], blockName: [UInt32] = []
        var blockWidth: [UInt16] = [], blockLanes: [UInt8] = [], blockSpeed: [UInt8] = [], blockLength: [UInt32] = []
        var blockOffsetLeft: [UInt8] = [], blockOffsetRight: [UInt8] = [], blockCrossing: [UInt8] = [], blockSides: [UInt8] = []
        var geomStart: [UInt32] = [], geomLat: [Int32] = [], geomLon: [Int32] = []
        // Global ids to these
        var nodeIndex: [UInt32: UInt32] = [:], blockIndex: [UInt32: UInt32] = [:]
        for tile in tiles {
            let ids: [UInt32] = try array(tile, "node_id"), counts: [UInt16] = try array(tile, "node_arms")
            for (i, id) in ids.enumerated() { nodeIndex[id] = UInt32(nodeLat.count + i) }
            nodeLat += try array(tile, "node_lat")
            nodeLon += try array(tile, "node_lon")
            nodeLevel += try array(tile, "node_level")
            nodeSignal += try array(tile, "node_signal")
            nodePart += try array(tile, "node_part")
            nodeSafety += try array(tile, "node_safety")
            nodeCrashes += try array(tile, "node_crashes")
            for band in Band.allCases { nodeCrime[band.rawValue] += try array(tile, "node_crime_\(band)") }
            var at = armBlock.count
            for count in counts {
                armStart.append(UInt32(at))
                at += Int(count)
            }
            // The arms' blocks by global id for now, put in after
            armBlock += try array(tile, "arm_block")
            armEnd += try array(tile, "arm_end")
            cornerDX += try array(tile, "corner_dx")
            cornerDY += try array(tile, "corner_dy")
            cornerKind += try array(tile, "corner_kind")
            cornerLink += try array(tile, "corner_link")
            cornerRamp += try array(tile, "corner_ramp")
            // Blocks, each once though it's in two tiles
            let blockIDs: [UInt32] = try array(tile, "block_id")
            let a: [UInt32] = try array(tile, "block_a"), b: [UInt32] = try array(tile, "block_b")
            let slotA: [UInt16] = try array(tile, "block_slot_a"), slotB: [UInt16] = try array(tile, "block_slot_b")
            let classes: [UInt8] = try array(tile, "block_class"), rws: [UInt8] = try array(tile, "block_rw")
            let flags: [UInt16] = try array(tile, "block_flags"), names: [UInt32] = try array(tile, "block_name")
            let widths: [UInt16] = try array(tile, "block_width"), lanes: [UInt8] = try array(tile, "block_lanes")
            let speeds: [UInt8] = try array(tile, "block_speed"), lengths: [UInt32] = try array(tile, "block_length")
            let lefts: [UInt8] = try array(tile, "block_offset_left"), rights: [UInt8] = try array(tile, "block_offset_right")
            let crossings: [UInt8] = try array(tile, "block_crossing"), sides: [UInt8] = try array(tile, "block_sides")
            let safeties: [UInt8] = try array(tile, "block_safety"), crashes: [UInt8] = try array(tile, "block_crashes")
            let crimes: [[UInt8]] = try Band.allCases.map { try array(tile, "block_crime_\($0)") }
            let shops: [UInt8] = try array(tile, "block_shops"), nights: [UInt8] = try array(tile, "block_night")
            let starts: [UInt32] = try array(tile, "geom_start"), whole: [UInt8] = try array(tile, "block_whole")
            let lats: [Int32] = try array(tile, "geom_lat"), lons: [Int32] = try array(tile, "geom_lon")
            for (i, id) in blockIDs.enumerated() where blockIndex[id] == nil {
                blockIndex[id] = UInt32(blockA.count)
                blockA.append(a[i]); blockB.append(b[i])
                blockSlotA.append(slotA[i]); blockSlotB.append(slotB[i])
                blockClass.append(classes[i]); blockRW.append(rws[i]); blockFlags.append(flags[i]); blockName.append(names[i])
                blockWidth.append(widths[i]); blockLanes.append(lanes[i]); blockSpeed.append(speeds[i]); blockLength.append(lengths[i])
                blockOffsetLeft.append(lefts[i]); blockOffsetRight.append(rights[i])
                blockCrossing.append(crossings[i]); blockSides.append(sides[i])
                blockSafety.append(safeties[i]); blockCrashes.append(crashes[i])
                for band in Band.allCases { blockCrime[band.rawValue].append(crimes[band.rawValue][i]) }
                blockShops.append(shops[i]); blockNight.append(nights[i])
                // Its line: its first point, then each one's change from the one before; only
                // the points between its ends where both are this tile's junctions
                geomStart.append(UInt32(geomLat.count))
                let ends = whole[i] == 0 ? (nodeIndex[a[i]].map(Int.init), nodeIndex[b[i]].map(Int.init)) : (nil, nil)
                if let first = ends.0 {
                    geomLat.append(nodeLat[first])
                    geomLon.append(nodeLon[first])
                }
                var lat: Int32 = 0, lon: Int32 = 0
                for g in Int(starts[i])..<Int(starts[i + 1]) {
                    lat &+= lats[g]
                    lon &+= lons[g]
                    geomLat.append(lat)
                    geomLon.append(lon)
                }
                if let last = ends.1 {
                    geomLat.append(nodeLat[last])
                    geomLon.append(nodeLon[last])
                }
            }
        }
        armStart.append(UInt32(armBlock.count))
        geomStart.append(UInt32(geomLat.count))
        // Global ids to these: an arm's block's always here, being in its junction's tile
        armBlock = try armBlock.map { id in
            guard let index = blockIndex[id] else { throw LoadError.missing("block \(id)") }
            return index
        }
        cornerLink = cornerLink.map { $0 == Self.noLink ? Self.noLink : nodeIndex[$0] ?? Self.noLink }
        var blockCut = Set<Int>()
        for block in blockA.indices {
            if let a = nodeIndex[blockA[block]], let b = nodeIndex[blockB[block]] {
                blockA[block] = a
                blockB[block] = b
            } else {
                // Off the tiles at one end: crossed where it's here, as what it is, but never
                // walked off them
                blockA[block] = nodeIndex[blockA[block]] ?? 0
                blockB[block] = nodeIndex[blockB[block]] ?? 0
                blockCut.insert(block)
            }
        }
        self.nodeLat = nodeLat; self.nodeLon = nodeLon; self.nodeLevel = nodeLevel; self.nodeSignal = nodeSignal
        self.nodePart = nodePart
        self.armStart = armStart; self.armBlock = armBlock; self.armEnd = armEnd
        self.cornerDX = cornerDX; self.cornerDY = cornerDY; self.cornerKind = cornerKind; self.cornerLink = cornerLink
        self.blockA = blockA; self.blockB = blockB; self.blockSlotA = blockSlotA; self.blockSlotB = blockSlotB
        self.blockClass = blockClass; self.blockRW = blockRW; self.blockFlags = blockFlags; self.blockName = blockName
        self.blockWidth = blockWidth; self.blockLanes = blockLanes; self.blockSpeed = blockSpeed; self.blockLength = blockLength
        self.blockOffsetLeft = blockOffsetLeft; self.blockOffsetRight = blockOffsetRight
        self.blockCrossing = blockCrossing; self.blockSides = blockSides
        self.blockCut = blockCut
        self.nodeSafety = nodeSafety; self.nodeCrashes = nodeCrashes; self.cornerRamp = cornerRamp
        self.blockSafety = blockSafety; self.blockCrashes = blockCrashes
        self.nodeCrime = nodeCrime; self.blockCrime = blockCrime; self.blockShops = blockShops; self.blockNight = blockNight
        self.geomStart = geomStart; self.geomLat = geomLat; self.geomLon = geomLon
        let count = (names.keys.max() ?? -1) + 1
        self.names = (0..<count).map { names[$0] ?? "" }
    }

    /// Metres across a tile of the file, from (40.7, -74.0) in the plane the graph's corners are
    /// in: the tiles `x` and `y` round `point`'s are those within `metres` of it.
    static let tile = 2000.0

    /// The tiles (x, y) within `metres` of a box round `points`.
    static func tiles(around points: [Walk.Point], metres: Double) -> [(x: Int, y: Int)] {
        let xs = points.map { ($0.lon + 74.0) * metresEast }, ys = points.map { ($0.lat - 40.7) * metresNorth }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return [] }
        let lowX = Int(((x0 - metres) / tile).rounded(.down)), highX = Int(((x1 + metres) / tile).rounded(.down))
        let lowY = Int(((y0 - metres) / tile).rounded(.down)), highY = Int(((y1 + metres) / tile).rounded(.down))
        return (lowX...highX).flatMap { x in (lowY...highY).map { (x, $0) } }
    }

    /// The tiles (x, y) within `metres` of the straight line from `start` to `end`: a walk's
    /// corridor, not the whole box round it, which for one across the city is many times more.
    static func tiles(along start: Walk.Point, to end: Walk.Point, metres: Double) -> [(x: Int, y: Int)] {
        func plane(_ p: Walk.Point) -> (Double, Double) { ((p.lon + 74.0) * metresEast, (p.lat - 40.7) * metresNorth) }
        let a = plane(start), b = plane(end)
        let dx = b.0 - a.0, dy = b.1 - a.1, length2 = dx * dx + dy * dy
        // A tile's in if its middle's within `metres` and half its diagonal of the line
        let reach = metres + tile * 0.5.squareRoot()
        return tiles(around: [start, end], metres: metres).filter { t in
            let mx = (Double(t.x) + 0.5) * tile, my = (Double(t.y) + 0.5) * tile
            let along = length2 > 0 ? min(1, max(0, ((mx - a.0) * dx + (my - a.1) * dy) / length2)) : 0
            let ex = mx - (a.0 + along * dx), ey = my - (a.1 + along * dy)
            return (ex * ex + ey * ey).squareRoot() <= reach
        }
    }

    var nodeCount: Int { nodeLat.count }
    var blockCount: Int { blockA.count }

    // MARK: Junctions and corners

    func point(ofNode node: Int) -> Walk.Point {
        Walk.Point(lat: Double(nodeLat[node]) / 1e6, lon: Double(nodeLon[node]) / 1e6)
    }

    /// The junction's arms, as indices into the arm arrays, clockwise.
    func arms(of node: Int) -> Range<Int> {
        Int(armStart[node])..<Int(armStart[node + 1])
    }

    /// The junction an arm leaves.
    func node(ofArm arm: Int) -> Int {
        let block = Int(armBlock[arm])
        return Int(armEnd[arm] == 0 ? blockA[block] : blockB[block])
    }

    /// The corner after arm `arm` clockwise, between it and the next.
    func corner(_ arm: Int) -> Walk.Point {
        let node = node(ofArm: arm)
        return Walk.Point(lat: Double(nodeLat[node]) / 1e6 + Double(cornerDY[arm]) / 10 / Self.metresNorth,
                          lon: Double(nodeLon[node]) / 1e6 + Double(cornerDX[arm]) / 10 / Self.metresEast)
    }

    func kind(ofCorner arm: Int) -> CornerKind {
        CornerKind(rawValue: cornerKind[arm]) ?? .none
    }

    /// The arm before `arm` clockwise at its junction, wrapping round.
    func previous(_ arm: Int, at node: Int) -> Int {
        let range = arms(of: node)
        return arm == range.lowerBound ? range.upperBound - 1 : arm - 1
    }

    /// The arm after `arm` clockwise at its junction, wrapping round.
    func next(_ arm: Int, at node: Int) -> Int {
        let range = arms(of: node)
        return arm + 1 == range.upperBound ? range.lowerBound : arm + 1
    }

    // MARK: Blocks

    /// How a block's walked: an arm where it runs off the loaded tiles, as it can't be
    /// walked along off them.
    func `class`(of block: Int) -> Class { blockCut.contains(block) ? .arm : crossingClass(of: block) }
    /// What a block is where it's crossed: a street, path or highway, wherever it leads.
    func crossingClass(of block: Int) -> Class { Class(rawValue: blockClass[block]) ?? .arm }
    func flags(of block: Int) -> BlockFlags { BlockFlags(rawValue: blockFlags[block]) }
    func crossing(of block: Int) -> Crossing { Crossing(rawValue: blockCrossing[block]) }

    /// Whether OSM maps sidewalks all round a street's side but not along it: most likely
    /// there's none worth walking.
    func isUnmapped(_ block: Int, left: Bool) -> Bool {
        blockSides[block] & (left ? 1 : 2) != 0
    }

    /// Whether a street's side is walked on OSM's sidewalk instead.
    func isCovered(_ block: Int, left: Bool) -> Bool {
        flags(of: block).contains(left ? .coveredLeft : .coveredRight)
    }
    func name(of block: Int) -> String { names[Int(blockName[block])] }
    func safety(ofNode node: Int) -> Safety { Safety(rawValue: nodeSafety[node]) }
    func safety(of block: Int) -> BlockSafety { BlockSafety(rawValue: blockSafety[block]) }
    /// Whether a corner has a curb ramp.
    func hasRamp(_ corner: Int) -> Bool { cornerRamp[corner] != 0 }
    /// Crimes over the neighbours' average at a junction's corners in three years, in `band`.
    func crime(ofNode node: Int, in band: Band) -> Double { Double(nodeCrime[band.rawValue][node]) / 4 }
    /// Crimes per 100 m over the neighbours' average along a block in three years, in `band`;
    /// a crosswalk's at its junction.
    func crime(of block: Int, in band: Band) -> Double { Double(blockCrime[band.rawValue][block]) / 4 }
    func shops(of block: Int) -> Double { Double(blockShops[block]) }
    func night(of block: Int) -> Night { Night(rawValue: blockNight[block]) }
    /// Metres along it.
    func length(of block: Int) -> Double { Double(blockLength[block]) / 10 }
    /// Whether its start (`end` 0) or end (1) is on the ground, not up on a bridge or down a tunnel.
    func atGrade(_ block: Int, end: Int) -> Bool {
        nodeLevel[Int(end == 0 ? blockA[block] : blockB[block])] == Self.grade
    }
    /// Metres curb to curb; 0 where not known.
    func width(of block: Int) -> Double { Double(blockWidth[block]) / 10 }

    /// Its arm at its start (`end` 0) or end (1), as an index into the arm arrays.
    func arm(of block: Int, end: Int) -> Int {
        end == 0 ? Int(armStart[Int(blockA[block])]) + Int(blockSlotA[block])
                 : Int(armStart[Int(blockB[block])]) + Int(blockSlotB[block])
    }

    /// The corners its sides run between, going from its start to its end: on its left, from
    /// the corner before its arm at the start to the corner after its arm at the end; on its
    /// right, from the corner after it at the start to the one before it at the end.
    func sideCorners(of block: Int, left: Bool) -> (from: Int, to: Int) {
        let atA = arm(of: block, end: 0), atB = arm(of: block, end: 1)
        let a = Int(blockA[block]), b = Int(blockB[block])
        return left ? (previous(atA, at: a), atB) : (atA, previous(atB, at: b))
    }

    /// Metres from its line to a side's sidewalk middle; 0 for no sidewalk.
    func offset(of block: Int, left: Bool) -> Double {
        Double(left ? blockOffsetLeft[block] : blockOffsetRight[block]) / 4
    }

    /// Its line, from its start to its end.
    func line(of block: Int) -> [Walk.Point] {
        (Int(geomStart[block])..<Int(geomStart[block + 1])).map {
            Walk.Point(lat: Double(geomLat[$0]) / 1e6, lon: Double(geomLon[$0]) / 1e6)
        }
    }
}
