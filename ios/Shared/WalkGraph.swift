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
    static let format = "1"

    /// Metres in a degree of latitude, and of longitude at the graph's own latitude: corners
    /// are placed in that plane.
    static let metresNorth = 111_320.0
    static let metresEast = 111_320.0 * cos(40.7 * .pi / 180)

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
    let nodeLevel: [UInt8]
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
    /// Street names as the city has them ("4 AVE", "W 43 ST"), by `blockName`.
    let names: [String]

    enum LoadError: Error {
        case missing(String)
        case size(String)
    }

    /// The graph from its file's arrays (raw-deflated little-endian, by name) and names.
    init(arrays: [String: Data], names: [Int: String]) throws {
        func array<T: FixedWidthInteger>(_ name: String, _: T.Type = T.self) throws -> [T] {
            guard let packed = arrays[name] else { throw LoadError.missing(name) }
            let data = try (packed as NSData).decompressed(using: .zlib) as Data
            guard data.count % MemoryLayout<T>.size == 0 else { throw LoadError.size(name) }
            return data.withUnsafeBytes { raw in
                (0..<(data.count / MemoryLayout<T>.size)).map {
                    T(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self))
                }
            }
        }
        nodeLat = try array("node_lat")
        nodeLon = try array("node_lon")
        nodeLevel = try array("node_level")
        nodeSignal = try array("node_signal")
        nodePart = try array("node_part")
        armStart = try array("arm_start")
        armBlock = try array("arm_block")
        armEnd = try array("arm_end")
        cornerDX = try array("corner_dx")
        cornerDY = try array("corner_dy")
        cornerKind = try array("corner_kind")
        blockA = try array("block_a")
        blockB = try array("block_b")
        blockSlotA = try array("block_slot_a")
        blockSlotB = try array("block_slot_b")
        blockClass = try array("block_class")
        blockRW = try array("block_rw")
        blockFlags = try array("block_flags")
        blockName = try array("block_name")
        blockWidth = try array("block_width")
        blockLanes = try array("block_lanes")
        blockSpeed = try array("block_speed")
        blockLength = try array("block_length")
        blockOffsetLeft = try array("block_offset_left")
        blockOffsetRight = try array("block_offset_right")
        geomStart = try array("geom_start")
        // Each block's first point, then each one's change from the one before
        var lat: [Int32] = try array("geom_lat"), lon: [Int32] = try array("geom_lon")
        for block in 0..<(geomStart.count - 1) {
            let start = Int(geomStart[block]), end = Int(geomStart[block + 1])
            guard start + 1 < end else { continue }
            for i in (start + 1)..<end {
                lat[i] &+= lat[i - 1]
                lon[i] &+= lon[i - 1]
            }
        }
        geomLat = lat
        geomLon = lon
        let count = (names.keys.max() ?? -1) + 1
        self.names = (0..<count).map { names[$0] ?? "" }
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

    func `class`(of block: Int) -> Class { Class(rawValue: blockClass[block]) ?? .arm }
    func flags(of block: Int) -> BlockFlags { BlockFlags(rawValue: blockFlags[block]) }
    func name(of block: Int) -> String { names[Int(blockName[block])] }
    /// Metres along it.
    func length(of block: Int) -> Double { Double(blockLength[block]) / 10 }
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
