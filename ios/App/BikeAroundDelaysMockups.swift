import MapKit
import SwiftUI

// Throwaway mockups: "Trains Fucked Mode". The R at 4 Av-9 St is delayed 19 min, so Citi Bike up
// 4 Av to Atlantic Av-Barclays Ctr and take the Q to Times Sq-42 St instead. Off by default; the
// delay banner turns it on. Delete once built.

private enum Mock {
    static let start = CLLocationCoordinate2D(latitude: 40.6712, longitude: -73.9880)
    static let ninthSt = CLLocationCoordinate2D(latitude: 40.6705, longitude: -73.9887)
    static let unionSt = CLLocationCoordinate2D(latitude: 40.6773, longitude: -73.9831)
    static let atlantic = CLLocationCoordinate2D(latitude: 40.6840, longitude: -73.9781)
    static let dekalb = CLLocationCoordinate2D(latitude: 40.6905, longitude: -73.9819)
    static let jaySt = CLLocationCoordinate2D(latitude: 40.6923, longitude: -73.9873)
    static let timesSq = CLLocationCoordinate2D(latitude: 40.7553, longitude: -73.9871)
    static let end = CLLocationCoordinate2D(latitude: 40.7570, longitude: -73.9855)

    /// Up 4 Av to the dock at Atlantic Av.
    static let bike = [start, unionSt, atlantic]
    /// Along Flatbush Av Ext to Jay St.
    static let bikeToJay = [start, unionSt, CLLocationCoordinate2D(latitude: 40.6860, longitude: -73.9800),
                            CLLocationCoordinate2D(latitude: 40.6900, longitude: -73.9850), jaySt]
    static let q = [atlantic, dekalb, CLLocationCoordinate2D(latitude: 40.7075, longitude: -73.9925),
                    CLLocationCoordinate2D(latitude: 40.7186, longitude: -74.0001),
                    CLLocationCoordinate2D(latitude: 40.7356, longitude: -73.9906),
                    CLLocationCoordinate2D(latitude: 40.7497, longitude: -73.9878), timesSq]
    static let a = [jaySt, CLLocationCoordinate2D(latitude: 40.7100, longitude: -74.0070),
                    CLLocationCoordinate2D(latitude: 40.7208, longitude: -74.0052),
                    CLLocationCoordinate2D(latitude: 40.7330, longitude: -74.0003),
                    CLLocationCoordinate2D(latitude: 40.7525, longitude: -73.9934),
                    CLLocationCoordinate2D(latitude: 40.7573, longitude: -73.9897)]
    /// The R through the Montague tunnel, as it would have gone.
    static let r = [ninthSt, unionSt, atlantic, dekalb, CLLocationCoordinate2D(latitude: 40.6941, longitude: -73.9918),
                    CLLocationCoordinate2D(latitude: 40.7031, longitude: -74.0129),
                    CLLocationCoordinate2D(latitude: 40.7132, longitude: -74.0070),
                    CLLocationCoordinate2D(latitude: 40.7196, longitude: -74.0018),
                    CLLocationCoordinate2D(latitude: 40.7356, longitude: -73.9906),
                    CLLocationCoordinate2D(latitude: 40.7497, longitude: -73.9878), timesSq]

    static func color(_ route: String) -> Color { Color(hex: LineStyle.of(route).color) }

    /// Citi Bike's blue.
    static let citiBike = Color(red: 0.0, green: 0.42, blue: 0.80)

    static let picked = Color(UIColor { traits in
        UIColor.tintColor.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.28 : 0.08)
    })
    static let casing = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.6) : .white
    })
}

/// A round bike bullet, to sit beside line bullets.
private struct BikeBullet: View {
    let size: CGFloat
    /// An e-bike: a bolt badge at the top right.
    var electric = false

    var body: some View {
        Image(systemName: "bicycle")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Mock.citiBike))
            .overlay(alignment: .topTrailing) {
                if electric {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.32, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: size * 0.5, height: size * 0.5)
                        .background(Circle().fill(.yellow))
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 1.5))
                        .offset(x: size * 0.15, y: -size * 0.15)
                }
            }
    }
}

/// The map, drawn, as map tiles don't load in previews.
private struct MockMap: View {
    /// The bike trips' kind when the mode's on; nil draws just the delayed R.
    var bike: BikeKind?

    private static let land = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1) })
    private static let street = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 0, alpha: 0.05) })

    var body: some View {
        GeometryReader { geometry in
            drawing(in: geometry.size)
        }
    }

    @ViewBuilder private func drawing(in size: CGSize) -> some View {
        let point = { (c: CLLocationCoordinate2D) in project(c.latitude, c.longitude, in: size) }
        let path = { (line: [CLLocationCoordinate2D]) in Path { $0.addLines(line.map(point)) } }
        let solid = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        ZStack {
            Self.land
            Path { p in
                for i in stride(from: -40.0, through: 80, by: 1) {
                    p.move(to: CGPoint(x: i * 22, y: -200))
                    p.addLine(to: CGPoint(x: i * 22 + 700, y: size.height + 200))
                    p.move(to: CGPoint(x: -200, y: i * 22))
                    p.addLine(to: CGPoint(x: size.width + 200, y: i * 22 - 350))
                }
            }
            .stroke(Self.street, lineWidth: 1.5)
            if let bike {
                // How far 10 min on a bike, or an e-bike, gets you
                let reach = CLLocationCoordinate2D(latitude: bike == .eBike ? 40.7000 : 40.6935, longitude: 0)
                let radius = abs(point(Mock.start).y - point(reach).y)
                Circle()
                    .fill(Mock.citiBike.opacity(0.08))
                    .stroke(Mock.citiBike.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(point(Mock.start))
                // The delayed R, greyed out
                path(Mock.r).stroke(Color.gray.opacity(0.45), style: StrokeStyle(lineWidth: 5, lineCap: .round,
                                                                                 lineJoin: .round, dash: [2, 6]))
                path(Mock.a).stroke(Mock.casing, style: solid(7))
                path(Mock.a).stroke(Mock.color("A").opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round,
                                                                                     lineJoin: .round, dash: [7, 5]))
                path(Mock.bikeToJay).stroke(Mock.citiBike.opacity(0.6),
                                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [7, 5]))
                path(Mock.q).stroke(Mock.casing, style: solid(11))
                path(Mock.q).stroke(Mock.color("Q"), style: solid(7))
                path(Mock.bike).stroke(Mock.casing, style: solid(11))
                path(Mock.bike).stroke(Mock.citiBike, style: solid(7))
                dock.position(point(Mock.start)).offset(x: 18, y: 4)
                dock.position(point(Mock.atlantic)).offset(x: 16)
                changeDot.position(point(Mock.atlantic))
                bullet("A").scaleEffect(0.8).position(point(Mock.jaySt)).offset(x: -16)
                bullet("Q").position(point(CLLocationCoordinate2D(latitude: 40.7270, longitude: -73.9960)))
            } else {
                // The R as picked: no bikes until you ask for them
                path(Mock.r).stroke(Mock.casing, style: solid(11))
                path(Mock.r).stroke(Mock.color("R"), style: solid(7))
                bullet("R").position(point(CLLocationCoordinate2D(latitude: 40.7270, longitude: -73.9965)))
            }
            Label("Delayed 19 min", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .fixedSize()
                .position(point(CLLocationCoordinate2D(latitude: 40.7040, longitude: -74.0129))).offset(x: 30)
            Circle().fill(.blue).frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 2)
                .position(point(Mock.start))
            Image(systemName: "mappin.circle.fill")
                .font(.title).foregroundStyle(.white, .red).shadow(radius: 2)
                .position(point(Mock.end)).offset(y: -14)
        }
    }

    /// Lat 40.757 at 16% down, 40.671 at 45%, the same scale across at this latitude.
    private func project(_ lat: Double, _ lon: Double, in size: CGSize) -> CGPoint {
        let perPoint = (40.757 - 40.671) / (size.height * 0.29)
        let y = size.height * 0.16 + (40.757 - lat) / perPoint
        let x = size.width / 2 + (lon + 73.995) / (perPoint / 0.758)
        return CGPoint(x: x, y: y)
    }

    private func bullet(_ route: String) -> some View {
        LineBullet(route: route, size: 20).overlay(Circle().stroke(.white, lineWidth: 2)).shadow(radius: 1)
    }

    private var dock: some View {
        Image(systemName: "bicycle")
            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(Mock.citiBike))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white, lineWidth: 1.5))
    }

    private var changeDot: some View {
        Circle().fill(.white).frame(width: 9, height: 9)
            .overlay(Circle().stroke(.black.opacity(0.8), lineWidth: 2))
    }
}

/// The From and To window at the map's top left, as New Trip has it.
private struct MockWindow: View {
    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 3) {
                Image(systemName: "location.fill").font(.caption2).foregroundStyle(.tint)
                Capsule().fill(.tertiary).frame(width: 2, height: 10)
                Circle().fill(.red).frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Current Location")
                Text("Times Sq-42 St")
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// One trip row, laid out as `TripOptionRow`; `bike` puts a bike bullet before the lines.
private struct MockRow<Detail: View>: View {
    var bike = false
    var electric = false
    let routes: [String]
    let title: String
    let minutes: Int
    var picked = false
    var dimmed = false
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if bike {
                    HStack(spacing: 2) {
                        BikeBullet(size: 19, electric: electric)
                        LineBullet(route: routes[0], size: 19)
                    }
                } else {
                    LineBullets(routes: routes, size: 24)
                }
            }
            .frame(width: 52)
            .grayscale(dimmed ? 1 : 0).opacity(dimmed ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                detail.font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("\(minutes) min").font(.subheadline.weight(.semibold))
                .foregroundStyle(dimmed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(picked ? Mock.picked : .clear)
    }
}

/// A row's second line: an icon, bullets and how.
private func legLine(_ icon: String, _ text: String, tint: Color? = nil) -> some View {
    legLine(icon, [], text, tint: tint)
}

private func legLine(_ icon: String, _ routes: [String], _ text: String, tint: Color? = nil) -> some View {
    HStack(spacing: 4) {
        Image(systemName: icon).foregroundStyle(tint ?? .secondary)
        HStack(spacing: 2) {
            ForEach(routes, id: \.self) { LineBullet(route: $0, size: 14) }
        }
        Text(text)
    }
    .lineLimit(1)
}

/// A bike trip under the picked one.
private struct OtherTrip {
    let route: String
    let lines: [String]
    let title: String
    let minutes: Int
    let how: String
}

private enum BikeKind: String, CaseIterable {
    case bike = "Bike"
    case eBike = "E-Bike"
}

/// New Trip with the mode: off by default, trips as usual. When the trip's lines are badly
/// delayed and a bike to another line beats them, a banner offers it; its button, or the bike
/// switch on the map, turns the mode on, and every trip becomes a ride to whichever line's fastest.
private struct TripsMock: View {
    @State var bike: BikeKind?

    var body: some View {
        ZStack(alignment: .top) {
            MockMap(bike: bike).ignoresSafeArea()
                .background(Color(.systemBackground))
            HStack(alignment: .top) {
                MockWindow()
                Spacer()
                modeSwitch
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let bike {
                        bikeTrips(bike)
                    } else {
                        trainTrips
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 2)
                .padding(.horizontal, 16)
                HStack(spacing: 12) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.title2).foregroundStyle(.tint)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: Circle())
                    Label("Show on Widget", systemImage: "rectangle.on.rectangle")
                        .font(.body.weight(.semibold)).foregroundStyle(.tint)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .glassEffect(.regular, in: Capsule())
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            }
        }
        .animation(.snappy, value: bike)
    }

    /// Off: a plain glass bike button. On: Citi Bike blue, named.
    @ViewBuilder private var modeSwitch: some View {
        Button {
            bike = bike == nil ? .bike : nil
        } label: {
            if bike != nil {
                Label("Trains Fucked", systemImage: "bicycle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glassEffect(.regular.tint(Mock.citiBike), in: Capsule())
            } else {
                Image(systemName: "bicycle")
                    .font(.body.weight(.semibold)).foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: Circle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Off

    @ViewBuilder private var trainTrips: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The R is delayed").font(.subheadline.weight(.semibold))
                    Text("A Citi Bike to another line could get you there 19 min sooner.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    bike = .bike
                } label: {
                    Label("Try Citi Bike", systemImage: "bicycle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Mock.citiBike, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.orange.opacity(0.12))
        MockRow(routes: ["R"], title: "4 Av-9 St → Times Sq-42 St", minutes: 46, picked: true) {
            legLine("exclamationmark.triangle.fill", "Delayed · next R in 19 min", tint: .orange)
        }
        Divider().padding(.leading, 80)
        MockRow(routes: ["F"], title: "4 Av-9 St → 42 St-Bryant Pk", minutes: 49) {
            legLine("exclamationmark.triangle.fill", "Delayed · next F in 14 min", tint: .orange)
        }
    }

    // MARK: On

    @ViewBuilder private func bikeTrips(_ kind: BikeKind) -> some View {
        let electric = kind == .eBike
        Picker("Ride", selection: Binding { kind } set: { bike = $0 }) {
            ForEach(BikeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
        MockRow(bike: true, electric: electric, routes: ["Q"], title: "\(electric ? "E-bike 4" : "Bike 7") min → Atlantic Av",
                minutes: electric ? 23 : 27, picked: true) {
            legLine(electric ? "bolt.fill" : "bicycle",
                    electric ? "2 e-bikes at 4 Av & 9 St · 11 docks free" : "6 bikes at 4 Av & 9 St · 11 docks free",
                    tint: Mock.citiBike)
            legLine("tram.fill", ["Q"], electric ? "in 1 min · or the N in 6" : "in 4 min · or the N in 6")
        }
        Divider().padding(.leading, 80)
        // The rest, ranked by arrival: on a bike the 2/3 beat the A; on an e-bike the A wins
        let others = [
            OtherTrip(route: "A", lines: ["A", "C"],
                      title: electric ? "E-bike 6 min → Jay St-MetroTech" : "Bike 11 min → Jay St-MetroTech",
                      minutes: electric ? 27 : 33, how: "to 42 St-Port Authority, 3 min walk"),
            OtherTrip(route: "2", lines: ["2", "3"],
                      title: electric ? "E-bike 4 min → Atlantic Av" : "Bike 7 min → Atlantic Av",
                      minutes: electric ? 28 : 31, how: electric ? "in 6 min" : "in 9 min"),
        ].sorted { $0.minutes < $1.minutes }
        ForEach(others, id: \.route) { trip in
            MockRow(bike: true, electric: electric, routes: [trip.route], title: trip.title, minutes: trip.minutes) {
                legLine("tram.fill", trip.lines, trip.how)
            }
            Divider().padding(.leading, 80)
        }
        MockRow(routes: ["R"], title: "4 Av-9 St → Times Sq-42 St", minutes: 46, dimmed: true) {
            legLine("exclamationmark.triangle.fill", "Delayed · next R in 19 min", tint: .orange)
        }
    }
}

#Preview("1 · Delayed, off") { TripsMock() }
#Preview("2 · On, Bike") { TripsMock(bike: .bike) }
#Preview("3 · On, E-Bike") { TripsMock(bike: .eBike) }
