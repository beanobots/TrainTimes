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
            // buses, and Nearby reads neither the stop card's style nor the default train
            var read = settings
            read.stepFree = oldValue.stepFree
            read.includesBuses = oldValue.includesBuses
            read.favoriteCard = oldValue.favoriteCard
            read.defaultTrain = oldValue.defaultTrain
            if settings.favoriteCard != oldValue.favoriteCard || settings.defaultTrain != oldValue.defaultTrain {
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
        get { settings.defaultTrain?.validatedIfKnown() ?? SharedStore.load() }
        set { settings.defaultTrain = newValue }
    }

    /// Which times get a symbol; live ones always do with Differentiate Without Color.
    func timeMarks(withoutColor: Bool) -> TimeMarks {
        settings.timeMarks(withoutColor: withoutColor)
    }
}

/// The Settings tab, in New Trip's look: a plain page, no title bar, faint rounded cards. The home
/// station, which alerts every widget mentions as icon toggles, and accessibility.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var store
    @Environment(WidgetStore.self) private var widgets
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var choosingDefaultTrain = false
    @AppStorage("firstRunDone") private var firstRunDone = false

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
                cardLabel("Home Station")
                homeStation
                Text("Siri, the countdown, Favorite Stop and widgets with no widget picked in Edit Widget show this train.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 14)

                cardLabel("Alerts")
                alertToggles
                    .padding(.bottom, 14)

                cardLabel("Accessibility")
                accessibility
                    .padding(.bottom, 14)

                cardLabel("Testing")
                rerunSetup
            }
            .padding(.horizontal, Self.margin)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    /// A small label over a card, as New Trip's "Depart from".
    private func cardLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// The default train as a glass card, as New Trip's From → To strip; a tap picks another.
    private var homeStation: some View {
        @Bindable var store = store
        let selection = store.defaultTrain
        return Button {
            choosingDefaultTrain = true
        } label: {
            HStack(spacing: 12) {
                LineBullets(routes: selection.routes, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selection.station?.name ?? "Choose a train").font(.headline)
                    if selection.station != nil {
                        Text("Toward \(selection.heading)")
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
        .glassEffect(.regular.interactive(), in: Self.card)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose another station, line or direction")
        .sheet(isPresented: $choosingDefaultTrain) {
            TrainPicker(selection: $store.defaultTrain)
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
            switchRow("Step-free mode", symbol: "figure.roll", tint: .accentColor, isOn: $store.settings.stepFree)
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
            switchRow("Mark live times", symbol: LiveMark.symbol, tint: .liveText,
                      detail: withoutColor ? "On while Differentiate Without Color is on in the Settings app." : nil,
                      isOn: withoutColor ? .constant(true) : $store.settings.marksLiveTimes)
                .disabled(withoutColor)
            Divider().padding(.leading, 52)
            switchRow("Mark scheduled times", symbol: ScheduledMark.symbol, tint: .secondary,
                      isOn: $store.settings.marksScheduledTimes)
        }
        .background(Self.faint, in: Self.card)
    }

    /// For testing: shows first-run setup again (AppTabs puts it up once `firstRunDone` clears).
    /// Saved places are cleared for it; the rest stays, setup's answers saving over it.
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
        .background(Self.faint, in: Self.card)
    }

    /// A 52 pt row with its icon and a switch, as New Trip's From and To rows.
    private func switchRow(_ title: String, symbol: String, tint: Color, detail: String? = nil,
                           isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
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

extension ServiceAlert.Kind {
    /// Short enough to sit under its icon in Settings; VoiceOver reads `settingsLabel`.
    fileprivate var shortLabel: String {
        switch self {
        case .delays: "Delays"
        case .suspended: "Suspensions"
        case .serviceChange: "Service changes"
        case .notice: "Notices"
        }
    }
}

#Preview {
    SettingsView()
        .environment(SettingsStore())
        .environment(WidgetStore())
}
