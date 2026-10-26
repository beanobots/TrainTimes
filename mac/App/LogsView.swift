import AppKit
import SwiftUI

struct LogsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case activity = "Activity"
        case countdowns = "Countdowns"
        case problems = "Problems"
        case raw = "Raw"
        var id: Self { self }

        func includes(_ event: LogEvent) -> Bool {
            switch self {
            case .activity, .raw: true
            case .countdowns: event.kind == .countdown || event.kind == .ended
            case .problems: event.isProblem
            }
        }
    }

    @Environment(ServerModel.self) private var model
    @State private var search = ""
    @State private var filter = Filter.activity
    @State private var follow = true
    /// Countdowns showing their pushes, by event id.
    @State private var expanded: Set<Int> = []

    /// The most lines shown at once in Raw, newest kept.
    private static let shownLimit = 3000

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if filter == .raw, let size = model.logSize {
                    Text("server.log · \(size.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let last = model.lastPass?.date {
                    LastPassLabel(date: last)
                }
                Toggle("Follow", isOn: $follow).toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let problem = model.logProblem {
                ContentUnavailableView("Can't read the log", systemImage: "lock.fill", description: Text(problem))
            } else if filter == .raw {
                rawLines
            } else {
                LogSummary(events: model.events, lines: model.lines)
                Divider()
                eventList
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter")
    }

    // MARK: Events

    @ViewBuilder
    private var eventList: some View {
        let shown = model.events.filter {
            filter.includes($0) && (search.isEmpty || $0.texts.contains { $0.localizedCaseInsensitiveContains(search) }
                                    || $0.title.localizedCaseInsensitiveContains(search))
        }
        if shown.isEmpty {
            ContentUnavailableView(model.lines.isEmpty ? "Nothing logged yet" : "Nothing matching",
                                   systemImage: "doc.text")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(LogDay.days(of: shown)) { day in
                            Section {
                                ForEach(day.events) { event in
                                    LogEventRow(event: event, isExpanded: expandedBinding(event.id))
                                    Divider().padding(.leading, 106)
                                }
                            } header: {
                                LogDayHeader(day: day.start)
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                }
                .background(.background)
                .onAppear { if follow { proxy.scrollTo(Self.end, anchor: .bottom) } }
                .onChange(of: model.lines.last?.id) {
                    if follow { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
                .onChange(of: filter) {
                    if follow { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
    }

    /// The list's bottom, to follow.
    private static let end = "end"

    private func expandedBinding(_ id: Int) -> Binding<Bool> {
        Binding {
            expanded.contains(id)
        } set: { isExpanded in
            if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
        }
    }

    // MARK: Raw

    @ViewBuilder
    private var rawLines: some View {
        let shown = model.lines.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
            .suffix(Self.shownLimit)
        if shown.isEmpty {
            ContentUnavailableView(model.lines.isEmpty ? "Nothing logged yet" : "No matching lines",
                                   systemImage: "doc.text")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { line in
                            Text(line.text)
                                .foregroundStyle(Self.color(of: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                }
                .background(.background)
                .onAppear { if follow, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: shown.last?.id) { _, last in
                    if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    static func color(of line: LogLine) -> Color {
        switch line.kind {
        case .pass: .primary
        case .registration: .blue
        case .drop: .orange
        case .error: .red
        case .lifecycle: .green
        case .other: .secondary
        }
    }
}

/// "Last pass 4 sec ago", kept up to date.
private struct LastPassLabel: View {
    let date: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
            Text("Last pass \(Text(date, style: .relative)) ago").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One day's events, oldest first.
private struct LogDay: Identifiable {
    /// Its start, or nil for events before any dated line.
    let start: Date?
    var events: [LogEvent]
    var id: Int { events.first?.id ?? 0 }

    static func days(of events: [LogEvent]) -> [LogDay] {
        var days: [LogDay] = []
        let calendar = Calendar.current
        for event in events {
            // An undated event goes with the day before it
            let start = event.date.map { calendar.startOfDay(for: $0) } ?? days.last?.start
            if let last = days.indices.last, days[last].start == start {
                days[last].events.append(event)
            } else {
                days.append(LogDay(start: start, events: [event]))
            }
        }
        return days
    }
}

private struct LogDayHeader: View {
    let day: Date?

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
    }

    private var title: String {
        guard let day else { return "Earlier" }
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

/// Today's countdowns, pushes, problems and quiet passes.
private struct LogSummary: View {
    let events: [LogEvent]
    let lines: [LogLine]

    var body: some View {
        let calendar = Calendar.current
        let today = events.filter { $0.date.map(calendar.isDateInToday) ?? false }
        let pushes = lines.reduce(0) { total, line in
            guard let stats = line.pass, let date = line.date, calendar.isDateInToday(date) else { return total }
            return total + stats.pushes
        }
        let countdowns = today.count { $0.kind == .countdown }
        let problems = today.count(where: \.isProblem)
        HStack(spacing: 18) {
            figure(countdowns, countdowns == 1 ? "countdown today" : "countdowns today", .blue)
            figure(pushes, pushes == 1 ? "push" : "pushes", .primary)
            figure(problems, problems == 1 ? "problem" : "problems", problems > 0 ? .red : .primary)
            figure(today.filter { $0.kind == .quiet }.reduce(0) { $0 + $1.passes }, "quiet passes", .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func figure(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value, format: .number).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One event: its time, a symbol for its kind, and what happened.
private struct LogEventRow: View {
    let event: LogEvent
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
                .padding(.top, 2)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(color.opacity(event.kind == .quiet ? 0.5 : 1)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ForEach(event.countdown?.routes ?? [], id: \.self) { LineBullet(route: $0, size: 18) }
                    Text(event.title)
                        .font(.body.weight(event.kind == .quiet ? .regular : .semibold))
                        .foregroundStyle(event.kind == .quiet ? .secondary : .primary)
                    if let token = event.token { TokenChip(token: token) }
                    Spacer(minLength: 0)
                    if event.countdown != nil, event.kind == .countdown {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(event.kind == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                if isExpanded, let countdown = event.countdown {
                    PushList(pushes: countdown.pushes)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(event.kind == .error ? Color.red.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard event.kind == .countdown else { return }
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        }
        .contextMenu {
            Button("Copy Log Lines") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.texts.joined(separator: "\n"), forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(event.kind == .countdown ? .isButton : [])
    }

    /// A countdown's environment, pushes, key, the first notice, and whether it's still running.
    private var detail: String? {
        guard let countdown = event.countdown, event.kind == .countdown else { return event.detail }
        let pushes = countdown.pushes.count
        let notice = countdown.pushes.first { $0.notice != nil }
        var parts: [String] = [countdown.environment, pushes > 0 ? (pushes == 1 ? "1 push" : "\(pushes) pushes") : nil,
                               countdown.key.map { "key \($0)" }].compactMap(\.self)
        if let notice, let text = notice.notice {
            parts.append(notice.date.map { "\(text) from \($0.formatted(date: .omitted, time: .shortened))" } ?? text)
        }
        if countdown.ended == nil { parts.append("running") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch event.kind {
        case .lifecycle: "power"
        case .quiet: "moon.zzz.fill"
        case .countdown: "timer"
        case .ended: "checkmark"
        case .registration: "key.fill"
        case .drop: "minus"
        case .error: "exclamationmark.triangle.fill"
        case .other: "info"
        }
    }

    private var color: Color {
        switch event.kind {
        case .lifecycle: .green
        case .quiet: .gray
        case .countdown: .blue
        case .ended: .orange
        case .registration: .teal
        case .drop: .orange
        case .error: .red
        case .other: .gray
        }
    }
}

/// A countdown's pushes, or why they aren't listed.
private struct PushList: View {
    let pushes: [LogEvent.Push]

    var body: some View {
        if pushes.isEmpty {
            Text("Pushes are listed when the server runs with LOG_PUSHES=1.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(pushes.enumerated()), id: \.offset) { _, push in
                    HStack(spacing: 8) {
                        Text(push.date.map { $0.formatted(date: .omitted, time: .standard) } ?? "")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        if let route = push.route { LineBullet(route: route, size: 14) }
                        Text("Next train \(push.train)").font(.callout)
                        if let notice = push.notice {
                            Text(notice).font(.callout).foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// A push token's prefix.
private struct TokenChip: View {
    let token: String

    var body: some View {
        Text(token)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("token \(token)")
    }
}
