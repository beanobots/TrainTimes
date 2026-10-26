import AppIntents
import CoreLocation
import SwiftUI
import WidgetKit

/// Nearby's buses, with its "Bus" switch on: the bus places near you (a stop and the one across
/// from it) and their next buses, from the push server's `GET /buses/nearby` (server/README.md),
/// which keeps Bus Time's key. Drawn in Nearby's grid as stations are.
enum NearbyBuses {
    /// One stop, as the server sends it, with its next buses, every line.
    struct Way: Codable, Hashable, Sendable {
        /// Its name as Bus Time writes it: "7 AV/9 ST".
        var stop: BusStopTimes.Stop
        /// From where you were.
        var meters: Double
        var arrivals: [BusArrival]
    }

    /// The bus places near `location`, nearest first: none with no stop within a quarter mile;
    /// nil if the server can't be reached or has no Bus Time key. From a server that predates
    /// places, its one place's ways.
    static func places(near location: CLLocation) async -> [NearbyBusPlace]? {
        guard let baseURL = ServerRoutes.baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent("buses/nearby"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "at", value: String(format: "%.5f,%.5f", location.coordinate.latitude,
                                                                          location.coordinate.longitude))]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: wait)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Response: Decodable { var ways: [Way]; var places: [[Way]]? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return (decoded.places ?? [decoded.ways]).filter { !$0.isEmpty }.map(place)
    }

    /// The server's stops as a place.
    static func place(_ ways: [Way]) -> NearbyBusPlace {
        NearbyBusPlace(ways: ways.map { NearbyBusPick.Way(stop: $0.stop, destination: nil, arrivals: $0.arrivals) },
                       meters: ways.map(\.meters).min() ?? 0)
    }

    /// How long Nearby waits for its buses before drawing without them.
    static let wait: TimeInterval = 3
}

extension NearbyBuses {
    /// For previews: the B63 both ways on 5 Av, and the B67 and B69 on 7 Av.
    static func preview(now: Date = .now) -> [NearbyBusPlace] {
        let stop = { (id: String, name: String, direction: String) in
            BusStopTimes.Stop(id: id, name: name, latitude: 40.6661, longitude: -73.9802, direction: direction)
        }
        return [
            place([
                Way(stop: stop("308209", "5 AV/9 ST", "NE"), meters: 110, arrivals: [
                    BusArrival(line: "B63", destination: "PIER 6 BKLYN BRIDGE PK", expected: now + 240, stopsAway: 3),
                ]),
                Way(stop: stop("308210", "5 AV/9 ST", "SW"), meters: 140, arrivals: [
                    BusArrival(line: "B63", destination: "BAY RIDGE SHORE RD", expected: now + 500, stopsAway: 5),
                ]),
            ]),
            place([
                Way(stop: stop("303245", "7 AV/9 ST", "N"), meters: 480, arrivals: [
                    BusArrival(line: "B67", destination: "DOWNTOWN BKLYN", expected: now + 220, stopsAway: 2),
                    BusArrival(line: "B69", destination: "DOWNTOWN BKLYN", expected: now + 610, stopsAway: 6),
                ]),
                Way(stop: stop("303280", "7 AV/10 ST", "S"), meters: 530, arrivals: [
                    BusArrival(line: "B67", destination: "KENSINGTON CHURCH AV", expected: now + 495, stopsAway: 5),
                    BusArrival(line: "B69", destination: "KENSINGTON CHURCH AV", expected: now + 900, stopsAway: 9),
                ]),
            ]),
        ]
    }
}

/// Nearby's buses, as found on its reload.
enum NearbyBusList: Hashable {
    /// Nearest first; none with no stop within a quarter mile.
    case places([NearbyBusPlace])
    /// The server couldn't say.
    case unavailable
    /// On Nearby's face, drawn at once on a tap, before they're fetched.
    case finding

    var places: [NearbyBusPlace] {
        if case .places(let places) = self { return places }
        return []
    }
}

/// "🚶 4 min", as Nearby's cards and headers have it.
struct WalkTime: View {
    let minutes: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "figure.walk")
            Text("\(minutes) min")
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(Color.boardGray)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(minutes) minute walk")
    }
}

/// Its views in rows, left to right, on to the next row when one's full; the first row
/// `firstLineInset` short at its right, for what's drawn there (a card's walk).
struct FlowRow: Layout {
    var spacing: CGFloat
    var firstLineInset: CGFloat = 0

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let room = width - (rows.count == 1 ? firstLineInset : 0)
            if !rows[rows.count - 1].isEmpty, x + size.width > room {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(index)
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing }
        let heights = rows(sizes, width: width).map { $0.map { sizes[$0].height }.max() ?? 0 }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in rows(sizes, width: bounds.width) {
            var x = bounds.minX
            for index in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += sizes[index].width + spacing
            }
            y += (row.map { sizes[$0].height }.max() ?? 0) + spacing
        }
    }
}

/// One line on a station's or bus place's lines screen: its bullet or badge, and where it goes
/// each way.
struct NearbyLineCard<Mark: View>: View {
    let ends: [String]
    /// Four or fewer lines: tall cards with their ends; more, tiles with just their marks.
    let tall: Bool
    @ViewBuilder let mark: Mark

    var body: some View {
        VStack(spacing: 6) {
            mark
            if tall, !ends.isEmpty {
                VStack(spacing: 0) {
                    ForEach(ends.prefix(2), id: \.self) { Text($0) }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: tall ? 16 : 14).fill(Color.boardText.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Lines laid out to fill the room: up to four in a row of tall cards, more in two rows of tiles.
struct NearbyLineGrid<Item: Hashable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item, _ tall: Bool) -> Card

    var body: some View {
        if items.count <= 4 {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { card($0, true) }
            }
        } else {
            let perRow = (items.count + 1) / 2
            let rows = stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        ForEach(rows[index], id: \.self) { card($0, false) }
                        // A short last row keeps its tiles the others' width
                        ForEach(rows[index].count..<perRow, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
}

/// A bus place picked from Nearby: its lines, as a station's are, or once one's picked (or
/// for a place with one line), a card for each way it goes, then Both, as a station's line's
/// ways are. ‹ back to its lines, or Nearby.
struct NearbyBusScreen: View {
    let place: NearbyBusPlace
    /// The line picked; nil for the place's lines.
    let pick: NearbyBusPick?
    let date: Date
    var still = false

    var body: some View {
        let lines = place.lines(at: date)
        VStack(alignment: .leading, spacing: 6) {
            header(line: pick?.line, back: pick != nil && lines.count > 1)
            if let pick {
                ways(pick)
            } else {
                NearbyLineGrid(items: lines) { line, tall in
                    button(PickNearbyBusIntent(line)) {
                        NearbyLineCard(ends: line.ways.map(\.name), tall: tall) {
                            BusBadge(line: line.line, size: tall ? (lines.count > 3 ? 30 : 36) : 26)
                        }
                    }
                    .accessibilityLabel(BusBadge.spokenName(line.line))
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// ‹ (to the place's lines with `back`, else Nearby), the line's badge if picked, the place's
    /// name and walk; ✕.
    private func header(line: String?, back: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if back {
                    button(PickNearbyBusPlaceIntent(place)) { title(line: line) }
                } else {
                    button(ShowQuickTripScreenIntent(.nearby)) { title(line: line) }
                }
            }
            .accessibilityLabel(back ? "Back to \(place.name)'s buses" : "Back to the stations near you")
            Spacer()
            button(ShowQuickTripScreenIntent(.home)) {
                Pill(symbol: "xmark", large: true, round: true)
            }
            .accessibilityLabel("Back to Favorite Stop, Nearby and Trip")
        }
    }

    private func title(line: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "chevron.left")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.boardGray)
                .padding(.top, 3)
            if let line {
                BusBadge(line: line, size: 20)
            }
            Text(place.name)
                .font(.subheadline.bold())
                .foregroundStyle(Color.boardText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 1)
            WalkTime(minutes: place.walkMinutes)
                .padding(.top, 3)
        }
        .contentShape(Rectangle())
    }

    /// A card for each way, where it's going and its stop; Both with two. No times: those come
    /// with the board, once one's picked.
    private func ways(_ pick: NearbyBusPick) -> some View {
        HStack(spacing: 8) {
            ForEach(pick.ways.indices, id: \.self) { index in
                let way = pick.ways[index]
                button(ShowNearbyBusIntent(pick, way: index)) {
                    VStack(spacing: 2) {
                        Text(way.name)
                            .font(.title2.bold())
                            .foregroundStyle(Color.boardText)
                            .lineLimit(way.name.contains(" ") ? 2 : 1)
                            .minimumScaleFactor(0.6)
                        Text(BusStopTimes.readable(way.stop.name))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.boardGray)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .accessibilityLabel("\(BusBadge.spokenName(pick.line)), to \(way.name)")
            }
            if pick.ways.count == 2 {
                button(ShowNearbyBusIntent(pick, way: 0, both: true)) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.body.bold())
                        Text("Both")
                            .font(.caption.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Color.boardText)
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .accessibilityLabel("\(BusBadge.spokenName(pick.line)), both directions")
            }
        }
    }

    /// A button, or on a toggle's face just its label.
    @ViewBuilder private func button<Intent: AppIntent, Label: View>(_ intent: Intent,
                                                                    @ViewBuilder label: () -> Label) -> some View {
        if still {
            label()
        } else {
            Button(intent: intent, label: label)
        }
    }
}

/// Nearby's "Bus" switch: "+ Bus", or lit "✓ Bus" with buses on. A toggle, so it flips at once
/// on a tap, before its redraw brings the buses or takes them away; just its face when `still`.
struct NearbyBusSwitch: View {
    let on: Bool
    var still = false

    var body: some View {
        if still {
            face(on)
        } else {
            Toggle(isOn: on, intent: IncludeNearbyBusesIntent(!on)) {
                Text("Bus")
            }
            .toggleStyle(SwapToggleStyle { isOn in face(isOn.wrappedValue) })
            .accessibilityLabel("Include buses")
            .accessibilityValue(on ? "On" : "Off")
        }
    }

    private func face(_ on: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: on ? "checkmark" : "plus")
            Text("Bus")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(on ? Color.white : Color.boardGray)
        .padding(.horizontal, 11)
        .frame(height: BoardStyle.large.buttonHeight)
        .background(Capsule().fill(on ? HomeTint.nearby : Color.boardButton))
        .widgetAccentable(on)
        .contentShape(Capsule())
    }
}
