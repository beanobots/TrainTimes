import SwiftUI

/// Makes the app act as if there's no signal, to try Save for Offline's timetables and alerts,
/// the phone's own trip planning, and every "couldn't be reached": each request to the push
/// server, the MTA and Citi Bike fails at once (`ForcedOffline`), and no network counts as back
/// (`Connectivity`) until it's off again. For this run of the app only.
struct ForceOfflineTool: View {
    @State private var isOn = ForcedOffline.isOn
    @State private var delay = ForcedOffline.delay

    /// The slow network's choices: how long each request waits.
    private static let delays: [Duration] = [.zero, .seconds(2), .seconds(5), .seconds(10)]

    var body: some View {
        Form {
            Section {
                Toggle("Force Offline", isOn: $isOn)
                Picker("Slow Network", selection: $delay) {
                    ForEach(Self.delays, id: \.self) { delay in
                        Text(delay == .zero ? "Off" : "\(delay.components.seconds) s Each").tag(delay)
                    }
                }
            } footer: {
                Text(isOn
                     ? "Every request fails as with no signal\(delay > .zero ? ", after the wait" : ""). Turning this off wakes the refreshes waiting for the network."
                     : delay > .zero ? "Every request waits, then goes ahead." : "The app goes online as usual.")
            }

            Section {
                Text("Apple Maps' tiles, search, addresses and bike directions, the widgets, the Lock Screen's pushed updates and the voice download aren't stopped. Off again at the next launch.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Not Stopped")
            }
        }
        .onChange(of: isOn) { Connectivity.shared.forceOffline(isOn) }
        .onChange(of: delay) { ForcedOffline.delay = delay }
    }
}

#Preview {
    NavigationStack { ForceOfflineTool() }
}
