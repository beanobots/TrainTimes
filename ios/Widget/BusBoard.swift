import SwiftUI
import WidgetKit

/// A trip with a bus on Transit Directions (`SharedBusTrip`, from New Trip), as Next train and
/// Transfers draw a train: the bus's badge where a line's bullet goes, and how many stops away the
/// bus is under its countdown. A bus alone as medium Next train, with when it comes and the next
/// two; with a train before or after it, as medium Transfers, with the change.
struct BusBoardEntry {
    var trip: BusTrip
    /// The next buses where the bus is boarded, soonest first.
    var buses: [BusArrival]
    /// The train's next trains, soonest first, for a trip with one.
    var trains: [Arrival] = []
    /// Each train's time where it's ridden to, by `Arrival.trip`.
    var trainTimes: [String: Date] = [:]
    /// Why there are no times, when there aren't.
    var problem: String?
    /// For a bus shown both ways (Nearby's Both): the other way, and its next buses.
    var otherWay: BusRide? = nil
    var otherBuses: [BusArrival] = []

    /// How long Transit Directions draws ahead, and reloads after at most.
    static let ahead: TimeInterval = 20 * 60
    static let reload: TimeInterval = 5 * 60

    /// The trip's times now: the next buses (MTA Bus Time, through the push server) and any
    /// train's, fetched together.
    static func fetch(_ trip: BusTrip, otherWay: BusRide? = nil, now: Date) async -> BusBoardEntry {
        async let stopTimes = BusTimes.arrivals(line: trip.bus.line, at: trip.bus.from, now: now)
        async let otherTimes = otherWay.asyncMap { await BusTimes.arrivals(line: $0.line, at: $0.from, now: now) }
        var trains: [Arrival] = []
        var trainTimes: [String: Date] = [:]
        var trainFailed = false
        if let train = trip.train {
            do {
                let board = try await TrainService.board(for: train.selection, arrivingAt: train.endStation,
                                                         includingAlerts: false, includingOutages: false,
                                                         waitingAfterOwnLines: TimelinePlan.firstDrawWait, now: now)
                trains = train.selection.catchable(board.trains, now: now)
                trainTimes = board.destinationTimes
            } catch {
                trainFailed = true
            }
        }
        let buses = await stopTimes
        let other = await otherTimes
        let problem = buses == nil ? "Couldn't reach Bus Time" : trainFailed ? "Couldn't reach the MTA" : nil
        return BusBoardEntry(trip: trip, buses: buses?.arrivals ?? [], trains: trains, trainTimes: trainTimes,
                             problem: problem, otherWay: otherWay, otherBuses: other??.arrivals ?? [])
    }

    /// When the board changes after `now`, sorted: each time what it counts down to goes, and
    /// every minute for the minutes it shows ("then 12 min", the wait at the change), within `ahead`.
    func dates(from now: Date, until end: Date) -> [Date] {
        let leaving = (trip.busFirst ? buses.compactMap(\.time) : trains.map(\.leaves)) + otherBuses.compactMap(\.time)
        let last = min(end, now.addingTimeInterval(Self.ahead))
        let minutes = stride(from: now.addingTimeInterval(60), to: last, by: 60)
        return [now] + Set(leaving.filter { $0 > now && $0 < last } + minutes).sorted()
    }

    /// What it shows at `date`.
    func shown(at date: Date) -> Shown {
        var shown = Shown()
        let walk = trip.walk
        if trip.busFirst {
            let coming = buses.filter { ($0.time ?? .distantPast) > date }
            guard let bus = coming.first, let time = bus.time else { return shown }
            shown.countdown = (time, bus.isLive)
            shown.stopsAway = bus.stopsAway
            shown.later = coming.dropFirst().prefix(2).compactMap(\.time)
            if trip.train != nil {
                let reaches = time.addingTimeInterval(trip.bus.duration + walk)
                if let train = trains.first(where: { $0.leaves >= reaches }) {
                    shown.change = (train.leaves.timeIntervalSince(reaches), trainTimes[train.trip])
                }
            }
        } else {
            let coming = trains.filter { $0.leaves > date }
            guard let train = coming.first else { return shown }
            shown.countdown = (train.leaves, train.isLive)
            shown.later = coming.dropFirst().prefix(2).map(\.leaves)
            if let there = trainTimes[train.trip] {
                let reaches = there.addingTimeInterval(walk)
                if let bus = buses.first(where: { ($0.time ?? .distantPast) >= reaches }), let time = bus.time {
                    shown.change = (time.timeIntervalSince(reaches), time.addingTimeInterval(trip.bus.duration))
                }
            }
        }
        return shown
    }

    /// The board at a moment: the countdown, and what comes after it.
    struct Shown {
        /// To the bus or train counted down to, and whether it's a prediction.
        var countdown: (time: Date, isLive: Bool)?
        /// How many stops away the bus counted down to is.
        var stopsAway: Int?
        /// The next ones' times after it.
        var later: [Date] = []
        /// With a train before or after the bus: the wait at the change, and when it gets there.
        var change: (wait: TimeInterval, arrives: Date?)?
    }
}

/// `BusBoardEntry` drawn as the round-3 mockups had it: Next train's or Transfers' medium board.
struct BusBoardView: View {
    let entry: BusBoardEntry
    let date: Date
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var trip: BusTrip { entry.trip }
    private var shown: BusBoardEntry.Shown { entry.shown(at: date) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // A tap anywhere refreshes: the intent's reload fetches again
            Button(intent: RefreshWidgetsIntent()) {
                board.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Refreshes the times")
            EndTripButton(large: true)
        }
        .padding(16)
    }

    @ViewBuilder private var board: some View {
        if let other = entry.otherWay {
            bothWays(other)
        } else {
            oneWay
        }
    }

    /// Both ways, as Next train shows a train both ways: a box for each, where it's going, its
    /// countdown, and how far the bus is and the next one's minutes.
    private func bothWays(_ other: BusRide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BusBadge(line: trip.bus.line, size: 24)
                Text(trip.bus.from.name)
                    .font(.body.bold())
                    .foregroundStyle(Color.boardText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Pill(symbol: "xmark", large: true, round: true).hidden()
            }
            HStack(spacing: 6) {
                wayBox(trip.bus, buses: entry.buses)
                wayBox(other, buses: entry.otherBuses)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func wayBox(_ ride: BusRide, buses: [BusArrival]) -> some View {
        let coming = buses.filter { ($0.time ?? .distantPast) > date }
        return VStack(alignment: .leading, spacing: 0) {
            Text(ride.headsign ?? ride.from.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.boardGray)
            if let bus = coming.first, let time = bus.time {
                timer(time, isLive: bus.isLive, size: 38)
                HStack(spacing: 4) {
                    BusBadge(line: ride.line, size: 14)
                    let stops = bus.stopsAway.map { $0 == 1 ? "1 stop" : "\($0) stops" }
                    let then = coming.dropFirst().first?.time.map { "then \(MinutesToGo(until: $0, from: date).label)" }
                    Text([stops, then].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.boardText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text(entry.problem ?? "None predicted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardText)
                    .padding(.top, 4)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }

    private var oneWay: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let countdown = shown.countdown {
                BoardBox {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            timer(countdown.time, isLive: countdown.isLive)
                            if let stops = shown.stopsAway {
                                Text(stops == 1 ? "1 stop away" : "\(stops) stops away")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.boardGray)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if trip.train == nil {
                            leaves(countdown.time)
                        } else {
                            change
                        }
                    }
                }
            } else {
                BoardBox {
                    Text(entry.problem ?? (trip.busFirst ? "No \(BusBadge.label(trip.bus.line)) buses predicted"
                                           : "No trains predicted"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.boardText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The first ride's badge or bullets; "5 Av/9 St Bay Ridge" for a bus alone, else where from
    /// and to. Room on the right for ✕.
    private var header: some View {
        HStack(spacing: 8) {
            if trip.busFirst {
                BusBadge(line: trip.bus.line, size: 24)
            } else if let train = trip.train {
                LineBullets(routes: train.selection.routes, size: 24)
            }
            Group {
                if trip.train == nil {
                    Text("\(trip.bus.from.name) \(Text(trip.bus.headsign ?? "").font(.footnote).foregroundStyle(Color.boardGray))")
                } else {
                    Text("\(trip.startName) \(Text("→").foregroundStyle(Color.boardGray)) \(trip.endName)")
                }
            }
            .font(.body.bold())
            .foregroundStyle(Color.boardText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Pill(symbol: "xmark", large: true, round: true).hidden()
        }
    }

    /// The countdown, as the boards draw it.
    private func timer(_ time: Date, isLive: Bool, size: CGFloat = 48) -> some View {
        BoardCountdown(start: date, end: time, isLive: isLive,
                       marks: SharedStore.loadSettings().timeMarks(withoutColor: withoutColor, renderingMode: renderingMode),
                       size: size)
    }

    /// For a bus alone, as `LeavesColumn`: its badge and when it comes, then the next two.
    private func leaves(_ time: Date) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                BusBadge(line: trip.bus.line, size: 18)
                Text("leaves \(time.clock)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardText)
            }
            if !shown.later.isEmpty {
                Text("then " + shown.later.map { MinutesToGo(until: $0, from: date).label }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(Color.boardGray)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// As Transfers' soonest way: "Change at", the line and where, then the wait and the walk.
    private var change: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("Change at")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.boardGray)
            HStack(spacing: 6) {
                if trip.busFirst, let train = trip.train {
                    LineBullets(routes: train.selection.routes, size: 26)
                    Text((train.selection.station?.name ?? "").mainStationName.replacingOccurrences(of: " Av", with: ""))
                } else {
                    BusBadge(line: trip.bus.line, size: 26)
                    Text(trip.bus.from.name)
                }
            }
            .font(.title2.weight(.semibold))
            .foregroundStyle(Color.boardText)
            let walk = "\(max(1, Int((trip.walk / 60).rounded()))) min walk"
            Text(shown.change.map { "\(MinutesToGo(until: date.addingTimeInterval($0.wait), from: date).label) · \(walk)" }
                 ?? (trip.busFirst ? "No train predicted" : "No bus predicted"))
                .font(.footnote)
                .foregroundStyle(Color.boardGray)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - Previews

private extension BusBoardEntry {
    static var preview: BusBoardEntry {
        let now = Date.now
        let bus = BusRide(line: "B63", from: .init(name: "5 Av/9 St", latitude: 40.6697, longitude: -73.9877),
                          to: .init(name: "Atlantic Av", latitude: 40.6838, longitude: -73.9786),
                          headsign: "Pier 6", stops: 9, seconds: 720)
        let buses = [240.0, 960, 1740].enumerated().map { index, seconds in
            BusArrival(line: "B63", destination: "Pier 6", expected: now.addingTimeInterval(seconds),
                       stopsAway: [3, 9, 16][index])
        }
        return BusBoardEntry(trip: BusTrip(bus: bus, train: nil, busFirst: true), buses: buses)
    }

    static var bothWays: BusBoardEntry {
        var entry = preview
        let now = Date.now
        entry.otherWay = BusRide(line: "B63", from: .init(name: "5 Av & 9 St", latitude: 40.6699, longitude: -73.9874),
                                 to: .init(name: "5 Av & 9 St", latitude: 40.6699, longitude: -73.9874), headsign: "Bay Ridge")
        entry.otherBuses = [BusArrival(line: "B63", destination: "Bay Ridge", expected: now.addingTimeInterval(500), stopsAway: 5),
                            BusArrival(line: "B63", destination: "Bay Ridge", expected: now.addingTimeInterval(1300), stopsAway: 12)]
        return entry
    }

    static var busThenTrain: BusBoardEntry {
        var entry = preview
        let atlantic = StationDirectory.all.first { $0.name.hasPrefix("Atlantic Av") && $0.routes.contains("D") }
        let herald = StationDirectory.all.first { $0.name == "34 St-Herald Sq" }
        entry.trip.train = SharedTrip.Option(selection: Selection(stationID: atlantic?.id ?? "R31", routes: ["D"], direction: .north),
                                             destinationID: herald?.id)
        let now = Date.now
        entry.trains = [1260.0, 1680].map {
            Arrival(route: "D", time: now.addingTimeInterval($0), stop: "R31N", lastStop: "D01N", isLive: true, trip: "D\($0)")
        }
        entry.trainTimes = ["D1260.0": now.addingTimeInterval(2100)]
        return entry
    }
}

#Preview("Bus alone", as: .systemMedium) {
    DirectionsWidget()
} timeline: {
    DirectionsEntry(date: .now, busBoard: .preview)
}

#Preview("Both ways", as: .systemMedium) {
    DirectionsWidget()
} timeline: {
    DirectionsEntry(date: .now, busBoard: .bothWays)
}

#Preview("Bus then train", as: .systemMedium) {
    DirectionsWidget()
} timeline: {
    DirectionsEntry(date: .now, busBoard: .busThenTrain)
}

private extension Optional {
    /// `transform` of the value, awaited; nil for none.
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

#Preview("Nearby bus places, a stop's lines, a line's ways", as: .systemMedium) {
    DirectionsWidget()
} timeline: {
    let places = NearbyBuses.preview()
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby, nearbyBuses: true),
                    nearby: .noneClose, buses: .places(places))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearbyBus, nearbyBusPlace: places[1]))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearbyBus, nearbyBusPlace: places[0],
                                                     nearbyBus: places[0].lines(at: .now).first))
}
