import Observation
import SwiftUI
import WidgetKit

/// The app's Settings, shared by its tabs. Every change is saved for the
/// widgets and the countdown to read, and they redraw with it.
@MainActor @Observable
final class SettingsStore {
    var settings = SharedStore.loadSettings() {
        didSet {
            guard settings != oldValue else { return }
            SharedStore.saveSettings(settings)
            WidgetCenter.shared.reloadAllTimelines()
            // The countdown's alert changes only with new times; its live and
            // scheduled marks are redrawn at once, without waiting on the network
            if settings.alertKinds != oldValue.alertKinds {
                Task { await TrainActivityController.refresh() }
            } else if settings.marksLiveTimes != oldValue.marksLiveTimes
                        || settings.marksScheduledTimes != oldValue.marksScheduledTimes {
                Task { await TrainActivityController.redraw() }
            }
        }
    }

    /// Whether live times get their symbol: as chosen here, or always with the
    /// phone's Differentiate Without Color.
    func marksLive(withoutColor: Bool) -> Bool {
        withoutColor || settings.marksLiveTimes
    }
}

/// The Settings tab: which alerts every widget mentions, and accessibility.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var store
    @Environment(WidgetStore.self) private var widgets
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    /// Saved widgets at stations with elevators that don't mention their outages.
    private var widgetsWithoutElevators: [SavedWidget] {
        widgets.saved.widgets.filter { widget in
            guard let station = widget.selection.station else { return false }
            return !widget.selection.elevatorAlerts && EquipmentDirectory.hasEquipment(atComplex: station.complex)
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
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
                    Toggle(isOn: $store.settings.largerWidgetText) {
                        Text("Larger widget text")
                        Text("A bigger countdown on the small widget, without the train after it. The medium widget uses its larger layout on every iPhone.")
                    }
                    Toggle(isOn: withoutColor ? .constant(true) : $store.settings.marksLiveTimes) {
                        Text("Mark live times")
                        Text(withoutColor
                             ? "On while Differentiate Without Color is on in the Settings app."
                             : "Live predictions get \(Image(systemName: "dot.radiowaves.up.forward")) as well as their green.")
                    }
                    .disabled(withoutColor)
                    Toggle(isOn: $store.settings.marksScheduledTimes) {
                        Text("Mark scheduled times")
                        Text("Timetable times get \(Image(systemName: "clock")), so they stand out from live predictions.")
                    }
                } header: {
                    Text("Accessibility")
                }
            }
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
