import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(ServerModel.self) private var model
    let editTiming: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let problem = model.logProblem ?? model.plistProblem {
                    Banner(symbol: "lock.fill", text: problem, color: .orange)
                }
                HStack(alignment: .top, spacing: 14) {
                    daemonCard
                    reachabilityCard
                    apnsCard
                }
                .fixedSize(horizontal: false, vertical: true)
                lastPassCard
                chartCard
                timingCard
            }
            .padding(18)
        }
    }

    // MARK: Cards

    private var daemonCard: some View {
        Card("Daemon") {
            if let status = model.status {
                StatusRow(color: status.isRunning ? .green : status.isLoaded ? .orange : .red,
                          title: status.isRunning ? "Running" : status.isLoaded ? (status.state?.capitalized ?? "Loaded") : "Stopped",
                          detail: status.pid.map { "\(Server.label) · PID \($0)" }
                              ?? status.lastExitCode.map { "Last exit code \($0)" } ?? Server.label)
            } else {
                StatusRow(color: .gray, title: "Checking…", detail: Server.label)
            }
            if let start = model.startDate {
                Text("Up \(Self.duration(since: start))").foregroundStyle(.secondary)
            }
            if let installed = model.installedDate {
                Text("Installed \(installed.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var reachabilityCard: some View {
        Card("Reachability") {
            let port = model.environment["PORT"] ?? String(Server.defaultPort)
            switch model.health {
            case .unknown:
                StatusRow(color: .gray, title: "GET /health", detail: "127.0.0.1:\(port)")
            case .ok(let milliseconds):
                StatusRow(color: .green, title: "GET /health → ok", detail: "127.0.0.1:\(port) · \(milliseconds) ms")
            case .failing(let reason):
                StatusRow(color: .red, title: "GET /health failing", detail: "127.0.0.1:\(port) · \(reason)")
            }
            switch model.tunnelRunning {
            case true?: StatusRow(color: .green, title: "Cloudflare Tunnel", detail: "cloudflared running")
            case false?: StatusRow(color: .red, title: "Cloudflare Tunnel", detail: "cloudflared isn't running")
            case nil: StatusRow(color: .gray, title: "Cloudflare Tunnel", detail: "Checking…")
            }
        }
    }

    private var apnsCard: some View {
        Card("APNs & App Attest") {
            let env = model.environment
            StatusRow(color: env["APNS_KEY_ID"] == nil ? .orange : .green,
                      title: "Key \(env["APNS_KEY_ID"] ?? "not set")",
                      detail: "Team \(env["APNS_TEAM_ID"] ?? "not set")")
            let attest = env["ATTEST_MODE"]?.lowercased() ?? "on"
            StatusRow(color: attest == "on" ? .green : .orange,
                      title: attest == "on" ? "App Attest: \(env["ATTEST_ENVIRONMENT"] ?? "production")" : "App Attest off",
                      detail: attest == "on" ? "Only the genuine app can register" : "For development only")
            if let lastPush = model.lastPush {
                Text("Last push \(lastPush.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
            }
        }
    }

    private var lastPassCard: some View {
        let title: String = {
            guard let date = model.lastPass?.date else { return "Last pass" }
            let poll = model.value(of: .poll) ?? "30"
            return "Last pass · \(date.formatted(date: .omitted, time: .standard)) · every \(poll) s"
        }()
        return Card(title) {
            if let stats = model.lastPass?.pass {
                HStack(spacing: 0) {
                    Stat(value: stats.countdowns, label: "countdowns")
                    Stat(value: stats.updates, label: "updates", color: .blue)
                    Stat(value: stats.refreshes, label: "refreshes", color: .teal)
                    Stat(value: stats.ended, label: "ended")
                    Stat(value: stats.dropped, label: "dropped")
                    Stat(value: stats.failed, label: "failed", color: stats.failed > 0 ? .orange : .primary)
                    Divider().frame(height: 36).padding(.horizontal, 12)
                    if let keys = model.keyCount {
                        Stat(value: keys, label: "attest keys")
                    } else {
                        Stat(value: nil, label: "attest keys")
                    }
                }
                if stats.withoutFeeds > 0 {
                    Label("\(stats.withoutFeeds) countdowns without the MTA's feeds", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else {
                Text(model.logProblem == nil ? "No passes in the log yet." : "The log can't be read.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chartCard: some View {
        Card("Pushes per pass · last hour") {
            let passes = model.recentPasses
            if passes.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary).frame(height: 120)
            } else {
                Chart {
                    ForEach(passes, id: \.date) { pass in
                        BarMark(x: .value("Time", pass.date), y: .value("Pushes", pass.stats.updates))
                            .foregroundStyle(by: .value("Kind", "Updates (priority 10)"))
                        BarMark(x: .value("Time", pass.date), y: .value("Pushes", pass.stats.refreshes))
                            .foregroundStyle(by: .value("Kind", "Refreshes (priority 5)"))
                    }
                }
                .chartForegroundStyleScale(["Updates (priority 10)": Color.blue, "Refreshes (priority 5)": Color.teal])
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 140)
            }
        }
    }

    private var timingCard: some View {
        Card("Push timing") {
            HStack(alignment: .bottom, spacing: 24) {
                Labeled("Earlier by more than", seconds(model.value(of: .pushEarlier)))
                Labeled("Later by more than", seconds(model.value(of: .pushLater)))
                Labeled("Following trains", seconds(model.value(of: .pushFollowing)))
                Labeled("Refresh after", seconds(model.value(of: .refresh)))
                Labeled("Poll every", seconds(model.value(of: .poll)))
                Spacer()
                Button("Edit…", action: editTiming)
            }
        }
    }

    // MARK: Formatting

    private func seconds(_ value: String?) -> String {
        guard let value, let number = Int(value) else { return "–" }
        return number >= 60 && number % 60 == 0 ? "\(number / 60) min" : "\(number) s"
    }

    static func duration(since start: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter.string(from: start, to: .now) ?? ""
    }
}

// MARK: - Pieces

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusRow: View {
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Stat: View {
    let value: Int?
    let label: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map { $0.formatted() } ?? "–")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Labeled: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).weight(.medium))
        }
    }
}
