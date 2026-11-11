import SwiftUI

/// The secret Prototyping card's tools (Settings, shown by tapping its tab 5 times quickly):
/// each opens as a sheet of its own. Pretend Time, Pretend Location, Force Offline and the map
/// overlays last for this run of the app only; Voice's choices are kept.
enum PrototypeTool: String, CaseIterable, Identifiable {
    case voice, voiceMixer, pretendTime, pretendLocation, forceOffline, liveActivity, lockScreen, diagnostics, clearCaches, mapOverlays

    var id: Self { self }

    var title: String {
        switch self {
        case .voice: "Voice"
        case .voiceMixer: "Voice Mixer"
        case .pretendTime: "Pretend Time"
        case .pretendLocation: "Pretend Location"
        case .forceOffline: "Force Offline"
        case .liveActivity: "Test Live Activity"
        case .lockScreen: "Test Lock Screen"
        case .diagnostics: "Diagnostics Tools"
        case .clearCaches: "Clear Caches"
        case .mapOverlays: "Map Overlays"
        }
    }

    var symbol: String {
        switch self {
        case .voice: "waveform"
        case .voiceMixer: "slider.horizontal.3"
        case .pretendTime: "clock.arrow.2.circlepath"
        case .pretendLocation: "location.viewfinder"
        case .forceOffline: "wifi.slash"
        case .liveActivity: "platter.filled.top.iphone"
        case .lockScreen: "lock.iphone"
        case .diagnostics: "doc.text.magnifyingglass"
        case .clearCaches: "trash"
        case .mapOverlays: "square.3.layers.3d"
        }
    }

    /// What it has on, on its row: "Sun 8:00 AM"; nil with nothing on.
    @MainActor var status: String? {
        switch self {
        case .pretendTime: PretendTime.shared.status
        default: nil
        }
    }

    /// The tool's page, in its sheet's navigation stack.
    @ViewBuilder @MainActor var page: some View {
        switch self {
        case .voice: VoiceTool()
        case .voiceMixer: VoiceMixerTool()
        case .pretendTime: PretendTimeTool()
        case .pretendLocation: PretendLocationTool()
        case .forceOffline: ForceOfflineTool()
        case .liveActivity: LiveActivityTool()
        case .lockScreen: LockScreenTool()
        case .diagnostics: DiagnosticsTool()
        case .clearCaches: ClearCachesTool()
        case .mapOverlays: MapOverlaysTool()
        }
    }
}

/// A tool's sheet: its page under its title, with Done.
struct PrototypeSheet: View {
    let tool: PrototypeTool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            tool.page
                .navigationTitle(tool.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
