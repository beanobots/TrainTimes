import Observation
import SwiftUI
import WidgetKit

/// The app's Settings, shared by its tabs. Changes are saved and the widgets and countdown redraw.
@MainActor @Observable
final class SettingsStore {
    var settings = SharedStore.loadSettings() {
        didSet {
            guard settings != oldValue else { return }
            SharedStore.saveSettings(settings)
            // Reload only if widgets read what changed: none read step-free mode or New Trip's
            // buses, and Nearby reads neither the stop card's style nor the default train, either way
            var read = settings
            read.stepFree = oldValue.stepFree
            read.includesBuses = oldValue.includesBuses
            read.favoriteCard = oldValue.favoriteCard
            read.defaultTrain = oldValue.defaultTrain
            read.defaultBothWays = oldValue.defaultBothWays
            read.defaultBus = oldValue.defaultBus
            // Only Citi Bike and Nearby show docks
            read.bikeKinds = oldValue.bikeKinds
            // Reloaded a moment on (`alertsChanged`)
            read.alertKinds = oldValue.alertKinds
            if settings.defaultBus != oldValue.defaultBus {
                Task { await SpotlightBusStop.indexHome() }
            }
            if settings.bikeKinds != oldValue.bikeKinds {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.citiBike)
            }
            // Each once, however many of what they read changed
            if read != oldValue || settings.favoriteCard != oldValue.favoriteCard
                || settings.defaultTrain != oldValue.defaultTrain
                || settings.defaultBothWays != oldValue.defaultBothWays || settings.defaultBus != oldValue.defaultBus {
                WidgetCenter.shared.reloadTrainWidgets()
            }
            if read != oldValue || settings.bikeKinds != oldValue.bikeKinds {
                WidgetCenter.shared.reloadTimelines(ofKind: Nearby.widgetKind)
            }
            // Alert changes need a refetch; mark changes just redraw, no network
            if settings.alertKinds != oldValue.alertKinds {
                alertsChanged()
            } else if settings.marksLiveTimes != oldValue.marksLiveTimes
                        || settings.marksScheduledTimes != oldValue.marksScheduledTimes {
                Task { await TrainActivityController.redraw() }
            }
        }
    }

    @ObservationIgnored private var reloadingAlerts: Task<Void, Never>?

    /// Widgets and the countdown, with their alerts fetched again, a second after the last of
    /// several alert kinds toggled in a row, not for each.
    private func alertsChanged() {
        reloadingAlerts?.cancel()
        reloadingAlerts = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTrainWidgets()
            WidgetCenter.shared.reloadTimelines(ofKind: Nearby.widgetKind)
            // Not cancelled by a toggle after it's begun
            Task { await TrainActivityController.refresh() }
        }
    }

    /// The station, lines and direction Siri, the countdown, Favorite Stop and widgets that pick
    /// no saved widget use; see `SharedStore.defaultTrain`.
    var defaultTrain: Selection {
        get { settings.defaultTrain?.validatedIfKnown() ?? savedSelection }
        set { settings.defaultTrain = newValue }
    }

    /// The selection saved by older versions, read once: Settings reads `defaultTrain` as it
    /// redraws, and nothing writes the file now.
    @ObservationIgnored private lazy var savedSelection = SharedStore.load()
    @ObservationIgnored private lazy var hasSavedSelection = SharedStore.hasSavedSelection

    /// No default train, nor one older versions saved, as setup's No Primary Stop leaves it:
    /// `defaultTrain` is then only `Selection.fallback`, which Siri and new widgets still use.
    var hasNoStop: Bool { settings.defaultTrain == nil && settings.defaultBus == nil && !hasSavedSelection }

    /// Copies the app's Citi Bike kinds (Settings → Biking) for the widgets to read.
    func shareBikeKinds() {
        let kinds = UserDefaults.standard.string(forKey: BikeKinds.key).flatMap(BikeKinds.init(rawValue:)) ?? BikeKinds.saved
        if settings.bikeKinds != kinds.shared { settings.bikeKinds = kinds.shared }
    }

    /// Which times get a symbol; live ones always do with Differentiate Without Color.
    func timeMarks(withoutColor: Bool) -> TimeMarks {
        settings.timeMarks(withoutColor: withoutColor)
    }
}

/// The Settings tab, in New Trip's look: a plain page under its title, one faint rounded card with
/// no headings or lines, its settings spaced apart, each an icon and title with any note under the
/// title's words: the home station or stop, Grid North, walk safety and comfortable walk, Biking,
/// step-free and time marks, Transit Alerts (which alerts every widget mentions) as icon toggles,
/// and diagnostics. The data sources are a credit line under it.
struct SettingsView: View {
    /// The secret Prototyping card, shown by tapping the Settings tab 5 times quickly (`AppTabs`).
    var showsPrototyping = false
    @Environment(SettingsStore.self) private var store
    @Environment(WidgetStore.self) private var widgets
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var choosingDefaultTrain = false
    @AppStorage(AppTabs.firstRunDoneKey) private var firstRunDone = false
    @AppStorage(WalkRouting.preferenceKey) private var walkPreference = WalkPreference.balanced
    @AppStorage(Diagnostics.sharesKey) private var sharesDiagnostics = false
    @AppStorage(NewTripView.walkMinutesKey) private var walkMinutes = NewTripView.defaultWalkMinutes
    @AppStorage(BikeKinds.key) private var bikeKinds = BikeKinds.saved
    @AppStorage(OwnBike.key) private var ownBike = OwnBike.none
    @AppStorage(BikeCarry.key) private var bikeCarry = BikeCarry.all
    @AppStorage(BikeKinds.offKey) private var citiBikeOff = false
    /// The no-bikes warning and With Transit, unrolled or not, and the bike With Transit's for, kept
    /// in step with the settings in an animation: a change to `@AppStorage` drops the one it was
    /// made in, so they'd snap open and shut.
    @State private var warnsNoBikes = false
    @State private var transitBike: OwnBike?
    @State private var lastTransitBike = OwnBike.bike
    @AppStorage(MapNorth.key) private var nyNorth = false
    /// The Prototyping tool open in its sheet.
    @State private var prototypeTool: PrototypeTool?

    /// The page's side margin and its cards' corners, as New Trip's.
    private static let margin: CGFloat = 16
    private static let card = RoundedRectangle(cornerRadius: 26, style: .continuous)
    /// Cards on the plain page: a faint fill in place of the grouped grey.
    private static let faint = Color.primary.opacity(0.05)

    /// Saved widgets with elevator alerts off whose platforms do have elevators.
    private var widgetsWithoutElevators: [SavedWidget] {
        widgets.saved.widgets.filter { widget in
            !widget.selection.elevatorAlerts && EquipmentDirectory.hasEquipment(serving: widget.selection.platforms)
        }
    }

    var body: some View {
        settingsPage
            // On its side, a card down the left over the map, as Nearby's
            .sidewaysCard()
            // For the Citi Bike and Nearby widgets, which can't read the app's own defaults
            .onChange(of: bikeKinds) { store.shareBikeKinds() }
            .onChange(of: citiBikeOff && ownBike == .none, initial: true) { old, none in
                withAnimation(old == none ? nil : .smooth(duration: 0.3)) { warnsNoBikes = none }
            }
            .onChange(of: ownBike, initial: true) { old, bike in
                if bike != .none { lastTransitBike = bike }
                withAnimation(old == bike ? nil : .smooth(duration: 0.3)) {
                    transitBike = bike == .none ? nil : bike
                }
            }
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Settings")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)

                // Room between settings, so each reads as its own
                VStack(spacing: 14) {
                    homeStation
                    gridNorth
                    walkSafety
                    comfortableWalk
                    biking
                    accessibility
                    alertToggles
                    diagnostics
                }
                .padding(.vertical, 6)
                .background(Self.faint, in: Self.card)

                dataSources
                    .padding(.top, 8)

                if showsPrototyping {
                    Label("Prototyping", systemImage: "hammer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                        .accessibilityAddTraits(.isHeader)
                    prototyping
                }
            }
            .padding(.horizontal, Self.margin)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    /// The home stop under its title: the default train, or its bus when it's one; a tap picks
    /// another (`HomeStopPicker`). Or, with none chosen, No Primary Stop and the train used meanwhile.
    private var homeStation: some View {
        @Bindable var store = store
        let selection = store.defaultTrain
        return Button {
            choosingDefaultTrain = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
            rowTitle("Home Station or Stop", symbol: "house.fill")
            HStack(spacing: 12) {
                if store.hasNoStop {
                    Image(systemName: "mappin.slash")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(.quaternary, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No Primary Stop").font(.headline)
                        Text("Widgets use \(selection.station?.name ?? "14 St-Union Sq") until you pick one")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(2)
                } else if let bus = store.settings.defaultBus {
                    HStack(spacing: 2) {
                        ForEach(bus.allLines.prefix(3), id: \.self) { BusBadge(line: $0, size: bus.allLines.count > 1 ? 28 : 32) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bus.stopName).font(.headline)
                        Text(bus.bothWays && bus.otherStop != nil ? "Both ways" : "Toward \(bus.shortWayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                } else {
                    LineBullets(routes: selection.routes, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selection.station?.name ?? "Choose a Train").font(.headline)
                        if selection.station != nil {
                            Text(store.settings.defaultBothWays ? "Both ways" : "Toward \(selection.heading)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: Circle())
                    .accessibilityHidden(true)
            }
            // Under the title's words, as the notes are
            .padding(.leading, 36)
            }
            .padding(Self.margin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(store.hasNoStop ? "Choose a station or bus stop, and its direction"
                                           : "Choose another station or bus stop, or direction")
        .sheet(isPresented: $choosingDefaultTrain) {
            HomeStopPicker(train: $store.defaultTrain, bothWays: $store.settings.defaultBothWays,
                           bus: $store.settings.defaultBus) { train, bothWays in
                // One save, so the widgets reload (and Spotlight indexes) once
                var settings = store.settings
                settings.defaultTrain = train
                settings.defaultBothWays = bothWays
                settings.defaultBus = nil
                store.settings = settings
            }
        }
    }

    /// Grid North: every map turned the grid's 29°, Manhattan's avenues up it (`MapNorth`), with
    /// the island as its icon (`ManhattanIcon`). Speaking and vibrating on walks are the walking
    /// map's sound button (`WalkSound`), not here.
    private var gridNorth: some View {
        switchRow("Grid North", detail: nyNorth ? "Compass shows Uptown as North" : "Compass uses true North",
                  isOn: $nyNorth) {
            ManhattanIcon()
                .fill(.tint)
                .frame(width: 13, height: 32)
        }
    }

    /// Walk Safety: how much longer a safer walk may take (`WalkRouting`), safest first, with what
    /// the one picked does under it.
    private var walkSafety: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowTitle("Walk Safety", symbol: "figure.walk")
            Picker("Walk Safety", selection: $walkPreference) {
                ForEach(WalkPreference.allCases.reversed(), id: \.self) { preference in
                    Text(preference.name).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            note(walkPreference.note)
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 12)
    }

    /// Comfortable Walk: how far New Trip's rides may have you walk to and from them (`WalkSlider`).
    private var comfortableWalk: some View {
        VStack(alignment: .leading, spacing: 6) {
            WalkSlider(minutes: $walkMinutes)
            note("Longest walk to or from a train, bus or bike. Walking the whole way is always offered.")
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 12)
    }

    /// What a setting does, under it, lined up with the titles' words rather than their icons.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 36)
    }

    /// A row of icon toggles under its title, as Walk Safety's.
    private func titled(_ title: String, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rowTitle(title, symbol: symbol)
                .padding(.horizontal, Self.margin)
                .padding(.top, 10)
            content()
        }
    }

    /// A setting's title over its control, its icon as the switch rows'.
    private func rowTitle(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title).fontWeight(.medium)
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// Bikes: which Citi Bikes New Trip rides and Nearby counts (`BikeKinds`; neither is
    /// `BikeKinds.offKey`), and your own bike or e-bike, or neither (`OwnBike`), which New Trip
    /// rides in their place. With your own, With Transit: what it does on a trip with a train
    /// (`BikeCarry`). With none at all, a warning that New Trip won't offer biking.
    private var biking: some View {
        VStack(spacing: 0) {
            titled("Biking", symbol: "bicycle") {
                HStack(alignment: .top, spacing: 8) {
                    bikeTile("Citi Bike", electric: false, own: false, on: citiBike(.bike))
                    bikeTile("Citi E-Bike", electric: true, own: false, on: citiBike(.eBike))
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1, height: 44)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    bikeTile("My Bike", electric: false, own: true, on: myBike(.bike))
                    bikeTile("My E-Bike", electric: true, own: true, on: myBike(.eBike))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            // Both always there, each unrolling down from the tiles as it's needed (`Unroll`)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text("Biking won’t be shown in New Trip. Add at least one of the above to include it again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Self.margin)
                .padding(.vertical, 10)
                .frame(minHeight: 52)
                .accessibilityElement(children: .combine)
            }
            .modifier(Unroll(shown: warnsNoBikes))
            withTransit
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .modifier(Unroll(shown: transitBike != nil))
        }
    }

    /// Your own bike on a trip with a train (`BikeCarry`), as two switches in a panel of your bike's
    /// tint, so they read as its and not Citi Bike's: taken on the train, and locked at the station.
    /// Both on is any of these; both off, rides without a train only.
    private var withTransit: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bicycle")
                    .accessibilityHidden(true)
                // Your bike kept as it rolls up, its name not changing on the way
                Text((transitBike ?? lastTransitBike) == .eBike ? "My E-Bike with Transit" : "My Bike with Transit")
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
            switchRow("Take it on the train", symbol: "tram.fill", tint: .accentColor, isOn: carries(bring: true))
                .padding(.horizontal, -4)
            Divider().padding(.leading, 48)
            switchRow("Lock it up, then ride", symbol: "lock.fill", tint: .accentColor, isOn: carries(bring: false))
                .padding(.horizontal, -4)
        }
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Whether your bike's taken on the train (`bring`), or locked at the station, the other kept.
    private func carries(bring: Bool) -> Binding<Bool> {
        Binding {
            bring ? bikeCarry.brings : bikeCarry.leaves
        } set: { isOn in
            let brings = bring ? isOn : bikeCarry.brings
            let leaves = bring ? bikeCarry.leaves : isOn
            bikeCarry = brings && leaves ? .all : brings ? .bring : leaves ? .leave : .none
        }
    }

    /// A bike as an icon, as the alerts are: Citi Bike blue while on for Citi Bike's, the tint for
    /// your own; a bolt on e-bikes; its name under it.
    private func bikeTile(_ name: String, electric: Bool, own: Bool, on: Binding<Bool>) -> some View {
        Button {
            // Animated at the source so the cards below slide with the one that grows
            withAnimation(.smooth(duration: 0.3)) { on.wrappedValue.toggle() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "bicycle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(on.wrappedValue ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 48, height: 38)
                    .background(on.wrappedValue ? (own ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.citiBike))
                                                : AnyShapeStyle(.quaternary), in: Capsule())
                    .eBikeBadge(electric)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(on.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(on.wrappedValue ? [.isToggle, .isSelected] : .isToggle)
        .accessibilityHint(own ? "Whether New Trip rides your own" : "Whether New Trip and Nearby count these")
    }

    /// Whether Citi Bike's `kind` is counted. Turning the last one off turns Citi Bike off
    /// (`citiBikeOff`), the kinds kept as they were; turning one on again picks just it.
    private func citiBike(_ kind: CitiBike.Kind) -> Binding<Bool> {
        Binding {
            !citiBikeOff && (bikeKinds == .both || bikeKinds.kinds == [kind])
        } set: { isOn in
            let this: BikeKinds = kind == .bike ? .bike : .eBike
            let other: BikeKinds = kind == .bike ? .eBike : .bike
            if isOn {
                bikeKinds = citiBikeOff ? this : bikeKinds == other ? .both : bikeKinds
                citiBikeOff = false
            } else if bikeKinds == .both {
                bikeKinds = other
            } else {
                citiBikeOff = true
            }
        }
    }

    /// Whether your own bike is `kind`: one or the other, or neither.
    private func myBike(_ kind: OwnBike) -> Binding<Bool> {
        Binding {
            ownBike == kind
        } set: { isOn in
            ownBike = isOn ? kind : .none
        }
    }

    /// Each kind of alert an icon, tinted in its colour while widgets mention it, as New Trip's
    /// Subway and Bus; its name under it.
    private var alertToggles: some View {
        titled("Transit Alerts", symbol: "bell.badge.fill") {
            HStack(alignment: .top, spacing: 8) {
                ForEach(ServiceAlert.Kind.allCases, id: \.self) { kind in
                    let on = alertKind(kind)
                    Button {
                        on.wrappedValue.toggle()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(on.wrappedValue ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                                .frame(width: 48, height: 38)
                                .background(on.wrappedValue ? AnyShapeStyle(kind.tint) : AnyShapeStyle(.quaternary),
                                            in: Capsule())
                            Text(kind.shortLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(kind.settingsLabel)
                    .accessibilityValue(on.wrappedValue ? "On" : "Off")
                    .accessibilityAddTraits(on.wrappedValue ? [.isToggle, .isSelected] : .isToggle)
                    .accessibilityHint("Whether widgets mention these")
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
    }

    /// Step-free mode and the time marks, each a switch with its icon.
    private var accessibility: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            switchRow("Step-Free Mode", symbol: "figure.roll", tint: .accentColor, isOn: $store.settings.stepFree)
            if store.settings.stepFree && !widgetsWithoutElevators.isEmpty {
                Button {
                    for var widget in widgetsWithoutElevators {
                        widget.selection.elevatorAlerts = true
                        widgets.update(widget)
                    }
                } label: {
                    Text("Show Elevator Outages on Every Widget")
                        .padding(.leading, 52 - Self.margin)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, Self.margin)
                        .contentShape(Rectangle())
                }
            }
            // Always on while Differentiate Without Color is
            switchRow("Mark Live Times", symbol: LiveMark.symbol, tint: .liveText,
                      isOn: withoutColor ? .constant(true) : $store.settings.marksLiveTimes)
                .disabled(withoutColor)
            switchRow("Mark Scheduled Times", symbol: ScheduledMark.symbol, tint: .secondary,
                      isOn: $store.settings.marksScheduledTimes)
        }
    }

    /// Share Diagnostics (`Diagnostics`): off until turned on; turned off, reports not yet sent
    /// are dropped.
    private var diagnostics: some View {
        switchRow("Share Diagnostics", symbol: "stethoscope", tint: .accentColor, isOn: $sharesDiagnostics)
            .onChange(of: sharesDiagnostics) { _, isOn in
                if !isOn { Diagnostics.discardPending() }
            }
    }

    /// Tools for trying the app out, hidden till unlocked (`PrototypeTool`), each a sheet; then
    /// Run Setup Again.
    private var prototyping: some View {
        VStack(spacing: 0) {
            ForEach(PrototypeTool.allCases) { tool in
                Button {
                    prototypeTool = tool
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: tool.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(tool.title)
                        Spacer(minLength: 0)
                        if let status = tool.status {
                            Text(status).font(.subheadline).foregroundStyle(.orange).lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.horizontal, Self.margin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 52)
            }
            rerunSetup
        }
        .background(Self.faint, in: Self.card)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .sheet(item: $prototypeTool) { PrototypeSheet(tool: $0) }
    }

    /// Where the app's data comes from, a line under the card, each name a link to its source.
    /// OpenStreetMap's licence (the ODbL) needs its credit and a link to its copyright page, for
    /// the signals walks cross at.
    private var dataSources: some View {
        Text("Data from [MTA](https://new.mta.info/developers), [New York State](https://data.ny.gov) and [NYC Open Data](https://opendata.cityofnewyork.us), [Citi Bike](https://citibikenyc.com/system-data) and [© OpenStreetMap contributors](https://www.openstreetmap.org/copyright)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    /// Shows first-run setup again (AppTabs puts it up once `firstRunDone` clears). Saved places
    /// are cleared for it; the rest stays, setup's answers saving over it.
    private var rerunSetup: some View {
        Button {
            firstRunDone = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Run Setup Again")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, Self.margin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A 56 pt row with its icon and a switch, as New Trip's From and To rows.
    private func switchRow(_ title: String, detail: String? = nil, symbol: String, tint: Color,
                           isOn: Binding<Bool>) -> some View {
        switchRow(title, detail: detail, isOn: isOn) {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    /// A switch row with its own icon.
    private func switchRow(_ title: String, detail: String? = nil, isOn: Binding<Bool>,
                           @ViewBuilder icon: () -> some View) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                icon()
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                }
            }
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
    }

    /// Whether widgets mention this kind of alert.
    private func alertKind(_ kind: ServiceAlert.Kind) -> Binding<Bool> {
        Binding {
            store.settings.alertKinds.contains(kind)
        } set: { isOn in
            if isOn {
                store.settings.alertKinds.insert(kind)
            } else {
                store.settings.alertKinds.remove(kind)
            }
        }
    }
}

extension WalkPreference {
    /// What it does, under Settings' Walk Safety.
    fileprivate var note: String {
        switch self {
        case .safest: "Uses safer crossings with walk lights, avoids areas with higher crime, and avoids dark streets, even if it makes the route longer."
        case .balanced: "Prefers safer crossings and well-lit streets when it adds no more than a few minutes."
        case .fastest: "The fastest way, even if that means wider crossings and darker streets."
        }
    }

    fileprivate var name: String {
        switch self {
        case .fastest: "Fastest"
        case .balanced: "Balanced"
        case .safest: "Safest"
        }
    }
}

extension ServiceAlert.Kind {
    /// Short enough to sit under its icon in Settings; VoiceOver reads `settingsLabel`.
    fileprivate var shortLabel: String {
        switch self {
        case .delays: "Delays"
        case .suspended: "Suspensions"
        case .serviceChange: "Service Changes"
        case .notice: "Notices"
        }
    }
}

/// A part of a card that unrolls down from what's above it: always laid out at its full height,
/// shown through a window that grows from nothing, its top kept in place. Hidden, VoiceOver and
/// taps skip it. For Settings' Biking card and New Trip's change stations and docks.
struct Unroll: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: shown ? nil : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

#Preview {
    SettingsView()
        .environment(SettingsStore())
        .environment(WidgetStore())
}

#Preview("No bikes") {
    UserDefaults.standard.set(true, forKey: BikeKinds.offKey)
    UserDefaults.standard.set(OwnBike.none.rawValue, forKey: OwnBike.key)
    return SettingsView()
        .environment(SettingsStore())
        .environment(WidgetStore())
}
