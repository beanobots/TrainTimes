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

/// The Settings tab: the default train, which alerts every widget mentions, and accessibility.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var store
    @Environment(WidgetStore.self) private var widgets
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var choosingDefaultTrain = false

    /// Saved widgets with elevator alerts off whose platforms do have elevators.
    private var widgetsWithoutElevators: [SavedWidget] {
        widgets.saved.widgets.filter { widget in
            !widget.selection.elevatorAlerts && EquipmentDirectory.hasEquipment(serving: widget.selection.platforms)
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    Button {
                        choosingDefaultTrain = true
                    } label: {
                        TrainChoiceRow(selection: store.defaultTrain)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Choose another station, line or direction")
                    // On the button, not the Section, which would apply it to each row
                    .sheet(isPresented: $choosingDefaultTrain) {
                        TrainPicker(selection: $store.defaultTrain)
                    }
                } header: {
                    Text("Default Train")
                } footer: {
                    Text("Siri, the countdown, Favorite Stop and widgets with no widget picked in Edit Widget show this train.")
                }

                Section {
                    ForEach(ServiceAlert.Kind.allCases, id: \.self) { kind in
                        Toggle(isOn: alertKind(kind)) {
                            Label {
                                Text(kind.settingsLabel)
                            } icon: {
                                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                            }
                        }
                    }
                } header: {
                    Text("Alerts")
                }

                Section {
                    Toggle(isOn: $store.settings.stepFree) {
                        Text("Step-free mode")
                        Text("Marks stations and platforms without step-free access when you choose a train.")
                    }
                    if store.settings.stepFree && !widgetsWithoutElevators.isEmpty {
                        Button("Show Elevator Outages on Every Widget", systemImage: "figure.roll") {
                            for var widget in widgetsWithoutElevators {
                                widget.selection.elevatorAlerts = true
                                widgets.update(widget)
                            }
                        }
                    }
                    Toggle(isOn: withoutColor ? .constant(true) : $store.settings.marksLiveTimes) {
                        Text("Mark live times")
                        // VoiceOver reads the mark as "Live", like the widgets
                        Text(withoutColor
                             ? "On while Differentiate Without Color is on in the Settings app."
                             : "Live predictions get \(Image(systemName: LiveMark.symbol)) as well as their green.")
                            .accessibilityLabel(withoutColor
                                                ? "On while Differentiate Without Color is on in the Settings app."
                                                : "Live predictions are marked Live as well as green.")
                    }
                    .disabled(withoutColor)
                    Toggle(isOn: $store.settings.marksScheduledTimes) {
                        Text("Mark scheduled times")
                        Text("Timetable times get \(Image(systemName: ScheduledMark.symbol)), so they stand out from live predictions.")
                            .accessibilityLabel("Timetable times are marked Scheduled, so they stand out from live predictions.")
                    }
                } header: {
                    Text("Accessibility")
                }

                Section {
                    Toggle(isOn: $store.settings.includesBuses) {
                        Text("Include buses")
                        Text("Trips can take a bus as well as the subway, with live times from MTA Bus Time.")
                    }
                } header: {
                    Text("New Trip")
                }

                Section {
                    Picker("Stop card", selection: $store.settings.favoriteCard) {
                        ForEach(FavoriteCardStyle.allCases, id: \.self) { style in
                            Text(style.name)
                        }
                    }
                } header: {
                    Text("Widgets")
                } footer: {
                    Text("How Magic Widget shows your Favorite Stop, and Next train and Transfers show theirs. Tap one for the next trains.")
                }
            }
            // A large title that shrinks into the glass bar on scroll
            .navigationTitle("Settings")
        }
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

#Preview {
    SettingsView()
        .environment(SettingsStore())
        .environment(WidgetStore())
}
