import CoreLocation
import SwiftUI

/// The Widgets tab: saved widget configurations, which Home and Lock Screen widgets pick
/// from in Edit Widget.
struct WidgetsView: View {
    @Environment(WidgetStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var newWidget: SavedWidget?
    /// Picking where a new countdown counts down.
    @State private var choosingCountdown = false
    /// The route open in Edit Route, if any.
    @State private var path: [UUID] = []
    /// The explanation's been shown, the first time this tab opened.
    @AppStorage(RoutesIntro.seenKey) private var introSeen = false
    @State private var showingIntro = false
    /// Every route's feeds fetched once for all their first loads as the tab shows.
    @State private var firstLoads = FirstLoads()

    /// A new route, starting at your Home Station: From, To and the ways there are planned on
    /// a map as New Trip plans (`NewRouteView`), then saved.
    private func add() {
        var start = settings.defaultTrain
        if let station = start.station { start.routes = station.routes }
        newWidget = SavedWidget(selection: start)
    }

    /// A new route with no To, counting down where and which way `CountdownSetup` picked.
    private func addCountdown(_ widget: SavedWidget) {
        guard widget.start.id != nil else { return }
        store.add(widget)
        store.setLook(.medium, for: widget.id)
    }

    /// The inputs that decide what an unconfigured (or orphaned) placed Transfers widget shows:
    /// which widgets, in order, have a change.
    private var placement: [String] {
        store.saved.widgets.map { "\($0.id) \($0.change != nil)" }
    }

    @Environment(\.isSideways) private var sideways
    @Environment(\.colorScheme) private var colorScheme
    private var paper: SplashPaper { .routes(colorScheme) }

    /// VoiceOver's Move Up and Move Down, as `.onMove` would, where there's room.
    @ViewBuilder private func moveActions(_ id: UUID) -> some View {
        let widgets = store.saved.widgets
        if let index = widgets.firstIndex(where: { $0.id == id }) {
            if index > 0 {
                Button("Move Up") { store.move(fromOffsets: [index], toOffset: index - 1) }
            }
            if index < widgets.count - 1 {
                Button("Move Down") { store.move(fromOffsets: [index], toOffset: index + 2) }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(store.saved.widgets) { widget in
                        WidgetRow(widget: widget, look: store.look(for: widget.id),
                                  placed: store.placed[widget.id] ?? 0, firstLoads: firstLoads)
                            // The whole widget opens it, without a chevron beside it
                            .background {
                                NavigationLink(value: widget.id) { EmptyView() }.opacity(0)
                            }
                            // Gaps between the cards
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            // The link behind is invisible to VoiceOver, so the row itself is the button
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Edit this route")
                            // Dragging is the only other way to reorder, with no Edit button
                            .accessibilityActions { moveActions(widget.id) }
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ store.saved.widgets[$0].id }) { store.delete(id) }
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            // Every route deleted: what New Route is for
            .overlay {
                if store.saved.widgets.isEmpty {
                    ContentUnavailableView {
                        Label("No Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    } description: {
                        Text("Plan a trip you take often, then put it on your Home Screen. Until then, widgets show your Home Station.")
                    }
                    .foregroundStyle(sideways ? AnyShapeStyle(.secondary) : AnyShapeStyle(paper.ink))
                }
            }
            .navigationDestination(for: UUID.self) { id in
                WidgetEditor(id: id)
                    .toolbar(.visible, for: .navigationBar)
            }
            // As the Home Screen: the widgets on the splash's map, each named under it
            .scrollContentBackground(.hidden)
            // On its side, a card over the map in its place (`sidewaysCard`)
            .background {
                if !sideways { RoutesBackdrop() }
            }
            .contentMargins(.top, 16, for: .scrollContent)
            // No title bar, as New Trip: the tab says where you are
            .toolbar(.hidden, for: .navigationBar)
            // Over the tab bar, by your thumb
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 10) {
                    addButton("Countdown", hint: "Adds a route counting down trains or buses at one station or stop") {
                        choosingCountdown = true
                    }
                    addButton("New Route", hint: "Plans a trip from one place to another, every way across the week",
                              action: add)
                }
                .padding(.bottom, 8)
            }
            .sheet(isPresented: $choosingCountdown) {
                CountdownSetup(saveTitle: "Save Countdown", save: addCountdown)
            }
            // On its side, down the left over the map as Nearby's card, New Route at its foot
            .sidewaysCard()
            .fullScreenCover(item: $newWidget) { widget in
                NewRouteView(starting: widget)
            }
            // The first time here, what Routes are for; seen once it's shown
            .sheet(isPresented: $showingIntro) {
                RoutesIntro { showingIntro = false }
            }
            // Before the routes' loads, which wait a moment first
            .onAppear {
                firstLoads.start(store.saved.widgets, look: store.look(for:), settings: settings.settings)
            }
            .onAppear {
                guard !introSeen else { return }
                introSeen = true
                showingIntro = true
            }
            // Placed widgets change outside the app, so recount on appear and foreground
            .task { await store.countPlaced() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.countPlaced() } }
            }
            // ...and when edits here change which saved widget some of them show
            .onChange(of: placement) {
                Task { await store.countPlaced() }
            }
        }
    }
}

extension WidgetsView {
    /// A glass capsule with a plus, over the tab bar.
    fileprivate func addButton(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityHint(hint)
    }
}

private struct WidgetRow: View {
    let widget: SavedWidget
    /// As last shown while editing it.
    let look: WidgetLook
    let placed: Int
    let firstLoads: FirstLoads

    /// With a typed name, what it rides beside the way; without, the name is what it rides, so
    /// only the way.
    private var detail: String {
        let way = widget.way
        guard widget.isNamed else { return way }
        return way.isEmpty ? widget.summary : "\(widget.summary) · \(way)"
    }

    private var placedText: String {
        switch placed {
        case 0: "Not on Home Screen yet"
        case 1: "On Home Screen"
        default: "On Home Screen ×\(placed)"
        }
    }

    /// The widget as the Home Screen shows it, nothing under it; its name, way and whether it's
    /// on the Home Screen read out.
    var body: some View {
        WidgetPreview(widget: widget, look: look, firstLoads: firstLoads)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([widget.title, detail, placedText].filter { !$0.isEmpty }.joined(separator: ", "))
        .frame(maxWidth: WidgetLook.medium.size.width)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

extension SplashPaper {
    /// The Routes tab's paper: cream, or navy in Dark Mode.
    static func routes(_ scheme: ColorScheme) -> SplashPaper { scheme == .dark ? .navy : .cream }
}

/// What Routes are for, shown the first time the tab opens: a route's widget, with a change,
/// its parts pointed out.
struct RoutesIntro: View {
    let done: () -> Void
    static let seenKey = "routesIntroSeen"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(.bottom, 8)
                        .accessibilityHidden(true)
                    Text("Routes")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Trips you take often, ready on your Home Screen.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 12)
                    WidgetParts()
                        // Its countdown's arrow comes down outside the widget, in the page's margin
                        .padding(.horizontal, -20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            Button(action: done) {
                Text("Got It")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .interactiveDismissDisabled()
    }
}

/// The example route with a change (the R north from Prospect Av, changing at Atlantic, as its
/// times are), as a medium widget, with arrows from notes above and below it to what its parts do.
private struct WidgetParts: View {
    private static let route = Selection(stationID: "R34", routes: ["R"], direction: .north)
    /// Its times, as a route that goes somewhere: New Trip's button where the countdown's would be.
    private static var sample: TrainEntry {
        var entry = TrainEntry.transferPreview(selection: route)
        entry.plansRoute = UUID()
        return entry
    }

    /// Where each note's arrow ends on the widget, from its top left.
    private enum Spot {
        static let walk = CGPoint(x: 300, y: 12)
        static let countdown = CGPoint(x: 24, y: 72)
        /// The bottom right corner of the walk's second train.
        static let transfer = CGPoint(x: 209, y: 133)
    }
    private static let size = WidgetLook.medium.size
    /// The notes' height above and below the widget.
    private static let top: CGFloat = 56
    private static let bottom: CGFloat = 70
    /// Room either side for the countdown's arrow to come down outside the widget.
    private static let side: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                note("The MTA's own live countdown", alignment: .leading)
                Spacer(minLength: 24)
                note("Start navigation using this route", alignment: .trailing)
            }
            .frame(height: Self.top, alignment: .top)
            WidgetPreview(widget: SavedWidget(selection: Self.route), sample: Self.sample)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            HStack(alignment: .top) {
                note("Tap anywhere to check for an update", alignment: .leading)
                Spacer(minLength: 24)
                note("Prioritizes transfers across a platform", alignment: .trailing)
            }
            .padding(.top, 22)
            .frame(height: Self.bottom, alignment: .top)
        }
        .frame(width: Self.size.width)
        .padding(.horizontal, Self.side)
        .overlay {
            Canvas { context, _ in
                let top = Self.top, bottom = Self.top + Self.size.height
                func spot(_ point: CGPoint) -> CGPoint { CGPoint(x: Self.side + point.x, y: top + point.y) }
                let left = Self.side, right = Self.side + Self.size.width
                arrow(from: CGPoint(x: right - 50, y: 38), to: spot(Spot.walk), bend: 10, in: context)
                // From under the "l" of "live", bowed out past the widget's left edge, into the
                // countdown's first digit
                arrow(from: CGPoint(x: left + 3, y: 36), to: spot(Spot.countdown), bend: -28, in: context)
                arrow(from: CGPoint(x: right - 80, y: bottom + 16), to: spot(Spot.transfer), bend: 8, in: context)
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String, alignment: TextAlignment) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
            .frame(maxWidth: 150, alignment: alignment == .leading ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A line in the tint from `start` to `end`, bowed sideways by `bend`, with a head.
    private func arrow(from start: CGPoint, to end: CGPoint, bend: CGFloat, in context: GraphicsContext) {
        let mid = CGPoint(x: (start.x + end.x) / 2 + bend, y: (start.y + end.y) / 2)
        var line = Path()
        line.move(to: start)
        line.addQuadCurve(to: end, control: mid)
        stroke(line, end: end, from: mid, in: context)
    }

    /// `line`, and its head at `end`, pointing on from `from`.
    private func stroke(_ line: Path, end: CGPoint, from: CGPoint, in context: GraphicsContext) {
        let tint = GraphicsContext.Shading.color(.accentColor)
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
        context.stroke(line, with: tint, style: style)
        let angle = atan2(end.y - from.y, end.x - from.x)
        var head = Path()
        for side in [-1.0, 1.0] {
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - 7 * cos(angle + side * .pi / 6),
                                     y: end.y - 7 * sin(angle + side * .pi / 6)))
        }
        context.stroke(head, with: tint, style: style)
    }
}

#Preview("Routes Intro") {
    RoutesIntro {}
        .environment(SettingsStore())
}

/// Behind the Routes tab's widgets: the splash's map, finished, without "Leeway", its mark
/// dimmed under them.
private struct RoutesBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LeewaySplashView(markCenterY: 0.66, still: true, paper: .routes(colorScheme),
                         lineOpacity: 0.5)
    }
}

/// Edits one saved widget.
private struct WidgetEditor: View {
    let id: UUID
    @Environment(WidgetStore.self) private var store

    /// Remembered, so the Widgets tab draws it as last shown here.
    private var look: Binding<WidgetLook> {
        Binding {
            store.look(for: id)
        } set: {
            store.setLook($0, for: id)
        }
    }

    var body: some View {
        if let widget = store.binding(for: id) {
            let countdown = widget.wrappedValue.isCountdown
            Form {
                WidgetHeader(widget: widget.wrappedValue, look: look)
                if countdown {
                    CountdownFields(widget: widget)
                } else {
                    WidgetFields(widget: widget)
                }
            }
            .listSectionSpacing(.compact)
            .pinnedWidget(widget.wrappedValue, look: look)
            // The name is edited in its field, as Clock's Edit Alarm does
            .navigationTitle(countdown ? "Edit Countdown" : "Edit Route")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Countdowns

extension SavedWidget {
    /// No To: it only counts down at its station or stop, its lines one way or both. Edited in
    /// Edit Countdown, just the place and which way.
    var isCountdown: Bool {
        guard commute == nil, end.id == nil, start.id != nil else { return false }
        switch kind {
        case .subway: return change == nil
        case .bus: return bus?.planned == nil && (bus?.changes ?? []).isEmpty
        case .bike: return false
        }
    }
}

/// Which way a countdown counts down: a station's lines one way or both, or a stop's bus one way
/// or both.
enum CountdownWay: Hashable {
    case train(Direction)
    case trainBoth
    case bus(line: String, to: String)
    case busBoth(line: String)

    /// "Uptown & The Bronx", "Both Ways", "B63 to Cobble Hill", "B63 Both Ways".
    func label(at place: RouteStart, routes: [String]? = nil) -> String {
        switch self {
        case .train(let direction):
            guard case .station(let station) = place else { return "" }
            return station.directionLabel(direction, routes: routes ?? station.routes)
        case .trainBoth: return "Both Ways"
        case .bus(let line, let to): return "\(BusNames.label(line)) to \(BusNames.destination(to))"
        case .busBoth(let line): return "\(BusNames.label(line)) Both Ways"
        }
    }

    /// Which way `widget` counts down.
    static func current(_ widget: SavedWidget) -> CountdownWay? {
        switch widget.kind {
        case .subway: return widget.bothWays ? .trainBoth : .train(widget.selection.direction)
        case .bus:
            guard let bus = widget.bus else { return nil }
            return bus.bothWays ? .busBoth(line: bus.line) : .bus(line: bus.line, to: bus.destination ?? "")
        case .bike: return nil
        }
    }

    /// The nearest stop of `line` the other way from `stop`, and where it goes there: on a way
    /// that doesn't call at `stop`, within a short walk.
    static func otherWay(of line: String, to: String, at stop: BusRoutes.Stop) -> (stop: BusRoutes.Stop, to: String)? {
        let here = stop.location
        return BusRoutes.ways(of: line)
            .filter { $0.to != to && !$0.stops.contains { $0.code == stop.code } }
            .flatMap { way in way.stops.map { (stop: $0, to: way.to, meters: $0.location.distance(from: here)) } }
            .filter { $0.meters < 500 }
            .min { $0.meters < $1.meters }
            .map { ($0.stop, $0.to) }
    }

    /// `widget` counting down this way at `place`, with no To.
    func applied(at place: RouteStart, to widget: SavedWidget) -> SavedWidget {
        var widget = widget
        if widget.start.id != place.id { widget.startAt(place) }
        switch (self, place) {
        case (.train(let direction), .station):
            widget.bothWays = false
            widget.selection.direction = direction
        case (.trainBoth, .station):
            widget.bothWays = true
        case (.bus(let line, let to), .stop(let stop)):
            let other = Self.otherWay(of: line, to: to, at: stop)
            widget.bus = BusChoice(line: line, stop: stop.busStop, destination: to, otherStop: other?.stop.busStop,
                                   otherDestination: other?.to)
            widget.bothWays = false
        case (.busBoth(let line), .stop(let stop)):
            // The way it's going now if that one comes back nearby, else the first that does
            let tos = (BusRoutes.linesAtStop[stop.code] ?? []).filter { $0.line == line }.map(\.to)
            let kept = widget.bus?.line == line ? widget.bus?.destination : nil
            let to = ([kept].compactMap { $0 }.filter(tos.contains) + tos)
                .first { Self.otherWay(of: line, to: $0, at: stop) != nil }
            guard let to, let other = Self.otherWay(of: line, to: to, at: stop) else { break }
            widget.bus = BusChoice(line: line, stop: stop.busStop, destination: to, otherStop: other.stop.busStop,
                                   otherDestination: other.to, bothWays: true)
            widget.bothWays = true
        default:
            break
        }
        widget.countdownOnly()
        return widget
    }
}

/// Edit Countdown's fields: where it counts down (tap to pick another, then which way there),
/// and which way.
private struct CountdownFields: View {
    @Binding var widget: SavedWidget
    @State private var choosing = false

    private var routes: [String]? { widget.kind == .subway ? widget.selection.routes : nil }

    var body: some View {
        let place = widget.start
        Section {
            Button {
                choosing = true
            } label: {
                CountdownPlaceRow(place: place, marks: widget.kind == .subway ? widget.selection.routes : place.marks,
                                  detail: nil, chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose another station or bus stop")
            NavigationLink {
                CountdownDirectionStep(place: place, line: widget.bus?.line, editing: widget, saveTitle: "Done",
                                       popsOnSave: true) { widget = $0 }
            } label: {
                HStack {
                    Text("Direction").foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(CountdownWay.current(widget)?.label(at: place, routes: routes) ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .sheet(isPresented: $choosing) {
            CountdownSetup(editing: widget, saveTitle: "Done") { widget = $0 }
        }

    }
}

/// A station or stop: its lines' marks, its name, and a caption.
private struct CountdownPlaceRow: View {
    let place: RouteStart
    let marks: [String]
    let detail: String?
    var chevron = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name ?? "Choose a station or stop")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 3) {
                    ForEach(marks.prefix(8), id: \.self) { RouteMark(route: $0, size: 18) }
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// A countdown's place, for pushing its Direction step.
private struct CountdownPick: Hashable {
    let place: RouteStart
    static func == (a: Self, b: Self) -> Bool { a.place.id == b.place.id }
    func hash(into hasher: inout Hasher) { hasher.combine(place.id) }
}

/// Setting up a countdown: the three stations nearest you (or what's searched for, stations and
/// bus stops), then which way, then `saveTitle` hands it to `save`. With `editing`, that one
/// moved and turned.
struct CountdownSetup: View {
    var editing: SavedWidget? = nil
    let saveTitle: String
    let save: (SavedWidget) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @State private var location = NearbyLocation()
    @State private var search = ""
    @State private var stops: [BusRoutes.Stop] = []
    @State private var picked: CountdownPick?

    /// The three stations nearest you, each with how far.
    private var nearest: [(station: Station, meters: CLLocationDistance)] {
        guard let here = location.location else { return [] }
        return StationDirectory.all
            .map { (station: $0, meters: here.distance(from: $0.location)) }
            .sorted { $0.meters < $1.meters }
            .prefix(3)
            .map { $0 }
    }

    private var found: [Station] {
        let query = StationSearch(search)
        return StationDirectory.all.filter(query.matches).sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    nearbySection
                } else {
                    if !found.isEmpty {
                        Section(stops.isEmpty ? "" : "Stations") {
                            ForEach(found) { station in
                                placeButton(.station(station), detail: nil)
                            }
                        }
                    }
                    if !stops.isEmpty {
                        Section("Bus Stops") {
                            ForEach(stops, id: \.code) { stop in
                                let to = BusRoutes.linesAtStop[stop.code]?.first?.to
                                placeButton(.stop(stop), detail: to.map { "toward \(BusNames.destination($0))" })
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Station, or street for a bus stop")
            .navigationTitle(editing == nil ? "New Countdown" : "Edit Countdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
            }
            .navigationDestination(item: $picked) { pick in
                CountdownDirectionStep(place: pick.place, editing: editing, saveTitle: saveTitle) { widget in
                    save(widget)
                    dismiss()
                }
            }
            .task(id: search) {
                let found = await BusStopSearch.find(search, among: nil)
                guard !Task.isCancelled else { return }
                stops = found
            }
            .onAppear {
                location.start()
                if location.isAllowed { location.find() }
            }
        }
    }

    /// Before typing: the nearest three, or without your location, your Home Station.
    @ViewBuilder private var nearbySection: some View {
        let nearest = nearest
        if !nearest.isEmpty {
            Section("Nearest") {
                ForEach(nearest, id: \.station.id) { near in
                    placeButton(.station(near.station), detail: Measurement(value: near.meters, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road)))
                }
            }
        } else {
            if location.isAllowed && !location.failed {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding stations near you…").foregroundStyle(.secondary)
                    }
                }
            } else if location.status == .notDetermined {
                Section {
                    Button("Show Stations Near Me", systemImage: "location.fill") { location.find() }
                }
            }
            if let home = settings.defaultTrain.station {
                Section {
                    placeButton(.station(home), detail: "Home Station")
                }
            }
        }
    }

    private func placeButton(_ place: RouteStart, detail: String?) -> some View {
        Button {
            picked = CountdownPick(place: place)
        } label: {
            CountdownPlaceRow(place: place, marks: place.marks, detail: detail, chevron: true)
        }
        .buttonStyle(.plain)
    }
}

/// A countdown's second step: which way at its place, on the train picker's Direction tiles
/// (Both under them where there's two), then save. At a stop with more than one bus, which bus
/// first.
private struct CountdownDirectionStep: View {
    let place: RouteStart
    /// At a stop, its bus; nil to choose one where there's more than one.
    var line: String? = nil
    let editing: SavedWidget?
    let saveTitle: String
    /// Goes back once saved: pushed from Edit Countdown, rather than in a sheet `save` closes.
    var popsOnSave = false
    let save: (SavedWidget) -> Void
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    /// The way picked, and where: at a stop, the other way is the stop across the street.
    @State private var picked: (place: RouteStart, way: CountdownWay)?
    /// For a station's Both, which way leads.
    @State private var lead: Direction?

    /// Editing at the same station, its own lines; else all of them.
    private var routes: [String]? {
        guard let editing, editing.kind == .subway, editing.start.id == place.id else { return nil }
        return editing.selection.routes
    }

    var body: some View {
        content
            .safeAreaBar(edge: .bottom) {
                if !needsLine {
                    Button {
                        guard let picked else { return }
                        var widget = picked.way.applied(at: picked.place,
                                                        to: editing ?? SavedWidget(selection: settings.defaultTrain))
                        if picked.way == .trainBoth, let lead { widget.selection.direction = lead }
                        save(widget)
                        if popsOnSave { dismiss() }
                    } label: {
                        Text(saveTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(picked == nil)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
            .onAppear(perform: pickCurrent)
    }

    /// The stop's buses, each once.
    private var lines: [String] {
        guard case .stop(let stop) = place else { return [] }
        return (BusRoutes.linesAtStop[stop.code] ?? []).map(\.line)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private var needsLine: Bool {
        guard case .stop = place else { return false }
        return line == nil && lines.count > 1
    }

    @ViewBuilder private var content: some View {
        switch place {
        case .station(let station):
            let routes = routes ?? station.routes
            DirectionStep(station: station, routes: routes, current: trainDirection, offersBoth: true,
                          bothCurrent: picked?.way == .trainBoth) { direction, both in
                lead = direction
                picked = (place, both ? .trainBoth : .train(direction))
            }
        case .stop(let stop):
            if needsLine {
                lineList(stop)
            } else if let line = line ?? lines.first, let ways = busWays(line, at: stop) {
                BusDirectionStep(pick: ways.pick, stopName: BusNames.readable(stop.name),
                                 chosen: busChosen(ways), bothChosen: picked?.way == .busBoth(line: line)) { choice in
                    if choice.bothWays {
                        picked = (place, .busBoth(line: line))
                    } else if let other = ways.other, choice.stop.id == other.stop.code {
                        picked = (.stop(other.stop), .bus(line: line, to: other.to))
                    } else {
                        picked = (place, .bus(line: line, to: ways.to))
                    }
                }
            }
        case .none:
            EmptyView()
        }
    }

    private var trainDirection: Direction? {
        switch picked?.way {
        case .train(let direction): direction
        case .trainBoth: lead
        default: nil
        }
    }

    /// Which bus, at a stop with more than one: each then goes on to its Direction.
    private func lineList(_ stop: BusRoutes.Stop) -> some View {
        let all = BusRoutes.linesAtStop[stop.code] ?? []
        return List {
            Section {
                ForEach(lines, id: \.self) { line in
                    NavigationLink {
                        CountdownDirectionStep(place: place, line: line, editing: editing, saveTitle: saveTitle,
                                               popsOnSave: popsOnSave, save: save)
                    } label: {
                        HStack(spacing: 12) {
                            BusBadge(line: line, size: 28)
                            Text(all.filter { $0.line == line }.map { BusNames.destination($0.to) }.joined(separator: " · "))
                                .font(.subheadline)
                        }
                    }
                }
            } header: {
                Text(BusNames.readable(stop.name))
            }
        }
        .navigationTitle("Bus")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// `line` from `stop`, one way and, if it comes back nearby, the other, as the bus picker
    /// has them; the way kept when editing it, else the first.
    private func busWays(_ line: String, at stop: BusRoutes.Stop)
        -> (pick: NearbyBusPick, to: String, other: (stop: BusRoutes.Stop, to: String)?)? {
        let tos = (BusRoutes.linesAtStop[stop.code] ?? []).filter { $0.line == line }.map(\.to)
        let kept = editing?.bus?.line == line ? editing?.bus?.destination : nil
        guard let to = kept.flatMap({ tos.contains($0) ? $0 : nil }) ?? tos.first else { return nil }
        let other = CountdownWay.otherWay(of: line, to: to, at: stop)
        var ways = [NearbyBusPick.Way(stop: stop.busStop, destination: to, arrivals: [])]
        if let other { ways.append(NearbyBusPick.Way(stop: other.stop.busStop, destination: other.to, arrivals: [])) }
        return (NearbyBusPick(line: line, ways: ways), to, other)
    }

    private func busChosen(_ ways: (pick: NearbyBusPick, to: String, other: (stop: BusRoutes.Stop, to: String)?)) -> Int? {
        guard let picked, case .bus = picked.way else { return nil }
        return picked.place.id == place.id ? 0 : 1
    }

    /// Editing here already: which way it is.
    private func pickCurrent() {
        guard picked == nil, let editing, let way = CountdownWay.current(editing) else { return }
        switch (place, way) {
        case (.station, .train), (.station, .trainBoth):
            guard editing.start.id == place.id else { return }
            lead = editing.selection.direction
            picked = (place, way)
        case (.stop, .bus(let busLine, _)), (.stop, .busBoth(let busLine)):
            guard busLine == (line ?? lines.first), editing.start.id == place.id else { return }
            picked = (place, way)
        default:
            break
        }
    }
}

/// The Saved Route's three sizes as tiles, each its outline with its name and size.
private struct LookTiles: View {
    @Binding var look: WidgetLook

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WidgetLook.allCases) { tile in
                let selected = tile == look
                Button {
                    look = tile
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(selected ? Color.accentColor.opacity(0.2) : .clear)
                            .strokeBorder(lineWidth: 1.5)
                            .frame(width: tile.glyph.width, height: tile.glyph.height)
                            .frame(height: 34)
                        Text(tile.kindName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(tile.sizeName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle.pickerCard
                        .fill(selected ? Color.accentColor.opacity(0.1) : Color(.secondarySystemGroupedBackground)))
                    .contentShape(RoundedRectangle.pickerCard)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// The widget being set up, as the Home Screen will show it and redrawn as its fields change,
/// with which widget to show it as. The top of the form, so it scrolls away with it; then
/// `pinnedWidget` keeps a small copy.
private struct WidgetHeader: View {
    let widget: SavedWidget
    @Binding var look: WidgetLook

    var body: some View {
        Section {
            VStack(spacing: 10) {
                WidgetPreview(widget: widget, look: look)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                LookTiles(look: $look)
                    .frame(maxWidth: WidgetLook.medium.size.width)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
            .id(PinnedWidget.top)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

extension View {
    /// Once `WidgetHeader` has mostly scrolled away, a bar at the top with a small copy of the
    /// widget and a menu for which widget and size; tapping the copy goes back up to the full one.
    fileprivate func pinnedWidget(_ widget: SavedWidget, look: Binding<WidgetLook>) -> some View {
        modifier(PinnedWidget(widget: widget, look: look))
    }
}

/// See `View.pinnedWidget(_:look:)`.
private struct PinnedWidget: ViewModifier {
    let widget: SavedWidget
    @Binding var look: WidgetLook
    @State private var compact = false

    /// The id of `WidgetHeader`'s row, to scroll back to. A Form is a List, which
    /// `scrollPosition` doesn't scroll, so this goes through a `ScrollViewReader`.
    static let top = "widgetHeader"

    /// Small enough for a bar: half size, or less for the large widget.
    private var scale: CGFloat { min(0.5, 90 / look.size.height) }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                // Shown once the header's widget is mostly out of sight, and hidden a little
                // higher, so it doesn't flip back and forth at the line
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, scrolled in
                    let line = look.size.height * 0.7
                    let shown = compact ? scrolled > line - 24 : scrolled > line
                    guard shown != compact else { return }
                    withAnimation(.snappy(duration: 0.25)) { compact = shown }
                }
                // Floating over the form under the navigation bar, not a safeAreaBar: adding or
                // removing one changes the form's top inset, and its scroll position jumps
                // far enough to show or hide the bar again, over and over
                .overlay(alignment: .top) {
                    if compact {
                        bar(proxy)
                            .glassEffect(.regular, in: .rect(cornerRadius: 26))
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
    }

    private func bar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 14) {
            Button {
                withAnimation { proxy.scrollTo(Self.top, anchor: .top) }
            } label: {
                // At its full size, then shrunk: offered less room, it would narrow instead
                WidgetPreview(widget: widget, look: look)
                    .frame(width: look.size.width, height: look.size.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: look.size.width * scale, height: look.size.height * scale, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the widget full size")
            // The widget's name and size as plain text, all of it the menu: a glass button
            // inside the glass card looked cramped
            Menu {
                Picker("Preview As", selection: $look) {
                    ForEach(WidgetLook.allCases) { look in
                        Text(look.title).tag(look)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(look.kindName)
                            .font(.headline)
                        Text(look.sizeName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Preview As")
            .accessibilityValue(look.title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

/// Fields shared by adding and editing a widget.
private struct WidgetFields: View {
    @Binding var widget: SavedWidget

    /// A route saved with a change but nowhere it goes: planned the old way, station and change
    /// by hand, as it has no To to find ways to.
    private var plannedByHand: Bool {
        widget.change != nil && widget.change?.destinationID == nil && widget.change?.planned == nil
    }

    /// Goes through `setSelection`, which keeps or drops the change in the same update.
    private var train: Binding<Selection> {
        Binding {
            widget.selection
        } set: {
            widget.setSelection($0)
        }
    }

    var body: some View {
        switch widget.kind {
        case .subway: trainFields
        // A bus route planned From and To; one saved before without a To keeps its bus and
        // change picked by hand
        case .bus where widget.destinationID != nil:
            RoutePlanSections(widget: $widget)
        case .bus, .bike: RouteFields(widget: $widget)
        }
    }

    @ViewBuilder private var trainFields: some View {
        if plannedByHand {
            handPlanned
        } else {
            RoutePlanSections(widget: $widget)
        }
        CommuteSection(widget: $widget)
        Section {
            Toggle("Service alerts", isOn: $widget.selection.serviceAlerts)
            Toggle("Elevator outages", isOn: $widget.selection.elevatorAlerts)
        }
    }

    /// The old planning: the train and its change, each picked by hand.
    @ViewBuilder private var handPlanned: some View {
        TripSections(selection: train, change: $widget.change, destinationID: $widget.destinationID,
                     bothWays: $widget.bothWays, route: $widget) {
            // Labelled like Depart from and Arrive at below it; empty, it's named by what it rides
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(widget.summary, text: $widget.name)
                    .font(.headline)
                    .accessibilityLabel("Name")
            }
            .padding(.vertical, 4)
        }
    }
}

/// A train row (tap to change) and its optional change of trains, for a widget or its
/// commuting hours. Bind `selection` through `setSelection`, which keeps or drops the change.
private struct TripSections<Leading: View>: View {
    @Binding var selection: Selection
    @Binding var change: Change?
    /// Where you're going without a change; with one, the change's destination is edited instead.
    @Binding var destinationID: String?
    /// A widget's Both directions, picked as the train's direction; nil where it isn't offered.
    var bothWays: Binding<Bool>?
    /// The route these are, whose Depart from can then be a bus stop too; nil for trains only.
    var route: Binding<SavedWidget>?
    /// The card's header, e.g. when the other trip shows; nil for none.
    var header: String?
    /// Rows above Depart from and Arrive at, in the same card: the widget's name, or the other
    /// trip's days and hours.
    let leading: Leading
    @State private var choosingTrain = false
    @State private var choosingChange = false
    /// Which of the change's `stops` the change picker edits; nil to add one.
    @State private var editingStop: Int?
    @State private var choosingDestination = false

    private var walkMinutes: Binding<Int> {
        Binding {
            change?.walkMinutes ?? Change.defaultWalkMinutes
        } set: {
            change?.walkMinutes = $0
        }
    }

    init(selection: Binding<Selection>, change: Binding<Change?>, destinationID: Binding<String?>,
         bothWays: Binding<Bool>? = nil, route: Binding<SavedWidget>? = nil, header: String? = nil,
         @ViewBuilder leading: () -> Leading) {
        _selection = selection
        _change = change
        _destinationID = destinationID
        self.bothWays = bothWays
        self.route = route
        self.header = header
        self.leading = leading()
    }

    /// `leading`, then where you start and where you're going, side by side, then the change,
    /// all in one card.
    var body: some View {
        Section {
            leading
            HStack(alignment: .top, spacing: 12) {
                departButton
                Divider()
                arriveButton
            }
            .padding(.vertical, 4)
            changeRows
        } header: {
            if let header { Text(header) }
        }
        if let change {
            suggestionsSection(change)
        }
    }

    private var departButton: some View {
        Button {
            choosingTrain = true
        } label: {
            EndpointCell(title: "Depart from", routes: selection.routes, name: selection.station?.name,
                         detail: bothWays?.wrappedValue == true ? "Both ways" : selection.heading,
                         placeholder: "Choose a train")
        }
        .buttonStyle(.plain)
        .accessibilityHint(route == nil ? "Choose another station, line or direction"
                                        : "Choose another station or bus stop")
        // On the button, not the Section: a Section applies modifiers to each row, header
        // and footer, and the duplicate sheets break this one
        .sheet(isPresented: $choosingTrain) {
            if let route {
                NewWidgetPicker(kind: .subway, editing: route.wrappedValue) { route.wrappedValue.takeDeparture($0) }
            } else {
                TrainPicker(selection: $selection, bothWays: bothWays)
            }
        }
    }

    private var arriveButton: some View {
        let station = destination.wrappedValue.flatMap(StationDirectory.station(id:))
        return Button {
            choosingDestination = true
        } label: {
            EndpointCell(title: "Arrive at", routes: [], name: station?.name, detail: nil,
                         placeholder: "Add a destination")
        }
        .buttonStyle(.plain)
        .accessibilityHint(change == nil ? "Choose where you're going, to show when you'd get there"
                                         : "Choose where you're going, to time each way there")
        .sheet(isPresented: $choosingDestination) {
            DestinationPicker(selection: selection, change: change, destinationID: destination)
        }
    }
}

/// Half of the Depart from and Arrive at row: its label, then the station (or a placeholder to
/// tap) with any line bullets and a caption.
private struct EndpointCell: View {
    let title: String
    let routes: [String]
    let name: String?
    let detail: String?
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let name {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                // The lines' bullets, then which way: (R) Manhattan
                if !routes.isEmpty || detail != nil {
                    HStack(spacing: 6) {
                        if !routes.isEmpty {
                            LineBullets(routes: routes, size: 18)
                        }
                        if let detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } else {
                Text(placeholder)
                    .font(.headline)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

extension TripSections {
    /// The change's stations, each a row to edit or swipe away, the walk between platforms if
    /// any is on another, then an Add button. Rows of the Depart from and Arrive at card.
    @ViewBuilder fileprivate var changeRows: some View {
        let stops = change?.stops ?? []
        let parts = change?.smartChanges(for: selection) ?? []
        ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
            Button {
                editingStop = index
                choosingChange = true
            } label: {
                ChangeRow(change: stop, selection: selection,
                          lines: stops.count > 1 ? parts.first { $0.change == stop }?.lines : nil,
                          isAlternative: index > 0)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose another station or lines to change to")
        }
        .onDelete { offsets in
            remove(at: offsets)
        }
        if let change, parts.contains(where: { !$0.change.isAllAcross(from: selection.only($0.lines)) }) {
            Stepper(value: walkMinutes, in: 1...15) {
                Text("Walk between platforms: \(change.walkMinutes) min")
            }
        }
        // Always here, so the sheet stays attached when Done adds the first change
        Button {
            editingStop = nil
            choosingChange = true
        } label: {
            // "Or": another station to change at instead, not a second change along the way
            Label(change == nil ? "Add a Change" : "Or Change At",
                  systemImage: change == nil ? "arrow.triangle.swap" : "plus.circle.fill")
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $choosingChange) {
            ChangePicker(selection: selection, change: pickedStop)
        }
    }

    /// Stations next to the change's where a useful line is across the platform, each with a
    /// button to add it.
    @ViewBuilder private func suggestionsSection(_ change: Change) -> some View {
        let suggestions = change.suggestions(for: selection)
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions, id: \.change.stationID) { suggestion in
                    Button {
                        add(suggestion.change)
                    } label: {
                        SuggestionRow(suggestion: suggestion)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Adds this change")
                }
            } header: {
                Text("Also worth trying")
            } footer: {
                if let destination = change.destination {
                    Text("Stops next to your changes where a line to \(destination.name) is across the platform.")
                } else {
                    Text("Stops next to your changes where a line you'd walk to is across the platform.")
                }
            }
        }
    }

    /// Removes the change's `stops` at `offsets`, and with none left the change, keeping where
    /// you're going as the widget's own destination again.
    private func remove(at offsets: IndexSet) {
        guard let change else { return }
        var stops = change.stops
        stops.remove(atOffsets: offsets)
        if stops.isEmpty {
            destinationID = change.destinationID
            self.change = nil
        } else {
            self.change = Change(stops: stops)
        }
    }

    /// Adds `stop` to the change, joining it to one already at its station.
    private func add(_ stop: Change) {
        guard var stops = change?.stops else { return }
        if let index = stops.firstIndex(where: { $0.stationID == stop.stationID && $0.direction == stop.direction }) {
            stops[index].routes += stop.routes.filter { !stops[index].routes.contains($0) }
        } else {
            stops.append(stop)
        }
        change = Change(stops: stops)
    }

    /// The change's destination, or without a change, the widget's own.
    private var destination: Binding<String?> {
        Binding {
            change == nil ? destinationID : change?.destinationID
        } set: {
            if change == nil { destinationID = $0 } else { change?.destinationID = $0 }
        }
    }

    /// The stop `editingStop` for `ChangePicker`, or nil to add one. A picked station already
    /// among the stops replaces it. A change starts without a destination, so a first one takes
    /// the widget's: with a change, Arrive at edits the change's destination instead.
    private var pickedStop: Binding<Change?> {
        Binding {
            guard let editingStop, let stops = change?.stops, stops.indices.contains(editingStop) else { return nil }
            return stops[editingStop]
        } set: {
            guard var picked = $0 else { return }
            guard let change else {
                if picked.destinationID == nil { picked.destinationID = destinationID }
                self.change = picked
                return
            }
            var stops = change.stops
            let index = editingStop.flatMap { stops.indices.contains($0) ? $0 : nil }
                ?? stops.firstIndex { $0.stationID == picked.stationID }
            if let index { stops[index] = picked } else { stops.append(picked) }
            // One stop per station
            let kept = index ?? stops.count - 1
            stops = stops.enumerated().filter { $0.offset == kept || $0.element.stationID != picked.stationID }.map(\.element)
            // The stops share the first's walk and destination
            var joined = Change(stops: stops)
            joined?.walkMinutes = change.walkMinutes
            joined?.quickMinutes = change.quickMinutes
            joined?.destinationID = change.destinationID
            self.change = joined
        }
    }

}

/// Times and days when a widget shows another train (with its own change), e.g. the
/// train home in the evening. Only for routes saved with one already: new ones can't be added,
/// and swiping removes it.
private struct CommuteSection: View {
    @Binding var widget: SavedWidget

    /// Falls back to `commute` if removed while still on screen.
    private func hours(_ commute: CommutingHours) -> Binding<CommutingHours> {
        Binding {
            widget.commute ?? commute
        } set: {
            widget.commute = $0
        }
    }

    /// Goes through `setSelection`, which keeps or drops the change in the same update.
    private func train(_ hours: Binding<CommutingHours>) -> Binding<Selection> {
        Binding {
            hours.wrappedValue.selection
        } set: {
            hours.wrappedValue.setSelection($0)
        }
    }

    /// Minutes after midnight as a `Date` today.
    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    /// Minutes after midnight as a `Date` today, for a time picker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Self.date(minutes.wrappedValue)
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
    }

    /// When the other trip shows, as its card's header: "Weekdays, 4:00 PM–6:00 PM".
    private static func summary(_ hours: CommutingHours) -> String {
        let calendar = Calendar.current
        let days: String
        switch hours.weekdays {
        case Set(1...7): days = "Every day"
        case [2, 3, 4, 5, 6]: days = "Weekdays"
        case [1, 7]: days = "Weekends"
        case []: days = "No days"
        default:
            // In the locale's order, as the day buttons are
            let first = calendar.firstWeekday
            let ordered = (0..<7).map { (first - 1 + $0) % 7 + 1 }.filter(hours.weekdays.contains)
            days = ordered.map { calendar.shortWeekdaySymbols[$0 - 1] }.formatted(.list(type: .and))
        }
        let from = date(hours.start).formatted(date: .omitted, time: .shortened)
        let until = date(hours.end).formatted(date: .omitted, time: .shortened)
        return "\(days), \(from)–\(until)"
    }

    var body: some View {
        if let commute = widget.commute {
            let hours = hours(commute)
            TripSections(selection: train(hours), change: hours.change, destinationID: hours.destinationID,
                         header: Self.summary(hours.wrappedValue)) {
                WeekdayPicker(weekdays: hours.weekdays)
                    // Line the divider below up with the others
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    .swipeActions { removeButton }
                    .accessibilityAction(named: "Remove") { widget.commute = nil }
                // From and until on one row
                HStack {
                    Text("From")
                    DatePicker("From", selection: time(hours.start), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                    Text("Until")
                    DatePicker("Until", selection: time(hours.end), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                .swipeActions { removeButton }
                .accessibilityAction(named: "Remove") { widget.commute = nil }
            }
        }
    }

    /// Swiping the days or hours removes the other trip, as swiping a change removes it.
    private var removeButton: some View {
        Button("Remove", role: .destructive) { widget.commute = nil }
    }
}

/// Weekday toggles, in the locale's order.
private struct WeekdayPicker: View {
    @Binding var weekdays: Set<Int>
    /// Each day's circle, growing with its letter.
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 22

    /// `Calendar` weekday numbers starting from `firstWeekday`.
    private var days: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        HStack {
            ForEach(days, id: \.self) { day in
                let isOn = weekdays.contains(day)
                Button {
                    if isOn { weekdays.remove(day) } else { weekdays.insert(day) }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: size, height: size)
                }
                // Glass, tinted when on, as the system's own toggle buttons are
                .buttonStyle(.glass(isOn ? .regular.tint(.accentColor) : .regular))
                .buttonBorderShape(.circle)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
                if day != days.last { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A widget's change: lines, station, direction and how (across or walk).
private struct ChangeRow: View {
    let change: Change
    let selection: Selection
    /// Those of your train's lines it's for, to say so when not all; nil for all of them.
    var lines: [String]? = nil
    /// After the first, so it reads as a choice between changes rather than a second one.
    var isAlternative = false

    private var subtitle: String {
        let from = lines.map(selection.only) ?? selection
        // "or the B63 to Cobble Hill, 3 min walk"
        let buses = change.buses.map { "the \(BusNames.label($0.line)) to \($0.wayName), \($0.walkMinutes) min walk" }
        guard !change.routes.isEmpty else {
            return buses.joined(separator: " or ").prefix(1).uppercased() + buses.joined(separator: " or ").dropFirst()
        }
        let heading = change.heading(for: from)
        let how = change.isAllAcross(from: from) ? "across the platform" : "\(change.walkMinutes) min walk"
        let trains = "\(Lines.list(change.routes, joinedBy: "or")) \(heading) · \(how)"
        return buses.isEmpty ? trains : ([trains] + buses).joined(separator: ", or ")
    }

    /// "From the Q", when it's for only some of your lines.
    private var fromLines: String? {
        guard let lines, lines.count < selection.routes.count else { return nil }
        return "From the \(Lines.list(lines, joinedBy: "or"))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if change.routes.isEmpty, let bus = change.buses.first {
                    BusBadge(line: bus.line, size: 30)
                } else {
                    LineBullets(routes: change.routes, size: 36)
                }
            }
            .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                // Labelled like Depart from and Arrive at, as it shares their card
                Text(isAlternative ? "Or change at" : "Then change at")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(change.station?.name ?? "Choose a station").font(.headline).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let fromLines {
                    Text(fromLines)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A station worth adding to the change: its lines, where it is next to the change, and a button.
private struct SuggestionRow: View {
    let suggestion: ChangeSuggestion

    /// "Across the platform, a stop after Atlantic Av".
    private var detail: String {
        let besides = suggestion.besides.station?.name.mainStationName ?? "your change"
        return "Across the platform, a stop \(suggestion.sooner ? "before" : "after") \(besides)"
    }

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: suggestion.change.routes, size: 28)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Lines.list(suggestion.change.routes, joinedBy: "or")) at \(suggestion.change.station?.name ?? "")")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The train on a widget or train page; tapping it opens the picker.
struct TrainChoiceRow: View {
    let selection: Selection
    /// Shown when there's no station.
    var placeholder = "Choose a train"

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: selection.routes, size: 36)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.station?.name ?? placeholder).font(.headline).foregroundStyle(.primary)
                if let station = selection.station {
                    Text("\(selection.caption) · \(station.borough)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview("Edit Widget") {
    let store = WidgetStore()
    NavigationStack {
        WidgetEditor(id: store.saved.widgets.first?.id ?? SavedWidget.firstID)
    }
    .environment(store)
    .environment(SettingsStore())
}

#Preview("Large Transfers") {
    // The R from Prospect Av, changing at Atlantic Av-Barclays Ctr to the D or N
    var widget = SavedWidget(selection: .fallback)
    widget.change = TrainEntry.transferPreview().change
    return Form {
        WidgetHeader(widget: widget, look: .constant(.largeTransfers))
    }
    .environment(SettingsStore())
}

#Preview {
    WidgetsView()
        .environment(WidgetStore())
        .environment(SettingsStore())
}
