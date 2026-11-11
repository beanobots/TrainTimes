import MetricKit
import SwiftUI
import UIKit
import WidgetKit

/// What the app knows about itself: its build and server, the data it's downloaded, the voice
/// pack, widgets, crash and hang reports waiting to go (`Diagnostics`), and the app's log
/// (`DiagnosticLog`). Read-only but for Send Now, which sends only with Share Diagnostics on.
struct DiagnosticsTool: View {
    @State private var subway: TimetableInfo?
    @State private var buses: TimetableInfo?
    @State private var pending = 0
    @State private var metricKit = 0
    @State private var placed: [String: Int] = [:]
    @State private var sending = false
    @State private var sent: String?

    private var isSharing: Bool { Diagnostics.isSharing }

    var body: some View {
        Form {
            Section("App") {
                LabeledContent("Version", value: Diagnostics.appVersion)
                LabeledContent("System", value: Diagnostics.osVersion)
                LabeledContent("Device", value: Diagnostics.deviceModel)
                LabeledContent("Server", value: ServerRoutes.baseURL?.absoluteString ?? "None")
                LabeledContent("Share Diagnostics", value: isSharing ? "On" : "Off")
            }

            Section("Offline Data") {
                timetable("Subway Timetable", subway)
                timetable("Bus Timetable", buses)
                LabeledContent("Voice Pack", value: voicePack)
            }

            Section("Widgets") {
                LabeledContent("Saved", value: "\(SharedStore.loadWidgets().widgets.count)")
                if placed.isEmpty {
                    LabeledContent("Placed", value: "None")
                } else {
                    ForEach(placed.sorted { $0.key < $1.key }, id: \.key) { kind, count in
                        LabeledContent(Self.name(ofKind: kind), value: "\(count)")
                    }
                }
            }

            Section {
                LabeledContent("Waiting to Send", value: "\(pending)")
                LabeledContent("MetricKit, Last Day", value: "\(metricKit)")
                Button(sending ? "Sending…" : "Send Now") {
                    Task { await send() }
                }
                .disabled(!isSharing || pending == 0 || sending)
            } header: {
                Text("Crash and Hang Reports")
            } footer: {
                Text(sent ?? (isSharing
                    ? "Reports are kept until the server takes them, up to a week."
                    : "Share Diagnostics is off in Settings: nothing is kept or sent."))
            }

            Section {
                NavigationLink("App Log") { AppLogView() }
            } footer: {
                Text("The last \(DiagnosticLog.maxBytes / 1024) KB or so, kept on the phone. Sent only with a report, with Share Diagnostics on.")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func timetable(_ title: String, _ info: TimetableInfo?) -> some View {
        LabeledContent(title) {
            if let info {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Downloaded \(info.downloaded.formatted(.relative(presentation: .named)))")
                    Text(info.bytes.formatted(.byteCount(style: .file))
                         + (info.made.map { ", built \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                        .font(.caption)
                }
            } else {
                Text("None")
            }
        }
    }

    private var voicePack: String {
        guard let folder = VoicePack.folder() else { return "Not Downloaded" }
        #if DEBUG
        if folder == VoicePack.devFolder { return "Dev Copy in Documents" }
        #endif
        return "Ready"
    }

    /// A widget kind's name, as the gallery shows it.
    private static func name(ofKind kind: String) -> String {
        switch kind {
        case WidgetKind.train: "Next Train"
        case WidgetKind.transfers: "Transfers"
        case WidgetKind.directions: "Transit Directions"
        case WidgetKind.citiBike: "Citi Bike"
        case Nearby.widgetKind: "Nearby"
        default: kind
        }
    }

    private func load() async {
        pending = Self.pendingCount()
        metricKit = MXMetricManager.shared.pastDiagnosticPayloads.count
        // Read off the main thread: the subway's is a megabyte or so, parsed if not yet
        subway = await Task.detached(priority: .utility) {
            TimetableInfo(file: "timetable.bin", made: TimetableStore.subway.load()?.made)
        }.value
        // The buses' isn't read: some 15 MB
        buses = TimetableInfo(file: "bus-timetable.bin", made: nil)
        let result = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { continuation.resume(returning: $0) }
        }
        placed = ((try? result.get()) ?? []).reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    private static func pendingCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: Diagnostics.pendingDirectory.path))?.count ?? 0
    }

    /// Sends what's waiting, as at launch; never with Share Diagnostics off, where sending
    /// would throw the reports away instead (`Diagnostics.sendPending`).
    private func send() async {
        guard Diagnostics.isSharing else {
            sent = "Share Diagnostics is off: nothing sent."
            return
        }
        sending = true
        let before = Self.pendingCount()
        await Diagnostics.sendPending()
        let after = Self.pendingCount()
        sending = false
        pending = after
        sent = after == 0 ? "Sent \(before == 1 ? "the report" : "all \(before)")."
            : "\(before - after) of \(before) gone; the rest wait for the server. See the log."
    }
}

/// A downloaded timetable's file: when, how big, and when the server built it.
private struct TimetableInfo: Sendable {
    var downloaded: Date
    var bytes: Int64
    var made: Date?

    /// Nil without the file.
    init?(file: String, made: Date?) {
        guard let url = SharedStore.url(named: file),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let changed = attributes[.modificationDate] as? Date else { return nil }
        downloaded = changed
        bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        self.made = made
    }
}

/// `DiagnosticLog`'s lines, newest first, by category, to copy or share.
private struct AppLogView: View {
    @State private var lines: [Line] = []
    @State private var category: String?

    /// A line of the log: "2026-11-01T14:03:22Z notice PushServer: …".
    struct Line: Identifiable {
        let id: Int
        let text: String
        let level: String
        let category: String

        init(id: Int, _ text: String) {
            self.id = id
            self.text = text
            let words = text.split(separator: " ", maxSplits: 3)
            level = words.count > 1 ? String(words[1]) : ""
            category = words.count > 2 && words[2].hasSuffix(":") ? String(words[2].dropLast()) : ""
        }
    }

    /// Most lines shown: the file holds a few thousand.
    private static let most = 1_000

    private var categories: [String] {
        Array(Set(lines.map(\.category))).filter { !$0.isEmpty }.sorted()
    }

    private var shown: [Line] {
        Array(lines.filter { category == nil || $0.category == category }.prefix(Self.most))
    }

    /// Oldest first, as the file has them.
    private var shownText: String {
        shown.reversed().map(\.text).joined(separator: "\n")
    }

    var body: some View {
        List(shown) { line in
            Text(line.text)
                .font(.caption.monospaced())
                .foregroundStyle(line.level == "error" ? .red : line.level == "launch" ? .blue : .primary)
                .textSelection(.enabled)
        }
        .listStyle(.plain)
        .overlay {
            if shown.isEmpty { ContentUnavailableView("No Lines", systemImage: "doc.text") }
        }
        .navigationTitle(category ?? "App Log")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Menu {
                    Picker("Category", selection: $category) {
                        Text("All").tag(String?.none)
                        ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                } label: {
                    Label("Category", systemImage: "line.3.horizontal.decrease.circle")
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = shownText }
                ShareLink(item: shownText, subject: Text("Leeway Log"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let text = await Task.detached(priority: .utility) { DiagnosticLog.contents() }.value
        let all = text.split(separator: "\n")
        lines = all.reversed().enumerated().map { Line(id: $0.offset, String($0.element)) }
    }
}

#Preview {
    NavigationStack { DiagnosticsTool() }
}
