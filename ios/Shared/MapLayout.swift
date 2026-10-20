import Foundation

// The widgets' maps, behind their map buttons, as laid out before they're
// drawn: which stops they show and where the trains are among them. The widget
// draws them (StopList.swift and TransferMap.swift); the push server's tests
// check them, as nothing in the app can.

/// The medium widget's list of the stops between the next train and yours, at
/// most `maxRows`: the first few and yours, with the rest folded into one row.
/// The feed lists a trip's stops from the one it's at or heading for, so the
/// list starts there.
struct StopLayout {
    enum Kind: Equatable {
        case stop, folded, yours
    }

    struct Row: Identifiable {
        /// Its place in the list, from the top.
        let id: Int
        let name: String
        let kind: Kind
        /// The stop the train is at or heading for.
        let isTrainStop: Bool
        /// When a train that hasn't set off leaves its first stop.
        let departs: Date?
    }

    let rows: [Row]
    /// Where the train is, in rows from the middle of the first: 0.5 is
    /// halfway between the first two, and -0.5 is on its way to the first.
    /// Between two stops, it's as far along as the times it's due at each say.
    let trainRow: CGFloat
    /// "7 STOPS AWAY", "NEXT STOP"
    let label: String

    // What VoiceOver says; see `spoken(clock:)`
    private let line: String
    private let place: String
    private let away: String

    /// `maxRows` is 3 or more.
    init?(train: Arrival, now: Date, maxRows: Int = 4) {
        let stops = train.approach
        guard let place = train.place(now: now), !stops.isEmpty else { return nil }
        let last = stops.count - 1
        // The stop it's at or heading for, and whether it's on its way there
        let (index, onTheWay): (Int, Bool) = switch place {
        case .starting: (0, false)
        case .at(let stop): (stop, false)
        case .approaching(let stop): (stop, true)
        }

        // From the stop it just left (or is at) down to yours; with only three
        // rows for a long way, from the stop it's heading for
        var first = onTheWay ? max(0, index - 1) : index
        if maxRows < 4, last - first + 1 > maxRows { first = index }
        var shown: [Int?] = (first...last).map { $0 }
        var folded = 0
        if shown.count > maxRows {
            let kept = maxRows - 2
            folded = shown.count - kept - 1
            shown = Array(shown.prefix(kept)) + [nil, last]
        }
        rows = shown.enumerated().map { row, stop in
            guard let stop else {
                return Row(id: row, name: folded == 1 ? "1 more stop" : "\(folded) more stops", kind: .folded, isTrainStop: false, departs: nil)
            }
            return Row(
                id: row,
                name: stops[stop].name,
                kind: stop == last ? .yours : .stop,
                isTrainStop: stop == index && stop != last,
                departs: place == .starting && stop == 0 ? stops[0].time : nil
            )
        }

        let target = CGFloat(shown.firstIndex(of: index) ?? 0)
        if onTheWay, let previous = shown.firstIndex(of: index - 1) {
            // As the large Transfers map has it: as far along from the stop
            // before as the times it's due at each say
            let from = stops[index - 1].time
            let span = stops[index].time.timeIntervalSince(from)
            let along = span > 0 ? min(1, max(0, now.timeIntervalSince(from) / span)) : 0.5
            trainRow = CGFloat(previous) + CGFloat(along) * (target - CGFloat(previous))
        } else if onTheWay {
            trainRow = target - 0.5
        } else {
            trainRow = target
        }

        let away = last - index + (onTheWay ? 1 : 0)
        if onTheWay && index == last {
            label = "NEXT STOP"
        } else if away == 0 {
            label = "AT YOUR STOP"
        } else {
            label = away == 1 ? "1 STOP AWAY" : "\(away) STOPS AWAY"
        }

        line = Lines.spokenName(of: train.route)
        switch place {
        case .starting: self.place = "scheduled to leave \(stops[0].name)"
        case .at: self.place = "at \(stops[index].name)"
        case .approaching where index > 0: self.place = "between \(stops[index - 1].name) and \(stops[index].name)"
        case .approaching: self.place = "heading for \(stops[index].name)"
        }
        let yours = stops[last].name
        if onTheWay && index == last {
            self.away = "your stop is next"
        } else if away == 0 {
            self.away = "your stop"
        } else {
            self.away = away == 1 ? "1 stop from \(yours)" : "\(away) stops from \(yours)"
        }
    }

    /// Where the train is, for VoiceOver, which can't see the rail: "R train
    /// between 25 St and 36 St, 7 stops from Prospect Av", "R train scheduled
    /// to leave Bay Ridge at 8:12 AM, 12 stops from Prospect Av". `clock`
    /// writes a time.
    func spoken(clock: (Date) -> String) -> String {
        let departs = rows.first?.departs.map { " at \(clock($0))" } ?? ""
        return "\(line) \(place)\(departs), \(away)"
    }
}

/// Where the large Transfers map's stops go across the widget: the change near
/// the right edge, the others evenly spaced to its left, with room before the
/// first for a train still on its way to it.
struct TrackGeometry {
    let right: CGFloat
    let spacing: CGFloat

    /// The change's way in from the right edge, past the platform's outline.
    static let changeInset: CGFloat = 12
    /// The furthest left a train is drawn.
    static let leftmost: CGFloat = 10

    init(width: CGFloat, stops: Int) {
        right = width - Self.changeInset
        spacing = (right - Self.leftmost) / (CGFloat(max(1, stops - 1)) + 0.6)
    }

    /// Where a stop is, or a train between stops, counted from the change.
    func x(_ row: CGFloat) -> CGFloat {
        right - row * spacing
    }
}

/// Which stops the large Transfers map shows, from the change back to where
/// your train is, and where the two trains are among them, in stops from the
/// change.
struct TransferMapLayout {
    enum Kind: Equatable {
        case change, origin, stop, folded
    }

    struct Row: Identifiable {
        /// Its place in the list, from the top.
        let id: Int
        let name: String
        let kind: Kind
        /// When your train is due there; for folded stops, midway between them.
        let time: Date
        /// The train it meets stops here too.
        let shared: Bool
    }

    /// From the change, at the right end of the track, back to the left end.
    let rows: [Row]
    /// Where your train is: 0 at the change, 1.5 midway between the second and
    /// third stops, and past the last while it's on its way to it.
    let firstRow: CGFloat
    /// Where the train it meets would be on your train's way with as long to
    /// go to the change; nil without one.
    let nextRow: CGFloat?
    /// Where the train it meets is, when it's further off than the map shows:
    /// "D at 9 Av", "D between 9 Av and 36 St".
    let nextNote: String?
    /// What VoiceOver says, which can't see the tracks: where your train is,
    /// and the one it meets, by where it is or when it gets to the change;
    /// and the other stops where the two meet. "Your R train is between 25 St
    /// and Prospect Av. The D gets to Atlantic Av 2 minutes after it, and
    /// stops at 36 St too."
    let spoken: String

    /// `maxRows` is 4 or more.
    init?(connection: Connection, selection: Selection, now: Date, maxRows: Int = 6) {
        let stops = connection.arrival.approach
        let yours = Set(selection.stopIDs)
        guard let origin = stops.firstIndex(where: { yours.contains($0.id) }), origin < stops.count - 1 else { return nil }
        let last = stops.count - 1

        // The change first, then the stops between it and yours, yours, the
        // stops between yours and where the train is, and that. When there are
        // too many, the longer of the runs between folds into one row, then
        // the other.
        let between = Array((origin + 1)..<last)
        let before = origin > 1 ? Array(1..<origin) : []
        let room = maxRows - (origin > 0 ? 3 : 2)
        var foldBetween = false
        var foldBefore = false
        var shown = between.count + before.count
        for run in [between, before].sorted(by: { $0.count > $1.count }) where shown > room && run.count >= 2 {
            if run == between { foldBetween = true } else { foldBefore = true }
            shown -= run.count - 1
        }
        var groups: [[Int]] = [[last]]
        groups += foldBetween ? [Array(between.reversed())] : between.reversed().map { [$0] }
        groups.append([origin])
        groups += foldBefore ? [Array(before.reversed())] : before.reversed().map { [$0] }
        if origin > 0 { groups.append([0]) }

        // Stations the train it meets calls at on its way, where the two share a platform
        let station = { (stop: String) in StationDirectory.station(id: String(stop.dropLast()))?.id }
        let theirs = Set((connection.next?.approach ?? []).compactMap { station($0.id) })

        let rows = groups.enumerated().map { (index, group) -> Row in
            if group.count > 1 {
                let times = group.map { stops[$0].time.timeIntervalSince1970 }
                let middle = Date(timeIntervalSince1970: ((times.min() ?? 0) + (times.max() ?? 0)) / 2)
                return Row(id: index, name: "\(group.count) more stops", kind: .folded, time: middle, shared: false)
            }
            let stop = group[0]
            let kind: Kind = stop == last ? .change : stop == origin ? .origin : .stop
            let shared = stop == last || (station(stops[stop].id).map(theirs.contains) ?? false)
            return Row(id: index, name: stops[stop].name, kind: kind, time: stops[stop].time, shared: shared)
        }
        self.rows = rows
        firstRow = Self.row(at: now, in: rows)

        // The note as VoiceOver says it, naming a shuttle
        let spokenNote: String?
        if let next = connection.next {
            // Your train gets to the change at the top row's time; the train it
            // meets is where yours would be with as long to go
            let row = Self.row(at: connection.arrival.time.addingTimeInterval(-next.time.timeIntervalSince(now)), in: rows)
            let offMap = row > CGFloat(rows.count - 1)
            nextRow = row
            nextNote = offMap ? Self.note(for: next, line: next.lineLabel, now: now) : nil
            spokenNote = offMap ? Self.note(for: next, line: Lines.name(of: next.route), now: now) : nil
        } else {
            nextRow = nil
            nextNote = nil
            spokenNote = nil
        }
        spoken = Self.spokenText(connection: connection, rows: rows, firstRow: firstRow, nextNote: spokenNote)
    }

    /// Where your train is at `time`: between two stops by how far it has come
    /// from one to the next, or before the last while it's on its way there.
    private static func row(at time: Date, in rows: [Row]) -> CGFloat {
        guard let top = rows.first, time < top.time else { return 0 }
        for index in rows.indices.dropLast() where time >= rows[index + 1].time {
            let upper = rows[index].time
            let lower = rows[index + 1].time
            let span = upper.timeIntervalSince(lower)
            let fraction = span > 0 ? upper.timeIntervalSince(time) / span : 0
            return CGFloat(index) + CGFloat(min(1, max(0, fraction)))
        }
        return CGFloat(rows.count - 1) + 0.6
    }

    /// "D at 36 St", "D between 9 Av and 36 St"; the feed leaves out the stops
    /// a train has passed, so often just "D heading for 36 St". `line` is what
    /// it calls the train's line.
    private static func note(for train: Arrival, line: String, now: Date) -> String? {
        guard let place = train.place(now: now) else { return nil }
        switch place {
        case .starting:
            return train.approach.first.map { "\(line) starting at \($0.name)" }
        case .at(let index):
            return "\(line) at \(train.approach[index].name)"
        case .approaching(let index) where index > 0:
            return "\(line) between \(train.approach[index - 1].name) and \(train.approach[index].name)"
        case .approaching(let index):
            return "\(line) heading for \(train.approach[index].name)"
        }
    }

    /// See `spoken`. The train it meets is drawn where yours would be with as
    /// long to go, not where it is, so unless the note says where it is, it's
    /// by when it gets to the change.
    private static func spokenText(connection: Connection, rows: [Row], firstRow: CGFloat, nextNote: String?) -> String {
        var sentences = ["Your \(Lines.spokenName(of: connection.first.route)) is \(place(firstRow, in: rows))."]
        if let next = connection.next, !connection.staysOn {
            let line = Lines.name(of: next.route)
            if let nextNote {
                sentences.append("\(nextNote).")
            } else {
                let minutes = Int((next.time.timeIntervalSince(connection.arrival.time) / 60).rounded())
                let when = minutes < 1 ? "as yours does" : minutes == 1 ? "a minute after yours" : "\(minutes) minutes after yours"
                sentences.append("The \(line) gets to \(rows[0].name) \(when).")
            }
            let together = rows.dropFirst().filter(\.shared).map(\.name)
            if !together.isEmpty {
                sentences.append("The \(line) stops at \(Self.list(together)) too.")
            }
        }
        return sentences.joined(separator: " ")
    }

    /// "at 36 St", "between 25 St and Prospect Av", or past a folded row, where
    /// it's headed: "on its way to Union St".
    private static func place(_ row: CGFloat, in rows: [Row]) -> String {
        let last = rows.count - 1
        if row > CGFloat(last) { return "on its way to \(rows[last].name)" }
        let ahead = Int(row.rounded(.down))
        if row - CGFloat(ahead) < 0.01 && rows[ahead].kind != .folded { return "at \(rows[ahead].name)" }
        if ahead < last && rows[ahead].kind != .folded && rows[ahead + 1].kind != .folded {
            return "between \(rows[ahead + 1].name) and \(rows[ahead].name)"
        }
        // The change, the first row, is never folded
        let headed = rows[...ahead].last { $0.kind != .folded } ?? rows[0]
        return "on its way to \(headed.name)"
    }

    /// "36 St", "36 St and Pacific St", "36 St, 9 Av and Pacific St".
    private static func list(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

extension String {
    /// A station's name up to any second name: "Atlantic Av" for Atlantic
    /// Av-Barclays Ctr, "47-50 Sts" for 47-50 Sts-Rockefeller Ctr. A hyphen
    /// after a single word or number joins it to the next, so
    /// Hoyt-Schermerhorn Sts and 174-175 Sts stay whole.
    var mainStationName: String {
        var rest = self[...]
        while let hyphen = rest.firstIndex(of: "-") {
            if self[..<hyphen].contains(" ") { return String(self[..<hyphen]) }
            rest = self[index(after: hyphen)...]
        }
        return self
    }
}
