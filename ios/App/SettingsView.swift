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
            if settings.favoriteCard != oldValue.favoriteCard || settings.defaultTrain != oldValue.defaultTrain
                || settings.defaultBothWays != oldValue.defaultBothWays {
                WidgetCenter.shared.reloadTrainWidgets()
            }
            if read != oldValue {
                WidgetCenter.shared.reloadTrainWidgets()
                WidgetCenter.shared.reloadTimelines(ofKind: Nearby.widgetKind)
            }
            // Alert changes need a refetch; mark changes just redraw, no network
            if settings.alertKinds != oldValue.alertKinds {
                Task { await TrainActivityController.refresh() }
            } else if settings.marksLiveTimes != oldValue.marksLiveTimes
                        || settings.marksScheduledTimes != oldValue.marksScheduledTimes {
                Task { await TrainActivityController.redraw() }
            }
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

    /// Which times get a symbol; live ones always do with Differentiate Without Color.
    func timeMarks(withoutColor: Bool) -> TimeMarks {
        settings.timeMarks(withoutColor: withoutColor)
    }
}

/// The Settings tab, in New Trip's look: a plain page under its title, faint rounded cards. The
/// home station, walking and biking, accessibility, which alerts every widget mentions as icon
/// toggles, diagnostics and the data sources.
struct SettingsView: View {
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
        ScrollView {
            VStack(spacing: 8) {
                Text("Settings")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)

                cardLabel("Home Station")
                homeStation
                    .padding(.bottom, 14)

                cardLabel("Walking", symbol: "figure.walk")
                walking
                    .padding(.bottom, 14)

                cardLabel("Biking", symbol: "bicycle")
                biking
                    .padding(.bottom, 14)

                cardLabel("Accessibility")
                accessibility
                    .padding(.bottom, 14)

                cardLabel("Alerts")
                alertToggles
                    .padding(.bottom, 14)

                cardLabel("Diagnostics")
                diagnostics
                    .padding(.bottom, 14)

                cardLabel("Data Sources")
                dataSources
            }
            .padding(.horizontal, Self.margin)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    /// A small label over a card, as New Trip's "Depart from", with its icon before it if it
    /// has one.
    private func cardLabel(_ title: String, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// The default train as a faint card, as the others; a tap picks another.
    private var homeStation: some View {
        @Bindable var store = store
        let selection = store.defaultTrain
        return Button {
            choosingDefaultTrain = true
        } label: {
            HStack(spacing: 12) {
                LineBullets(routes: selection.routes, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selection.station?.name ?? "Choose a Train").font(.headline)
                    if selection.station != nil {
                        Text(store.settings.defaultBothWays ? "Both ways" : "Toward \(selection.heading)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: Circle())
            }
            .padding(Self.margin)
            .contentShape(Self.card)
        }
        .buttonStyle(.plain)
        .background(Self.faint, in: Self.card)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose another station, line or direction")
        .sheet(isPresented: $choosingDefaultTrain) {
            TrainPicker(selection: $store.defaultTrain, bothWays: $store.settings.defaultBothWays)
        }
    }

    /// Safety, unlabelled: how much longer a safer walk may take (`WalkRouting`). Comfortable Walk: how far
    /// New Trip's rides may have you walk to and from them, a pick of its `walkChoices`.
    private var walking: some View {
        VStack(spacing: 0) {
            // Safest first; VoiceOver reads it as Safety
            Picker("Safety", selection: $walkPreference) {
                ForEach(WalkPreference.allCases.reversed(), id: \.self) { preference in
                    Text(preference.name).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Self.margin)
            .padding(.vertical, 12)
            Divider().padding(.leading, Self.margin)
            HStack(spacing: 12) {
                Text("Comfortable Walk")
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                // The button shows just the time; the menu each choice's distance too
                Menu {
                    Picker("Comfortable Walk", selection: $walkMinutes) {
                        ForEach(NewTripView.walkChoices, id: \.minutes) { choice in
                            Text("\(NewTripView.walkLabel(choice.minutes)) · \(choice.miles)").tag(choice.minutes)
                        }
                    }
                } label: {
                    menuLabel(NewTripView.walkLabel(walkMinutes))
                }
                .accessibilityLabel("Comfortable Walk")
                .accessibilityValue(NewTripView.walkLabel(walkMinutes))
            }
            .padding(.horizontal, Self.margin)
            .frame(minHeight: 52)
        }
        .background(Self.faint, in: Self.card)
    }

    /// Bikes: which Citi Bikes New Trip rides and Nearby counts (`BikeKinds`; neither is
    /// `BikeKinds.offKey`), and your own bike or e-bike, or neither (`OwnBike`), which New Trip
    /// rides in their place. With your own, With Transit: what it does on a trip with a train
    /// (`BikeCarry`). With none at all, a warning that New Trip won't offer biking.
    private var biking: some View {
        VStack(spacing: 0) {
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
            if citiBikeOff && ownBike == .none {
                Divider().padding(.leading, 52)
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
            if ownBike != .none {
                Divider().padding(.leading, 52)
                HStack(spacing: 12) {
                    // A plus before the train: the bike, and transit with it
                    HStack(spacing: 1) {
                        Image(systemName: "plus").font(.caption.weight(.bold))
                        Image(systemName: "tram.fill")
                    }
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                    Text("With Transit")
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    Menu {
                        Picker("With Transit", selection: $bikeCarry) {
                            ForEach(BikeCarry.allCases, id: \.self) { carry in
                                Text(carry.name).tag(carry)
                            }
                        }
                    } label: {
                        menuLabel(bikeCarry.name)
                    }
                    .accessibilityLabel("With Transit")
                    .accessibilityValue(bikeCarry.name)
                    .accessibilityHint("What your bike does on a trip with a train")
                }
                .padding(.horizontal, Self.margin)
                .frame(minHeight: 52)
            }
        }
        .animation(.default, value: ownBike)
        .animation(.default, value: citiBikeOff)
        .background(Self.faint, in: Self.card)
    }

    /// A menu's label: its value and the up-down chevron.
    private func menuLabel(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
                .accessibilityHidden(true)
        }
    }

    /// A bike as an icon, as the alerts are: Citi Bike blue while on for Citi Bike's, the tint for
    /// your own; a bolt on e-bikes; its name under it.
    private func bikeTile(_ name: String, electric: Bool, own: Bool, on: Binding<Bool>) -> some View {
        Button {
            on.wrappedValue.toggle()
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
                    .font(.caption2)
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
                            .font(.caption2)
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
                .accessibilityHint("Whether widgets mention these")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Self.faint, in: Self.card)
    }

    /// Step-free mode and the time marks, each a switch with its icon.
    private var accessibility: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            switchRow("Step-Free Mode", symbol: "figure.roll", tint: .accentColor, isOn: $store.settings.stepFree)
            if store.settings.stepFree && !widgetsWithoutElevators.isEmpty {
                Divider().padding(.leading, 52)
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
            Divider().padding(.leading, 52)
            // Always on while Differentiate Without Color is
            switchRow("Mark Live Times", symbol: LiveMark.symbol, tint: .liveText,
                      isOn: withoutColor ? .constant(true) : $store.settings.marksLiveTimes)
                .disabled(withoutColor)
            Divider().padding(.leading, 52)
            switchRow("Mark Scheduled Times", symbol: ScheduledMark.symbol, tint: .secondary,
                      isOn: $store.settings.marksScheduledTimes)
        }
        .background(Self.faint, in: Self.card)
    }

    /// Share Diagnostics (`Diagnostics`): off until turned on; turned off, reports not yet sent
    /// are dropped. Under it, Run Setup Again.
    private var diagnostics: some View {
        VStack(spacing: 0) {
            switchRow("Share Diagnostics", symbol: "stethoscope", tint: .accentColor, isOn: $sharesDiagnostics)
                .onChange(of: sharesDiagnostics) { _, isOn in
                    if !isOn { Diagnostics.discardPending() }
                }
            Divider().padding(.leading, 52)
            rerunSetup
        }
        .background(Self.faint, in: Self.card)
    }

    /// Where the app's data comes from, each a link to its source. OpenStreetMap's licence (the
    /// ODbL) needs its credit and a link to its copyright page, for the signals walks cross at.
    private var dataSources: some View {
        VStack(spacing: 0) {
            sourceRow("MTA", symbol: "tram.fill",
                      url: "https://new.mta.info/developers")
            Divider().padding(.leading, 52)
            sourceRow("New York State Open Data", symbol: "stairs", url: "https://data.ny.gov")
            Divider().padding(.leading, 52)
            sourceRow("NYC Open Data", symbol: "figure.walk",
                      url: "https://opendata.cityofnewyork.us")
            Divider().padding(.leading, 52)
            sourceRow("OpenStreetMap", symbol: "light.beacon.max.fill",
                      credit: "© OpenStreetMap contributors",
                      url: "https://www.openstreetmap.org/copyright")
            Divider().padding(.leading, 52)
            sourceRow("Citi Bike", symbol: "bicycle", url: "https://citibikenyc.com/system-data")
        }
        .background(Self.faint, in: Self.card)
    }

    /// A source's row: its icon, name and any credit its licence needs, opening its page.
    private func sourceRow(_ name: String, symbol: String, credit: String? = nil, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    if let credit {
                        Text(credit).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Self.margin)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityHint("Opens its website")
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

    /// A 52 pt row with its icon and a switch, as New Trip's From and To rows.
    private func switchRow(_ title: String, symbol: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
            }
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
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
