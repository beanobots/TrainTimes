import Foundation

/// How New Trip ranks its trips beside walking all the way, and which it keeps beside a walk:
/// plain minutes and seconds in, so the rules stand apart from the view. What a ride's wait,
/// changes and walks count against it is the planners' (`TripPlanner.penalty`,
/// `BusTrip.penalty`); this weighs that against walking.
enum TripRanking {
    /// Walking all the way shorter than this goes ahead of a ride unless the ride beats it by
    /// `walkMargin` of it: no one wants to wait for a bus to save two minutes.
    static let walkMarginUnder = 30
    static let walkMargin = 0.2

    /// How many times your comfortable walk a walk all the way is, at least, to be said to be long.
    static let longWalk = 1.6

    /// Longest walk all the way offered at all, even with nothing else: past it, No Trip Found
    /// rather than an eight-hour walk from Glen Oaks to Times Square. With No Limit, any.
    static let longestWalk = 120

    /// What walking all the way, shown taking `minutes`, is ranked by, in seconds: under
    /// `walkMarginUnder` minutes, `walkMargin` less, so a ride has to beat it by that. Its walk
    /// counts nothing more (`TripPlanner.walkWeight` is for a ride's walks only).
    static func walkEffort(minutes: Int) -> TimeInterval {
        let seconds = TimeInterval(minutes * 60)
        return minutes < walkMarginUnder ? seconds * (1 - walkMargin) : seconds
    }

    /// What a ride by train, bus or bike, shown taking `minutes`, is ranked by, in seconds: those,
    /// and what its walks, wait and changes count against it (`penalty`).
    static func rideEffort(minutes: Int, penalty: TimeInterval) -> TimeInterval {
        TimeInterval(minutes * 60) + penalty
    }

    /// The trips' new order, as indices into `efforts` (nil for one that can't be timed), best
    /// first: those it can't time keep their places, those it can fill the others in order;
    /// ties keep theirs, but for walking all the way (`walkAll`), which wins them.
    static func order(efforts: [TimeInterval?], walkAll: [Bool]) -> [Int] {
        func walks(_ index: Int) -> Int { walkAll[index] ? 0 : 1 }
        // The timed ones' places, and the timed ones best first (a stable sort, so ties keep
        // their order)
        let timed = efforts.indices.filter { efforts[$0] != nil }
        let sorted = timed.enumerated()
            .sorted { (efforts[$0.element] ?? 0, walks($0.element), $0.offset)
                < (efforts[$1.element] ?? 0, walks($1.element), $1.offset) }
            .map(\.element)
        var order = Array(efforts.indices)
        for (slot, index) in zip(timed, sorted) {
            order[slot] = index
        }
        return order
    }

    /// Whether walking all the way, `minutes`, is well past your `comfortable` walk (`longWalk`
    /// times it), for a word on its row. Never with No Limit.
    static func walkIsLong(minutes: Int, comfortable: Int, noLimit: Bool) -> Bool {
        !noLimit && Double(minutes) >= longWalk * Double(comfortable)
    }

    /// Whether walking all the way, routed as `minutes`, is offered: always, beside rides or
    /// alone, up to `longestWalk`; any with No Limit.
    static func offersWalk(minutes: Int, noLimit: Bool) -> Bool {
        noLimit || minutes <= longestWalk
    }

    /// Whether a trip of `minutes` stays beside walking all the way, `walkMinutes`: not one that
    /// takes longer. One that can't be timed stays.
    static func keeps(minutes: Int?, besideWalk walkMinutes: Int) -> Bool {
        minutes.map { $0 <= walkMinutes } ?? true
    }

    /// The trips kept, by index, as walking all the way (`walkMinutes`) comes in after them:
    /// those `keeps` keeps, and the one `tapped`, which stays picked; of Citi Bike rides
    /// (`bikes`), those quicker than the walk, or the soonest if every one is slower.
    static func keptBesideWalk(_ walkMinutes: Int, minutes: [Int?], bikes: Set<Int>, tapped: Int?) -> [Int] {
        let bikeRows = minutes.indices.filter(bikes.contains)
        let fasterBikes = bikeRows.filter { minutes[$0].map { $0 < walkMinutes } ?? true }
        let soonestBike = bikeRows.min { (minutes[$0] ?? .max) < (minutes[$1] ?? .max) }
        return minutes.indices.filter { index in
            if index == tapped { return true }
            if bikes.contains(index) { return fasterBikes.contains(index) || (fasterBikes.isEmpty && index == soonestBike) }
            return keeps(minutes: minutes[index], besideWalk: walkMinutes)
        }
    }
}
