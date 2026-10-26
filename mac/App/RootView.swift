import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case logs = "Logs"
    case configuration = "Configuration"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .logs: "doc.text.magnifyingglass"
        case .configuration: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @Environment(ServerModel.self) private var model
    @State private var section: SidebarItem? = .overview
    @State private var showingRebuild = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { section in
                Label(section.rawValue, systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            switch section ?? .overview {
            case .overview: OverviewView(editTiming: { section = .configuration })
            case .logs: LogsView()
            case .configuration: ConfigurationView()
            }
        }
        .navigationTitle((section ?? .overview).rawValue)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let activity = model.activity {
                    ProgressView().controlSize(.small)
                    Text(activity).foregroundStyle(.secondary)
                }
                if model.status?.isLoaded == true {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
                        .help("Stop the server (launchctl bootout)")
                } else {
                    Button("Start", systemImage: "play.fill") { Task { await model.start() } }
                        .help("Start the server (launchctl bootstrap)")
                        .disabled(model.status == nil)
                }
                Button("Restart", systemImage: "arrow.clockwise") { Task { await model.restart() } }
                    .help("Restart the server (launchctl kickstart -k)")
                    .disabled(model.status?.isLoaded != true)
                Button("Rebuild…", systemImage: "hammer") { showingRebuild = true }
                    .help("Build from the files on disk and install")
            }
        }
        .disabled(model.activity != nil)
        .sheet(isPresented: $showingRebuild) { RebuildSheet() }
        .alert("Couldn't do that", isPresented: Binding(get: { model.actionError != nil },
                                                        set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .task { await model.run() }
    }

    private var sidebarStatus: some View {
        HStack(spacing: 6) {
            StatusDot(color: daemonColor)
            Text(daemonSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }

    private var daemonColor: Color {
        guard let status = model.status else { return .gray }
        return status.isRunning ? .green : status.isLoaded ? .orange : .red
    }

    private var daemonSummary: String {
        guard let status = model.status else { return "Checking…" }
        if status.isRunning { return "Running" }
        return status.isLoaded ? (status.state?.capitalized ?? "Loaded") : "Stopped"
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}
