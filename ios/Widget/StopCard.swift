import SwiftUI
import WidgetKit

/// A stop's card, with no times: its station and way, then its lines (and for a change, → the
/// lines it changes to), drawn as Settings picks (`FavoriteCardStyle`). Next train and Transfers
/// show it on the Home Screen until a tap opens their board (`OpenBoards`), as Transit
/// Directions' Favorite Stop does. Fills the room it's given.
struct StopCard: View {
    let station: String
    /// "to Manhattan", or for a change "to 34 St-Herald Sq · change at Atlantic Av-Barclays Ctr".
    let heading: String
    let routes: [String]
    /// The lines changed to, after an →; none without a change.
    var onward: [String] = []
    let style: FavoriteCardStyle
    /// Whether a long heading wraps to two lines (bullet row) or shrinks (station sign) to fit;
    /// off, it's cut short, as Transit Directions' Favorite Stop card has it.
    var fitsHeading = true
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        switch style {
        case .bulletRow: bulletRowCard
        case .stationSign: stationSignCard
        }
    }

    /// Whether the card's drawn in colour; tinted and clear home screens get the plain card.
    private var fullColor: Bool { renderingMode == .fullColor }

    /// Tinted with the first line: the station and way, then the lines in a row along the
    /// bottom, overlapping, as big as the card's room lets (`roomyBullets`).
    private var bulletRowCard: some View {
        roomyBullets { size in
            VStack(alignment: .leading, spacing: 0) {
                Text(station)
                    .font(.headline)
                    .foregroundStyle(Color.boardText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(heading)
                    .font(.caption)
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(fitsHeading ? 2 : 1)
                Spacer(minLength: 4)
                bulletLine(upTo: size, spacing: { -$0 * 0.14 }, arrow: .boardGray) {
                    LineBullet(route: $0, size: $1)
                        // Ringed in the widget's background, to part the overlapping bullets
                        .overlay(Circle().stroke(Color.boardBackground, lineWidth: 2))
                }
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(fullColor
                  ? LineStyle.of(routes.first ?? "").swiftUIColor.opacity(0.14)
                  : Color.boardText.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Like a station's sign: a white rule along the top, the station in white on black, its
    /// lines in a row as big as there's room for, the way in capitals. Outlined, so it shows on a
    /// dark home screen.
    private var stationSignCard: some View {
        let ink = fullColor ? Color.white : Color.boardText
        return roomyBullets { size in
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(ink).frame(height: 2).padding(.top, 10)
                Spacer(minLength: 4)
                Text(station)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                bulletLine(upTo: size, spacing: { $0 * 0.1 }, arrow: ink.opacity(0.7)) {
                    LineBullet(route: $0, size: $1)
                }
                .padding(.top, 5)
                Spacer(minLength: 4)
                Text(heading.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(ink.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(fitsHeading ? 0.7 : 1)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(fullColor ? Color(white: 0.08) : Color.boardText.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.white.opacity(fullColor ? 0.14 : 0), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Sizes the card's bullets can be, biggest first: up to Transit Directions' Nearby and Trip
    /// circles.
    private static let bulletSizes: [CGFloat] = [52, 46, 40, 36, 32, 28, 24, 20, 17]

    /// The card's contents with its bullets as big as fit its height: the first of `bulletSizes`
    /// whose drawing isn't too tall (the station's name wrapping takes some). Smallest otherwise.
    private func roomyBullets<Content: View>(@ViewBuilder _ content: @escaping (CGFloat) -> Content) -> some View {
        ViewThatFits(in: .vertical) {
            ForEach(Self.bulletSizes, id: \.self) { content($0) }
        }
    }

    /// The lines in a row, then → and the lines changed to, as big as fit the card's width, up
    /// to `largest`: `bullet` draws each route at a size, `spacing` gives the gap between a
    /// group's bullets at a size.
    private func bulletLine<Bullet: View>(upTo largest: CGFloat, spacing: @escaping (CGFloat) -> CGFloat, arrow: Color,
                                          @ViewBuilder bullet: @escaping (String, CGFloat) -> Bullet) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.bulletSizes.filter { $0 <= largest }, id: \.self) { size in
                HStack(spacing: size * 0.1) {
                    HStack(spacing: spacing(size)) {
                        ForEach(routes, id: \.self) { bullet($0, size) }
                    }
                    if !onward.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.system(size: size * 0.45, weight: .bold))
                            .foregroundStyle(arrow)
                            .accessibilityLabel("then")
                        HStack(spacing: spacing(size)) {
                            ForEach(onward, id: \.self) { bullet($0, size) }
                        }
                    }
                }
            }
        }
    }
}

extension Selection {
    /// A stop's card's heading (`StopCard`): "to Manhattan", or "Northbound" where the MTA names
    /// neither way.
    var cardHeading: String {
        heading == direction.compassName ? heading : "to \(heading)"
    }
}

extension Station {
    /// The name on a stop's card (`StopCard`), which has room for two lines of it on the narrowest
    /// widget: shortened where the whole name needs more, keeping its street number.
    var cardName: String { Self.cardNames[name] ?? name }

    private static let cardNames = [
        "103 St-Corona Plaza": "103 St-Corona Plz",
        "110 St-Malcolm X Plaza": "110 St-Malcolm X",
        "116 St-Columbia University": "116 St-Columbia",
        "138 St-Grand Concourse": "138 St-Concourse",
        "15 St-Prospect Park": "15 St-Prospect Pk",
        "161 St-Yankee Stadium": "161 St-Yankee Stad",
        "163 St-Amsterdam Av": "163 St-Amsterdam",
        "168 St-Washington Hts": "168 St-Wash Hts",
        "21 St-Queensbridge": "21 St-Qnsbridge",
        "34 St-Hudson Yards": "34 St-Hudson Yds",
        "42 St-Port Authority Bus Terminal": "42 St-Port Authority",
        "47-50 Sts-Rockefeller Ctr": "47-50 Sts-Rock Ctr",
        "59 St-Columbus Circle": "59 St-Columbus",
        "66 St-Lincoln Center": "66 St-Lincoln Ctr",
        "68 St-Hunter College": "68 St-Hunter",
        "81 St-Museum of Natural History": "81 St-Museum",
        "Bedford Park Blvd-Lehman College": "Bedford Pk-Lehman",
        "Bedford-Nostrand Avs": "Bedford-Nostrand",
        "Brooklyn Bridge-City Hall": "Brooklyn Bridge",
        "Bushwick Av-Aberdeen St": "Bushwick-Aberdeen",
        "Canarsie-Rockaway Pkwy": "Canarsie",
        "Cathedral Pkwy (110 St)": "Cathedral Pkwy-110 St",
        "Clinton-Washington Avs": "Clinton-Washington",
        "Coney Island-Stillwell Av": "Coney Island",
        "Eastern Pkwy-Brooklyn Museum": "Brooklyn Museum",
        "Far Rockaway-Mott Av": "Far Rockaway",
        "Flatbush Av-Brooklyn College": "Flatbush Av",
        "Fort Hamilton Pkwy": "Ft Hamilton Pkwy",
        "Franklin Av-Medgar Evers College": "Franklin Av-Medgar",
        "Grand Central-42 St": "Grand Ctrl-42 St",
        "Howard Beach-JFK Airport": "Howard Beach",
        "Hoyt-Schermerhorn Sts": "Hoyt-Scherm.",
        "Jackson Hts-Roosevelt Av": "Jackson Hts",
        "Jamaica Center-Parsons/Archer": "Jamaica Center",
        "Kew Gardens-Union Tpke": "Kew Gardens",
        "Middle Village-Metropolitan Av": "Middle Village",
        "Myrtle-Willoughby Avs": "Myrtle-Willoughby",
        "President St-Medgar Evers College": "President St",
        "Rockaway Park-Beach 116 St": "Rockaway Pk-B 116 St",
        "Sutphin Blvd-Archer Av-JFK Airport": "Sutphin Blvd-JFK",
        "Van Cortlandt Park-242 St": "242 St-Van Cortlandt",
        "Vernon Blvd-Jackson Av": "Vernon Blvd",
        "West Farms Sq-E Tremont Av": "West Farms Sq",
        "Westchester Sq-E Tremont Av": "Westchester Sq",
        "Whitehall St-South Ferry": "Whitehall St",
    ]
}
