import Foundation

/// What Siri says when asked for the next train.
enum Spoken {
    /// e.g. "The next R to Manhattan at Prospect Av is in 4 minutes, at 8:12 AM. The one after is at 8:22 AM."
    /// `trains` are the ones you can still catch, soonest first; any of another
    /// line running on yours are named by their own: "… is at 8:22 AM, on the N."
    static func nextTrain(selection: Selection, trains: [Arrival], notice: String?, now: Date) -> String {
        let lines = either(selection.routes.map { LineStyle.of($0).label })
        let station = selection.station?.name ?? "your station"
        var sentence: String
        if let next = trains.first {
            let train = describe(line: next.lineLabel, selection: selection)
            var after = ""
            if trains.count > 1 {
                let second = trains[1]
                after = clock(second.time) + (second.route == next.route ? "" : ", on the \(second.lineLabel)")
            }
            if selection.walkMinutes > 0 {
                let leave = selection.leaveTime(for: next)
                let when = minutes(until: leave, from: now) == 0 ? "Leave now" : "Leave in \(duration(until: leave, from: now))"
                sentence = "\(when) for the \(clock(next.time)) \(train) at \(station)."
                if !after.isEmpty { sentence += " If you miss it, the next is at \(after)." }
            } else {
                let when = minutes(until: next.time, from: now) == 0 ? "arriving now" : "in \(duration(until: next.time, from: now)), at \(clock(next.time))"
                sentence = "The next \(train) at \(station) is \(when)."
                if !after.isEmpty { sentence += " The one after is at \(after)." }
            }
        } else {
            sentence = "There are no \(trainsPlural(line: lines, selection: selection)) predicted at \(station) right now."
        }
        if let notice {
            sentence += " Heads up: \(notice.lowercased())."
        }
        return sentence
    }

    /// "R", "N or R", "D, N or R".
    static func either(_ labels: [String]) -> String {
        guard let last = labels.last, labels.count > 1 else { return labels.first ?? "" }
        return labels.dropLast().joined(separator: ", ") + " or " + last
    }

    /// "R to Manhattan", or "northbound R" where the MTA gives the direction no name.
    static func describe(line: String, selection: Selection) -> String {
        let label = selection.station?.directionLabel(selection.direction) ?? ""
        return label.hasPrefix("to ") ? "\(line) \(label)" : "\(label.lowercased()) \(line)".trimmingCharacters(in: .whitespaces)
    }

    /// "R trains to Manhattan", or "northbound R trains".
    static func trainsPlural(line: String, selection: Selection) -> String {
        let label = selection.station?.directionLabel(selection.direction) ?? ""
        return label.hasPrefix("to ") ? "\(line) trains \(label)" : "\(label.lowercased()) \(line) trains".trimmingCharacters(in: .whitespaces)
    }

    static func minutes(until date: Date, from now: Date) -> Int {
        max(0, Int(date.timeIntervalSince(now) / 60))
    }

    static func duration(until date: Date, from now: Date) -> String {
        let count = minutes(until: date, from: now)
        return count == 1 ? "1 minute" : "\(count) minutes"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
