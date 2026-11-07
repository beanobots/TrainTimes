import SwiftUI

/// The Widgets tab: saved widget configurations, which Home and Lock Screen widgets pick
/// from in Edit Widget.
struct WidgetsView: View {
    @Environment(WidgetStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosing = false
    /// The widget picked (its kind, then its train, bus or dock), before it's named.
    @State private var chosen: SavedWidget?
    @State private var newWidget: SavedWidget?

    private func add() {
        chosen = nil
        choosing = true
    }

    /// The inputs that decide what an unconfigured (or orphaned) placed Transfers widget shows:
    /// which widgets, in order, have a change.
    private var placement: [String] {
        store.saved.widgets.map { "\($0.id) \($0.change != nil)" }
    }

    @Environment(\.isSideways) private var sideways

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.saved.widgets) { widget in
                        WidgetRow(widget: widget, look: store.look(for: widget.id),
                                  placed: store.placed[widget.id] ?? 0)
                            // The whole widget opens it, without a chevron beside it
                            .background {
                                NavigationLink(value: widget.id) { EmptyView() }.opacity(0)
                            }
                            // Gaps between the cards
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityHint("Edit this widget")
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ store.saved.widgets[$0].id }) { store.delete(id) }
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    .deleteDisabled(store.saved.widgets.count == 1)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                WidgetEditor(id: id)
                    .toolbar(.visible, for: .navigationBar)
            }
            // As the Home Screen: the widgets on a wallpaper, each named under it
            .scrollContentBackground(.hidden)
            // On its side, a card over the map in its place (`sidewaysCard`)
            .background {
                if !sideways { WallpaperBackdrop().ignoresSafeArea() }
            }
            .contentMargins(.top, 16, for: .scrollContent)
            // No title bar, as New Trip: the tab says where you are
            .toolbar(.hidden, for: .navigationBar)
            // Over the tab bar, by your thumb
            .safeAreaBar(edge: .bottom) {
                Button(action: add) {
                    Label("New Route", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.bottom, 8)
            }
            // On its side, down the left over the map as Nearby's card, New Route at its foot
            .sidewaysCard()
            // On dismiss, continue to AddWidget; nothing if cancelled
            .sheet(isPresented: $choosing, onDismiss: {
                if let chosen { newWidget = chosen }
            }) {
                NewWidgetPicker { chosen = $0 }
            }
            .sheet(item: $newWidget) { widget in
                AddWidget(starting: widget)
            }
            // Placed widgets change outside the app, so recount on appear and foreground
            .task { await store.countPlaced() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.countPlaced() } }
            }
            // ...and when edits here change which saved widget some of them show
            .onChange(of: placement) {
                Task { await store.countPlaced() }
            }
        }
    }
}

private struct WidgetRow: View {
    let widget: SavedWidget
    /// As last shown while editing it.
    let look: WidgetLook
    let placed: Int
    @Environment(\.isSideways) private var sideways

    /// The widget as the Home Screen shows it, then its name and how many are placed under it,
    /// as an app's name is.
    var body: some View {
        VStack(spacing: 6) {
            WidgetPreview(widget: widget, look: look)
            Text("\(widget.title) · \(placed == 0 ? "Not placed" : "\(placed) placed")")
                .font(.caption.weight(.medium))
                // White on the wallpaper; on its side, on the card
                .foregroundStyle(sideways ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                .shadow(color: .black.opacity(sideways ? 0 : 0.35), radius: 2, y: 1)
                .lineLimit(1)
        }
        .frame(maxWidth: WidgetLook.medium.size.width)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Edits one saved widget.
private struct WidgetEditor: View {
    let id: UUID
    @Environment(WidgetStore.self) private var store

    /// Remembered, so the Widgets tab draws it as last shown here.
    private var look: Binding<WidgetLook> {
        Binding {
            store.look(for: id)
        } set: {
            store.setLook($0, for: id)
        }
    }

    var body: some View {
        if let widget = store.binding(for: id) {
            Form {
                WidgetHeader(widget: widget.wrappedValue, look: look)
                WidgetFields(widget: widget)
            }
            .listSectionSpacing(.compact)
            .pinnedWidget(widget.wrappedValue, look: look)
            // The name is edited in its field, as Clock's Edit Alarm does
            .navigationTitle("Edit Route")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Sets up a new widget whose train is already chosen.
private struct AddWidget: View {
    @Environment(WidgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var widget: SavedWidget
    @State private var look = WidgetLook.medium

    init(starting widget: SavedWidget) {
        _widget = State(initialValue: widget)
    }

    var body: some View {
        NavigationStack {
            Form {
                WidgetHeader(widget: widget, look: $look)
                WidgetFields(widget: $widget)
            }
            .listSectionSpacing(.compact)
            .pinnedWidget(widget, look: $look)
            .navigationTitle("New Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // The standard tick, still named "Add" for VoiceOver
                    Button("Add", systemImage: "checkmark", role: .confirm) {
                        store.add(widget)
                        store.setLook(look, for: widget.id)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The Saved Route's three sizes as tiles, each its outline with its name and size.
private struct LookTiles: View {
    @Binding var look: WidgetLook

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WidgetLook.allCases) { tile in
                let selected = tile == look
                Button {
                    look = tile
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(selected ? Color.accentColor.opacity(0.2) : .clear)
                            .strokeBorder(lineWidth: 1.5)
                            .frame(width: tile.glyph.width, height: tile.glyph.height)
                            .frame(height: 34)
                        Text(tile.kindName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(tile.sizeName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle.pickerCard
                        .fill(selected ? Color.accentColor.opacity(0.1) : Color(.secondarySystemGroupedBackground)))
                    .contentShape(RoundedRectangle.pickerCard)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// The widget being set up, as the Home Screen will show it and redrawn as its fields change,
/// with which widget to show it as. The top of the form, so it scrolls away with it; then
/// `pinnedWidget` keeps a small copy.
private struct WidgetHeader: View {
    let widget: SavedWidget
    @Binding var look: WidgetLook

    var body: some View {
        Section {
            VStack(spacing: 10) {
                WidgetPreview(widget: widget, look: look)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                LookTiles(look: $look)
                    .frame(maxWidth: WidgetLook.medium.size.width)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
            .id(PinnedWidget.top)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

extension View {
    /// Once `WidgetHeader` has mostly scrolled away, a bar at the top with a small copy of the
    /// widget and a menu for which widget and size; tapping the copy goes back up to the full one.
    fileprivate func pinnedWidget(_ widget: SavedWidget, look: Binding<WidgetLook>) -> some View {
        modifier(PinnedWidget(widget: widget, look: look))
    }
}

/// See `View.pinnedWidget(_:look:)`.
private struct PinnedWidget: ViewModifier {
    let widget: SavedWidget
    @Binding var look: WidgetLook
    @State private var compact = false

    /// The id of `WidgetHeader`'s row, to scroll back to. A Form is a List, which
    /// `scrollPosition` doesn't scroll, so this goes through a `ScrollViewReader`.
    static let top = "widgetHeader"

    /// Small enough for a bar: half size, or less for the large widget.
    private var scale: CGFloat { min(0.5, 90 / look.size.height) }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                // Shown once the header's widget is mostly out of sight, and hidden a little
                // higher, so it doesn't flip back and forth at the line
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, scrolled in
                    let line = look.size.height * 0.7
                    let shown = compact ? scrolled > line - 24 : scrolled > line
                    guard shown != compact else { return }
                    withAnimation(.snappy(duration: 0.25)) { compact = shown }
                }
                // Floating over the form under the navigation bar, not a safeAreaBar: adding or
                // removing one changes the form's top inset, and its scroll position jumps
                // far enough to show or hide the bar again, over and over
                .overlay(alignment: .top) {
                    if compact {
                        bar(proxy)
                            .glassEffect(.regular, in: .rect(cornerRadius: 26))
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
    }

    private func bar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 14) {
            Button {
                withAnimation { proxy.scrollTo(Self.top, anchor: .top) }
            } label: {
                // At its full size, then shrunk: offered less room, it would narrow instead
                WidgetPreview(widget: widget, look: look)
                    .frame(width: look.size.width, height: look.size.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: look.size.width * scale, height: look.size.height * scale, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the widget full size")
            // The widget's name and size as plain text, all of it the menu: a glass button
            // inside the glass card looked cramped
            Menu {
                Picker("Widget", selection: $look) {
                    ForEach(WidgetLook.allCases) { look in
                        Text(look.title).tag(look)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(look.kindName)
                            .font(.headline)
                        Text(look.sizeName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Widget")
            .accessibilityValue(look.title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

/// Fields shared by adding and editing a widget.
private struct WidgetFields: View {
    @Binding var widget: SavedWidget

    /// Goes through `setSelection`, which keeps or drops the change in the same update.
    private var train: Binding<Selection> {
        Binding {
            widget.selection
        } set: {
            widget.setSelection($0)
        }
    }

    var body: some View {
        switch widget.kind {
        case .subway: trainFields
        case .bus, .bike: RouteFields(widget: $widget)
        }
    }

    @ViewBuilder private var trainFields: some View {
        TripSections(selection: train, change: $widget.change, destinationID: $widget.destinationID,
                     bothWays: $widget.bothWays, route: $widget) {
            // Labelled like Depart from and Arrive at below it; empty shows the station's name
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(widget.selection.station?.name ?? "Name", text: $widget.name)
                    .font(.headline)
                    .accessibilityLabel("Name")
            }
            .padding(.vertical, 4)
        }
        CommuteSection(widget: $widget)
        Section {
            Toggle("Service alerts", isOn: $widget.selection.serviceAlerts)
            Toggle("Elevator outages", isOn: $widget.selection.elevatorAlerts)
        }
    }
}

/// A train row (tap to change) and its optional change of trains, for a widget or its
/// commuting hours. Bind `selection` through `setSelection`, which keeps or drops the change.
private struct TripSections<Leading: View>: View {
    @Binding var selection: Selection
    @Binding var change: Change?
    /// Where you're going without a change; with one, the change's destination is edited instead.
    @Binding var destinationID: String?
    /// A widget's Both directions, picked as the train's direction; nil where it isn't offered.
    var bothWays: Binding<Bool>?
    /// The route these are, whose Depart from can then be a bus stop too; nil for trains only.
    var route: Binding<SavedWidget>?
    /// The card's header, e.g. when the other trip shows; nil for none.
    var header: String?
    /// Rows above Depart from and Arrive at, in the same card: the widget's name, or the other
    /// trip's days and hours.
    let leading: Leading
    @State private var choosingTrain = false
    @State private var choosingChange = false
    /// Which of the change's `stops` the change picker edits; nil to add one.
    @State private var editingStop: Int?
    @State private var choosingDestination = false

    private var walkMinutes: Binding<Int> {
        Binding {
            change?.walkMinutes ?? Change.defaultWalkMinutes
        } set: {
            change?.walkMinutes = $0
        }
    }

    init(selection: Binding<Selection>, change: Binding<Change?>, destinationID: Binding<String?>,
         bothWays: Binding<Bool>? = nil, route: Binding<SavedWidget>? = nil, header: String? = nil,
         @ViewBuilder leading: () -> Leading) {
        _selection = selection
        _change = change
        _destinationID = destinationID
        self.bothWays = bothWays
        self.route = route
        self.header = header
        self.leading = leading()
    }

    /// `leading`, then where you start and where you're going, side by side, then the change,
    /// all in one card.
    var body: some View {
        Section {
            leading
            HStack(alignment: .top, spacing: 12) {
                departButton
                Divider()
                arriveButton
            }
            .padding(.vertical, 4)
            changeRows
        } header: {
            if let header { Text(header) }
        }
        if let change {
            suggestionsSection(change)
        }
    }

    private var departButton: some View {
        Button {
            choosingTrain = true
        } label: {
            EndpointCell(title: "Depart from", routes: selection.routes, name: selection.station?.name,
                         detail: bothWays?.wrappedValue == true ? "Both ways" : selection.heading,
                         placeholder: "Choose a train")
        }
        .buttonStyle(.plain)
        .accessibilityHint(route == nil ? "Choose another station, line or direction"
                                        : "Choose another station or bus stop")
        // On the button, not the Section: a Section applies modifiers to each row, header
        // and footer, and the duplicate sheets break this one
        .sheet(isPresented: $choosingTrain) {
            if let route {
                NewWidgetPicker(kind: .subway, editing: route.wrappedValue) { route.wrappedValue.takeDeparture($0) }
            } else {
                TrainPicker(selection: $selection, bothWays: bothWays)
            }
        }
    }

    private var arriveButton: some View {
        let station = destination.wrappedValue.flatMap(StationDirectory.station(id:))
        return Button {
            choosingDestination = true
        } label: {
            EndpointCell(title: "Arrive at", routes: [], name: station?.name, detail: nil,
                         placeholder: "Add a destination")
        }
        .buttonStyle(.plain)
        .accessibilityHint(change == nil ? "Choose where you're going, to show when you'd get there"
                                         : "Choose where you're going, to time each way there")
        .sheet(isPresented: $choosingDestination) {
            DestinationPicker(selection: selection, change: change, destinationID: destination)
        }
    }
}

/// Half of the Depart from and Arrive at row: its label, then the station (or a placeholder to
/// tap) with any line bullets and a caption.
private struct EndpointCell: View {
    let title: String
    let routes: [String]
    let name: String?
    let detail: String?
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let name {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                // The lines' bullets, then which way: (R) Manhattan
                if !routes.isEmpty || detail != nil {
                    HStack(spacing: 6) {
                        if !routes.isEmpty {
                            LineBullets(routes: routes, size: 18)
                        }
                        if let detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } else {
                Text(placeholder)
                    .font(.headline)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

extension TripSections {
    /// The change's stations, each a row to edit or swipe away, the walk between platforms if
    /// any is on another, then an Add button. Rows of the Depart from and Arrive at card.
    @ViewBuilder fileprivate var changeRows: some View {
        let stops = change?.stops ?? []
        let parts = change?.smartChanges(for: selection) ?? []
        ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
            Button {
                editingStop = index
                choosingChange = true
            } label: {
                ChangeRow(change: stop, selection: selection,
                          lines: stops.count > 1 ? parts.first { $0.change == stop }?.lines : nil,
                          isAlternative: index > 0)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose another station or lines to change to")
        }
        .onDelete { offsets in
            remove(at: offsets)
        }
        if let change, parts.contains(where: { !$0.change.isAllAcross(from: selection.only($0.lines)) }) {
            Stepper(value: walkMinutes, in: 1...15) {
                Text("Walk between platforms: \(change.walkMinutes) min")
            }
        }
        // Always here, so the sheet stays attached when Done adds the first change
        Button {
            editingStop = nil
            choosingChange = true
        } label: {
            // "Or": another station to change at instead, not a second change along the way
            Label(change == nil ? "Add a Change" : "Or Change At",
                  systemImage: change == nil ? "arrow.triangle.swap" : "plus.circle.fill")
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $choosingChange) {
            ChangePicker(selection: selection, change: pickedStop)
        }
    }

    /// Stations next to the change's where a useful line is across the platform, each with a
    /// button to add it.
    @ViewBuilder private func suggestionsSection(_ change: Change) -> some View {
        let suggestions = change.suggestions(for: selection)
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions, id: \.change.stationID) { suggestion in
                    Button {
                        add(suggestion.change)
                    } label: {
                        SuggestionRow(suggestion: suggestion)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Adds this change")
                }
            } header: {
                Text("Also worth trying")
            } footer: {
                if let destination = change.destination {
                    Text("Stops next to your changes where a line to \(destination.name) is across the platform.")
                } else {
                    Text("Stops next to your changes where a line you'd walk to is across the platform.")
                }
            }
        }
    }

    /// Removes the change's `stops` at `offsets`, and with none left the change, keeping where
    /// you're going as the widget's own destination again.
    private func remove(at offsets: IndexSet) {
        guard let change else { return }
        var stops = change.stops
        stops.remove(atOffsets: offsets)
        if stops.isEmpty {
            destinationID = change.destinationID
            self.change = nil
        } else {
            self.change = Change(stops: stops)
        }
    }

    /// Adds `stop` to the change, joining it to one already at its station.
    private func add(_ stop: Change) {
        guard var stops = change?.stops else { return }
        if let index = stops.firstIndex(where: { $0.stationID == stop.stationID && $0.direction == stop.direction }) {
            stops[index].routes += stop.routes.filter { !stops[index].routes.contains($0) }
        } else {
            stops.append(stop)
        }
        change = Change(stops: stops)
    }

    /// The change's destination, or without a change, the widget's own.
    private var destination: Binding<String?> {
        Binding {
            change == nil ? destinationID : change?.destinationID
        } set: {
            if change == nil { destinationID = $0 } else { change?.destinationID = $0 }
        }
    }

    /// The stop `editingStop` for `ChangePicker`, or nil to add one. A picked station already
    /// among the stops replaces it. A change starts without a destination, so a first one takes
    /// the widget's: with a change, Arrive at edits the change's destination instead.
    private var pickedStop: Binding<Change?> {
        Binding {
            guard let editingStop, let stops = change?.stops, stops.indices.contains(editingStop) else { return nil }
            return stops[editingStop]
        } set: {
            guard var picked = $0 else { return }
            guard let change else {
                if picked.destinationID == nil { picked.destinationID = destinationID }
                self.change = picked
                return
            }
            var stops = change.stops
            let index = editingStop.flatMap { stops.indices.contains($0) ? $0 : nil }
                ?? stops.firstIndex { $0.stationID == picked.stationID }
            if let index { stops[index] = picked } else { stops.append(picked) }
            // One stop per station
            let kept = index ?? stops.count - 1
            stops = stops.enumerated().filter { $0.offset == kept || $0.element.stationID != picked.stationID }.map(\.element)
            // The stops share the first's walk and destination
            var joined = Change(stops: stops)
            joined?.walkMinutes = change.walkMinutes
            joined?.quickMinutes = change.quickMinutes
            joined?.destinationID = change.destinationID
            self.change = joined
        }
    }

}

/// Times and days when a widget shows another train (with its own change), e.g. the
/// train home in the evening.
private struct CommuteSection: View {
    @Binding var widget: SavedWidget

    /// Falls back to `commute` if removed while still on screen.
    private func hours(_ commute: CommutingHours) -> Binding<CommutingHours> {
        Binding {
            widget.commute ?? commute
        } set: {
            widget.commute = $0
        }
    }

    /// Goes through `setSelection`, which keeps or drops the change in the same update.
    private func train(_ hours: Binding<CommutingHours>) -> Binding<Selection> {
        Binding {
            hours.wrappedValue.selection
        } set: {
            hours.wrappedValue.setSelection($0)
        }
    }

    /// Minutes after midnight as a `Date` today.
    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    /// Minutes after midnight as a `Date` today, for a time picker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Self.date(minutes.wrappedValue)
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
    }

    /// When the other trip shows, as its card's header: "Weekdays, 4:00 PM–6:00 PM".
    private static func summary(_ hours: CommutingHours) -> String {
        let calendar = Calendar.current
        let days: String
        switch hours.weekdays {
        case Set(1...7): days = "Every day"
        case [2, 3, 4, 5, 6]: days = "Weekdays"
        case [1, 7]: days = "Weekends"
        case []: days = "No days"
        default:
            // In the locale's order, as the day buttons are
            let first = calendar.firstWeekday
            let ordered = (0..<7).map { (first - 1 + $0) % 7 + 1 }.filter(hours.weekdays.contains)
            days = ordered.map { calendar.shortWeekdaySymbols[$0 - 1] }.formatted(.list(type: .and))
        }
        let from = date(hours.start).formatted(date: .omitted, time: .shortened)
        let until = date(hours.end).formatted(date: .omitted, time: .shortened)
        return "\(days), \(from)–\(until)"
    }

    var body: some View {
        if let commute = widget.commute {
            let hours = hours(commute)
            TripSections(selection: train(hours), change: hours.change, destinationID: hours.destinationID,
                         header: Self.summary(hours.wrappedValue)) {
                WeekdayPicker(weekdays: hours.weekdays)
                    // Line the divider below up with the others
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    .swipeActions { removeButton }
                // From and until on one row
                HStack {
                    Text("From")
                    DatePicker("From", selection: time(hours.start), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                    Text("Until")
                    DatePicker("Until", selection: time(hours.end), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                .swipeActions { removeButton }
            }
        } else {
            Section {
                Button {
                    // Starts as a copy of the widget's train and change
                    widget.commute = CommutingHours(selection: widget.selection, change: widget.change)
                } label: {
                    Label("Show Another Trip at Set Times", systemImage: "clock.arrow.2.circlepath")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            } footer: {
                Text("E.g. the train home in the evening")
            }
        }
    }

    /// Swiping the days or hours removes the other trip, as swiping a change removes it.
    private var removeButton: some View {
        Button("Remove", role: .destructive) { widget.commute = nil }
    }
}

/// Weekday toggles, in the locale's order.
private struct WeekdayPicker: View {
    @Binding var weekdays: Set<Int>
    /// Each day's circle, growing with its letter.
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 22

    /// `Calendar` weekday numbers starting from `firstWeekday`.
    private var days: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        HStack {
            ForEach(days, id: \.self) { day in
                let isOn = weekdays.contains(day)
                Button {
                    if isOn { weekdays.remove(day) } else { weekdays.insert(day) }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: size, height: size)
                }
                // Glass, tinted when on, as the system's own toggle buttons are
                .buttonStyle(.glass(isOn ? .regular.tint(.accentColor) : .regular))
                .buttonBorderShape(.circle)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
                if day != days.last { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A widget's change: lines, station, direction and how (across or walk).
private struct ChangeRow: View {
    let change: Change
    let selection: Selection
    /// Those of your train's lines it's for, to say so when not all; nil for all of them.
    var lines: [String]? = nil
    /// After the first, so it reads as a choice between changes rather than a second one.
    var isAlternative = false

    private var subtitle: String {
        let from = lines.map(selection.only) ?? selection
        // "or the B63 to Cobble Hill, 3 min walk"
        let buses = change.buses.map { "the \(BusNames.label($0.line)) to \($0.wayName), \($0.walkMinutes) min walk" }
        guard !change.routes.isEmpty else {
            return buses.joined(separator: " or ").prefix(1).uppercased() + buses.joined(separator: " or ").dropFirst()
        }
        let heading = change.heading(for: from)
        let how = change.isAllAcross(from: from) ? "across the platform" : "\(change.walkMinutes) min walk"
        let trains = "\(Lines.list(change.routes, joinedBy: "or")) \(heading) · \(how)"
        return buses.isEmpty ? trains : ([trains] + buses).joined(separator: ", or ")
    }

    /// "From the Q", when it's for only some of your lines.
    private var fromLines: String? {
        guard let lines, lines.count < selection.routes.count else { return nil }
        return "From the \(Lines.list(lines, joinedBy: "or"))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if change.routes.isEmpty, let bus = change.buses.first {
                    BusBadge(line: bus.line, size: 30)
                } else {
                    LineBullets(routes: change.routes, size: 36)
                }
            }
            .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                // Labelled like Depart from and Arrive at, as it shares their card
                Text(isAlternative ? "Or change at" : "Then change at")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(change.station?.name ?? "Choose a station").font(.headline).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let fromLines {
                    Text(fromLines)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A station worth adding to the change: its lines, where it is next to the change, and a button.
private struct SuggestionRow: View {
    let suggestion: ChangeSuggestion

    /// "Across the platform, a stop after Atlantic Av".
    private var detail: String {
        let besides = suggestion.besides.station?.name.mainStationName ?? "your change"
        return "Across the platform, a stop \(suggestion.sooner ? "before" : "after") \(besides)"
    }

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: suggestion.change.routes, size: 28)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Lines.list(suggestion.change.routes, joinedBy: "or")) at \(suggestion.change.station?.name ?? "")")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The train on a widget or train page; tapping it opens the picker.
struct TrainChoiceRow: View {
    let selection: Selection
    /// Shown when there's no station.
    var placeholder = "Choose a train"

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: selection.routes, size: 36)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.station?.name ?? placeholder).font(.headline).foregroundStyle(.primary)
                if let station = selection.station {
                    Text("\(selection.caption) · \(station.borough)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview("Edit Widget") {
    let store = WidgetStore()
    NavigationStack {
        WidgetEditor(id: store.saved.widgets[0].id)
    }
    .environment(store)
    .environment(SettingsStore())
}

#Preview("Large Transfers") {
    // The R from Prospect Av, changing at Atlantic Av-Barclays Ctr to the D or N
    var widget = SavedWidget(selection: .fallback)
    widget.change = TrainEntry.transferPreview().change
    return Form {
        WidgetHeader(widget: widget, look: .constant(.largeTransfers))
    }
    .environment(SettingsStore())
}

#Preview {
    WidgetsView()
        .environment(WidgetStore())
        .environment(SettingsStore())
}
