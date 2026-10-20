import Foundation

/// What Siri says when asked for the next train.
enum Spoken {
    /// e.g. "The next R to Manhattan at Prospect Av is in 4 minutes, at 8:12 AM. The one after is at 8:22 AM."
    /// `trains` are the ones you can still catch, soonest first; any of another
    /// line running on yours are named by their own: "… is at 8:22 AM, on the N."
    /// `unreachable` says whether others still to come are left out of them,
    /// as you can't reach them in time.
    static func nextTrain(selection: Selection, trains: [Arrival], unreachable: Bool = false, notice: Notice?,
                          now: Date) -> String {
        let lines = Lines.list(selection.routes, joinedBy: "or")
        let station = selection.station?.name ?? "your station"
        var sentence: String
        if let next = trains.first {
            let train = describe(line: Lines.name(of: next.route), heading: selection.heading(of: next))
            var after = ""
            if trains.count > 1 {
                let second = trains[1]
                after = clock(second.time) + (second.route == next.route ? "" : ", on the \(Lines.name(of: second.route))")
            }
            if selection.walkMinutes > 0 {
                let leave = MinutesToGo(until: selection.leaveTime(for: next), from: now)
                let when = leave.isNow ? "Leave now" : "Leave in \(leave.spoken)"
                sentence = "\(when) for the \(clock(next.time)) \(train) at \(station)."
                if !after.isEmpty { sentence += " If you miss it, the next is at \(after)." }
            } else {
                let due = MinutesToGo(until: next.time, from: now)
                let when = due.isNow ? "arriving now" : "in \(due.spoken), at \(clock(next.time))"
                sentence = "The next \(train) at \(station) is \(when)."
                if !after.isEmpty { sentence += " The one after is at \(after)." }
            }
        } else if unreachable {
            sentence = "There are \(trainsPlural(line: lines, heading: selection.heading)) predicted at \(station), but none you can reach in time."
        } else {
            sentence = "There are no \(trainsPlural(line: lines, heading: selection.heading)) predicted at \(station) right now."
        }
        if let notice {
            sentence += " Heads up: \(headsUp(notice))"
        }
        return sentence
    }

    /// An alert's headline, "R trains are running with delays in both
    /// directions.", or what's out: "elevator out."
    static func headsUp(_ notice: Notice) -> String {
        let text: String
        switch notice.kind {
        case .elevator:
            // Only its first letter, so line letters and names inside it keep their capitals
            text = notice.label.prefix(1).lowercased() + notice.label.dropFirst()
        case .alert(let kind):
            let headline = notice.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !headline.isEmpty {
                text = headline
            } else {
                switch kind {
                case .delays: text = "there are delays"
                case .suspended: text = "service is suspended"
                case .serviceChange: text = "there's a service change"
                case .notice: text = "there's a notice from the MTA"
                }
            }
        }
        if let last = text.last, ".!?".contains(last) { return text }
        return text + "."
    }

    /// "R to Manhattan", or "northbound R" where the MTA gives the direction no name.
    static func describe(line: String, heading: String) -> String {
        isNamed(heading) ? "\(line) to \(heading)" : "\(heading.lowercased()) \(line)".trimmingCharacters(in: .whitespaces)
    }

    /// "R trains to Manhattan", or "northbound R trains".
    static func trainsPlural(line: String, heading: String) -> String {
        isNamed(heading) ? "\(line) trains to \(heading)" : "\(heading.lowercased()) \(line) trains".trimmingCharacters(in: .whitespaces)
    }

    /// Whether `heading` is a place, "Manhattan", rather than the
    /// "Northbound" or "Southbound" given where the MTA names none.
    private static func isNamed(_ heading: String) -> Bool {
        !heading.isEmpty && heading != "Northbound" && heading != "Southbound"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
