import SwiftUI

/// The Widgets tab: every widget set up in the app. A widget on the Home
/// Screen or Lock Screen picks one of these in its Edit menu.
struct WidgetsView: View {
    @Environment(WidgetStore.self) private var store
    @Environment(FavoritesStore.self) private var favorites
    @Environment(\.scenePhase) private var scenePhase
    /// Adding a widget starts by choosing its train.
    @State private var choosingTrain = false
    /// The train chosen for a new widget, which then gets its name.
    @State private var chosenTrain: Selection?
    @State private var newWidget: NewWidget?

    private struct NewWidget: Identifiable {
        let id = UUID()
        let selection: Selection
    }

    /// Starts out as the default widget, for its walking time; the
    /// picker sets the station, lines and direction one after another.
    private var newTrain: Binding<Selection> {
        Binding {
            chosenTrain ?? store.defaultWidget.selection
        } set: {
            chosenTrain = $0
        }
    }

    private func add() {
        chosenTrain = nil
        choosingTrain = true
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.saved.widgets) { widget in
                        NavigationLink(value: widget.id) {
                            WidgetRow(widget: widget, isDefault: widget.id == store.saved.defaultID, placed: store.placed[widget.id] ?? 0)
                        }
                        .contextMenu {
                            if widget.id != store.saved.defaultID {
                                Button("Make Default", systemImage: "star") { store.makeDefault(widget.id) }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ store.saved.widgets[$0].id }) { store.delete(id) }
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    .deleteDisabled(store.saved.widgets.count == 1)
                    Button(action: add) {
                        Label("Add a Widget", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Long-press a widget on your Home Screen, choose Edit Widget, and pick one of these. Changes here update every widget showing it.")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                WidgetEditor(id: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add", systemImage: "plus") {
                        Button("Create New", systemImage: "plus.circle", action: add)
                        Menu("Add from Favorites", systemImage: "star") {
                            // A favorite's train, with its walking time, to name and add
                            ForEach(favorites.favorites, id: \.trainID) { selection in
                                Button {
                                    newWidget = NewWidget(selection: selection)
                                } label: {
                                    Text(selection.station?.name ?? "Train")
                                    Text("\(Lines.list(selection.routes)) \(selection.heading)")
                                }
                            }
                        }
                        .disabled(favorites.favorites.isEmpty)
                    }
                }
            }
            // Once the train's chosen, the rest; cancelled, nothing
            .sheet(isPresented: $choosingTrain, onDismiss: {
                if let chosenTrain { newWidget = NewWidget(selection: chosenTrain) }
            }) {
                TrainPicker(selection: newTrain)
            }
            .sheet(item: $newWidget) { widget in
                AddWidget(starting: widget.selection)
            }
            // Which widgets are out there changes outside the app
            .task { await store.countPlaced() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.countPlaced() } }
            }
        }
    }
}

private struct WidgetRow: View {
    let widget: SavedWidget
    let isDefault: Bool
    let placed: Int

    /// The station under a name of its own; under the station's name, which
    /// way. Then any change: "R to Manhattan, then D or N".
    private var subtitle: String {
        let selection = widget.selection
        let base = widget.title == selection.station?.name
            ? "\(Lines.list(selection.routes)) \(selection.heading)"
            : selection.station?.name ?? ""
        guard let change = widget.change else { return base }
        return "\(base), then \(Lines.list(change.routes, joinedBy: "or"))"
    }

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: widget.selection.routes, size: 30)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(widget.title).font(.headline)
                    if isDefault {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Default")
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(placed == 0 ? "Not placed" : "\(placed) placed")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One saved widget's setup. Star its train in the Live tab for its live times.
private struct WidgetEditor: View {
    let id: UUID
    @Environment(WidgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        if let widget = store.binding(for: id) {
            let isDefault = id == store.saved.defaultID
            let placed = store.placed[id] ?? 0
            Form {
                WidgetFields(widget: widget)
                Section {
                    // The count takes in the Lock Screen's widgets as well
                    LabeledContent("On your Home and Lock Screens", value: placed == 0 ? "None" : "\(placed)")
                    if isDefault {
                        Label("Default for new widgets", systemImage: "star.fill")
                    } else {
                        Button("Make Default", systemImage: "star") { store.makeDefault(id) }
                    }
                }
                if store.saved.widgets.count > 1 {
                    Section {
                        Button("Delete Widget", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle(widget.wrappedValue.title)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete \(widget.wrappedValue.title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Widget", role: .destructive) {
                    dismiss()
                    store.delete(id)
                }
            } message: {
                Text(placed == 0 ? "" : "Widgets showing it will show the default instead.")
            }
        }
    }
}

/// Adding a widget, set up as the default is until you choose its train.
private struct AddWidget: View {
    @Environment(WidgetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var widget: SavedWidget

    init(starting selection: Selection) {
        _widget = State(initialValue: SavedWidget(selection: selection))
    }

    var body: some View {
        NavigationStack {
            Form {
                WidgetFields(widget: $widget)
            }
            .listSectionSpacing(.compact)
            .navigationTitle("New Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.add(widget)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// What adding and editing a widget have in common: its name, its train, any
/// change of trains, and which alerts it mentions.
private struct WidgetFields: View {
    @Binding var widget: SavedWidget
    @State private var choosingTrain = false
    @State private var choosingChange = false

    private var station: Station? { widget.selection.station }

    private var quickMinutes: Binding<Int> {
        Binding {
            widget.change?.quickMinutes ?? Change.defaultQuickMinutes
        } set: {
            widget.change?.quickMinutes = $0
        }
    }

    private var walkMinutes: Binding<Int> {
        Binding {
            widget.change?.walkMinutes ?? Change.defaultWalkMinutes
        } set: {
            widget.change?.walkMinutes = $0
        }
    }

    var body: some View {
        Section {
            Button {
                choosingTrain = true
            } label: {
                TrainRow(selection: widget.selection)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose another station, line or direction")
        }
        .sheet(isPresented: $choosingTrain) {
            TrainPicker(selection: $widget.selection)
        }
        // Another line or direction goes on another way, which the change
        // isn't on; another station on the same way keeps it
        .onChange(of: widget.selection) { old, new in
            if old.routes != new.routes || old.direction != new.direction {
                widget.change = nil
            } else {
                widget.change = widget.change?.validated(for: new)
            }
        }
        changeSection
        Section("Name") {
            TextField(station?.name ?? "Name", text: $widget.name)
        }
        Section {
            Stepper(value: $widget.selection.walkMinutes, in: 0...60) {
                Text(widget.selection.walkMinutes == 0 ? "Walk to the station: not set" : "Walk to the station: \(widget.selection.walkMinutes) min")
            }
        } header: {
            Text("Getting there")
        } footer: {
            Text("Trains you can't reach in time are left out, and the widget counts down to when to leave.")
        }
        Section {
            Toggle("Service alerts", isOn: $widget.selection.serviceAlerts)
            Toggle("Elevator outages", isOn: $widget.selection.elevatorAlerts)
        } header: {
            Text("Mentions")
        } footer: {
            Text("The app always lists them all.")
        }
    }
}

extension WidgetFields {
    /// Where the train is left for another, and how short a wait the large
    /// widget highlights; or a button to add one.
    @ViewBuilder fileprivate var changeSection: some View {
        let selection = widget.selection
        Section {
            if let change = widget.change {
                Button {
                    choosingChange = true
                } label: {
                    ChangeRow(change: change, selection: selection)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Choose another station or lines to change to")
                Stepper(value: quickMinutes, in: 0...15) {
                    Text("Quick change: up to \(change.quickMinutes) min")
                }
                if !change.isAllAcross(from: selection) {
                    Stepper(value: walkMinutes, in: 1...15) {
                        Text("Walk between platforms: \(change.walkMinutes) min")
                    }
                }
                Button("Remove Change", role: .destructive) {
                    widget.change = nil
                }
            } else {
                Button {
                    choosingChange = true
                } label: {
                    Label("Add a Change", systemImage: "arrow.triangle.swap")
                }
            }
        } header: {
            Text("Then change")
        } footer: {
            if let change = widget.change, let name = change.station?.name {
                Text("The large widget pairs each \(Lines.list(selection.routes)) with the first \(Lines.list(change.routes, joinedBy: "or")) it can catch at \(name), and highlights waits this short.")
            } else {
                Text("Change trains on the way, say from a local to an express. The large widget pairs each train with the first one it can catch there.")
            }
        }
        .sheet(isPresented: $choosingChange) {
            ChangePicker(selection: selection, change: $widget.change)
        }
    }
}

/// A widget's change: the lines changed to, where, which way and how.
private struct ChangeRow: View {
    let change: Change
    let selection: Selection

    private var subtitle: String {
        let heading = change.station?.directionLabel(selection.direction, routes: change.routes) ?? ""
        let how = change.isAllAcross(from: selection) ? "across the platform" : "\(change.walkMinutes) min walk"
        return "\(Lines.list(change.routes, joinedBy: "or")) \(heading) · \(how)"
    }

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: change.routes, size: 36)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.station?.name ?? "Choose a station").font(.headline).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

/// A widget's train; tapping it chooses another, in three steps.
private struct TrainRow: View {
    let selection: Selection

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: selection.routes, size: 36)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.station?.name ?? "Choose a train").font(.headline).foregroundStyle(.primary)
                if let station = selection.station {
                    Text("\(Lines.list(selection.routes)) \(selection.heading) · \(station.borough)")
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

#Preview {
    WidgetsView()
        .environment(WidgetStore())
        .environment(FavoritesStore())
        .environment(SettingsStore())
}
