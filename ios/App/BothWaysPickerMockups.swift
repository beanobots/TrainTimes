#if DEBUG
import SwiftUI

// Throwaway mockups: Both as a direction of its own, and the Direction and Edit Widget pages
// redone for Liquid Glass and consistency. Glass only on controls floating over the widget's
// stage; form rows all one pattern. Delete once one is picked.

// MARK: The widget, as Two Rows

/// The medium Next train widget at 338 × 158: one way as now, or both as Two Rows.
private struct MockWidget: View {
    var both = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LineBullet(route: "R", size: 24)
                if both {
                    Text("Prospect Av").font(.body.bold()).foregroundStyle(Color.boardText)
                } else {
                    Text("Prospect Av \(Text("Manhattan").font(.footnote).foregroundStyle(Color.boardGray))")
                        .font(.body.bold()).foregroundStyle(Color.boardText)
                }
                Spacer()
                Image(systemName: "figure.walk")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.boardText)
                    .frame(width: 44, height: 26)
                    .background(Capsule().fill(Color.boardButton))
            }
            if both {
                row("arrow.up", "Manhattan", route: "N", then: "then 12 · 20 min", time: "4:00", live: true)
                row("arrow.down", "Bay Ridge", route: "R", then: "then 18 · 27 min", time: "9:00", live: false)
            } else {
                HStack {
                    countdown("4:00", size: 48, live: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            LineBullet(route: "N", size: 18)
                            Text("leaves 8:29").font(.subheadline.weight(.semibold)).foregroundStyle(Color.boardText)
                        }
                        Text("then 12 · 20 min").font(.caption).foregroundStyle(Color.boardGray)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
            }
        }
        .padding(16)
        .frame(width: 338, height: 158)
        .background(Color.boardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row(_ arrow: String, _ name: String, route: String, then: String, time: String, live: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: arrow).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.boardGray)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.boardText)
                HStack(spacing: 3) {
                    LineBullet(route: route, size: 12)
                    Text(then).font(.caption2).foregroundStyle(Color.boardGray)
                }
            }
            Spacer()
            countdown(time, size: 28, live: live)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
    }

    private func countdown(_ time: String, size: CGFloat, live: Bool) -> some View {
        HStack(spacing: 3) {
            Text(time).font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            if live { LiveMark(size: size / 3) }
        }
        .foregroundStyle(live ? Color.liveText : Color.boardText)
    }
}

extension View {
    /// Drawn at `size`, then shrunk by `scale`, taking only the shrunk room.
    fileprivate func shrunk(_ scale: CGFloat, size: CGSize = CGSize(width: 338, height: 158)) -> some View {
        scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
    }
}

// MARK: Shared row pattern

/// Every row: a tinted icon tile, a caption over its value, then a chevron. As Settings' rows.
private struct FieldRow<Value: View>: View {
    let symbol: String
    let tint: Color
    let label: String
    var chevron = true
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                value
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
    }
}

/// Both's arrows and name, as the train's direction everywhere.
private struct BothWaysLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            LineBullet(route: "R", size: 18)
            Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text("Both ways").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: Direction · A · List

/// The Direction step as now, with Both an equal third choice in the same card.
private struct DirectionListMock: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice("arrow.up", "Manhattan", "Northbound")
                    choice("arrow.down", "Bay Ridge - 95 St", "Southbound")
                    choice("arrow.up.arrow.down", "Both ways", "A row for each, Manhattan on top", checked: true)
                } header: {
                    Text("R at Prospect Av")
                } footer: {
                    Text("Both shows every size of the widget with a row for each way.")
                }
            }
            .navigationTitle("Direction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back", systemImage: "chevron.left") {} }
            }
        }
    }

    private func choice(_ symbol: String, _ title: String, _ subtitle: String, checked: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(.systemGray5)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if checked { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
        }
    }
}

// MARK: Direction · B · Cards with previews

/// Each direction a card showing the widget it makes, so Both's two rows are seen before
/// they're picked.
private struct DirectionCardsMock: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("R at Prospect Av")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                    card("arrow.up.arrow.down", "Both ways", "A row for each", both: true, checked: true)
                    card("arrow.up", "Manhattan", "Northbound", both: false)
                    HStack(spacing: 12) {
                        compactCard("arrow.down", "Bay Ridge - 95 St", "Southbound")
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Direction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back", systemImage: "chevron.left") {} }
            }
        }
    }

    private func header(_ symbol: String, _ title: String, _ subtitle: String, checked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(checked ? Color.white : .secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(checked ? Color.accentColor : Color(.systemGray5)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if checked { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint) }
        }
    }

    private func card(_ symbol: String, _ title: String, _ subtitle: String, both: Bool, checked: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(symbol, title, subtitle, checked: checked)
            MockWidget(both: both)
                .shrunk(0.9)
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay {
            if checked {
                RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private func compactCard(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        header(symbol, title, subtitle, checked: false)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

// MARK: Edit Widget · A · Tidied form

/// The widget on top, then system controls only: Home Screen and widget as segmented pickers,
/// the trip as rows of one pattern, direction a three-way control under the station.
private struct EditFormMock: View {
    @State private var appearance = 0
    @State private var kind = 0
    @State private var size = 1
    @State private var way = 1
    @State private var alerts = true
    @State private var elevators = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        MockWidget(both: way == 1)
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                        Picker("Home Screen", selection: $appearance) {
                            Text("Default").tag(0); Text("Clear").tag(1); Text("Tinted").tag(2)
                        }
                        .pickerStyle(.segmented)
                        HStack(spacing: 8) {
                            Picker("Widget", selection: $kind) {
                                Text("Next Train").tag(0); Text("Transfers").tag(1)
                            }
                            Picker("Size", selection: $size) {
                                Text("S").tag(0); Text("M").tag(1); Text("L").tag(2)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .frame(maxWidth: 338)
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section("Trip") {
                    FieldRow(symbol: "textformat", tint: .gray, label: "Name", chevron: false) {
                        Text("Prospect Av").font(.headline).foregroundStyle(.tertiary)
                    }
                    FieldRow(symbol: "tram.fill", tint: .yellow, label: "Depart from") {
                        HStack(spacing: 6) {
                            Text("Prospect Av").font(.headline)
                            LineBullet(route: "R", size: 18)
                        }
                    }
                    Picker("Direction", selection: $way) {
                        Label("Manhattan", systemImage: "arrow.up").tag(0)
                        Label("Both", systemImage: "arrow.up.arrow.down").tag(1)
                        Label("Bay Ridge", systemImage: "arrow.down").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 54 }
                    FieldRow(symbol: "mappin", tint: .red, label: "Arrive at") {
                        Text("Add a destination").font(.headline).foregroundStyle(.tint)
                    }
                    FieldRow(symbol: "arrow.triangle.swap", tint: .orange, label: "Change") {
                        Text("Add a change").font(.headline).foregroundStyle(.tint)
                    }
                }

                Section {
                    FieldRow(symbol: "clock.arrow.2.circlepath", tint: .indigo, label: "At set times") {
                        Text("Show another trip").font(.headline).foregroundStyle(.tint)
                    }
                } footer: {
                    Text("E.g. the train home in the evening")
                }

                Section("On the widget") {
                    Toggle(isOn: $alerts) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "exclamationmark.triangle.fill", tint: .orange)
                            Text("Service alerts")
                        }
                    }
                    Toggle(isOn: $elevators) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "figure.roll", tint: .blue)
                            Text("Elevator outages")
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Edit Widget")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: Edit Widget · B · Glass stage

/// The widget on a wallpaper stage, its Home Screen and size as glass controls floating over it
/// (the one place glass sits on rich content, as Apple suggests). The form under it keeps the
/// same rows; direction opens the Direction step.
private struct EditStageMock: View {
    @State private var appearance = 0
    @Namespace private var glass

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    stage
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section("Trip") {
                    FieldRow(symbol: "textformat", tint: .gray, label: "Name", chevron: false) {
                        Text("Prospect Av").font(.headline).foregroundStyle(.tertiary)
                    }
                    FieldRow(symbol: "tram.fill", tint: .yellow, label: "Depart from") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prospect Av").font(.headline)
                            BothWaysLabel()
                        }
                    }
                    FieldRow(symbol: "mappin", tint: .red, label: "Arrive at") {
                        Text("Add a destination").font(.headline).foregroundStyle(.tint)
                    }
                    FieldRow(symbol: "arrow.triangle.swap", tint: .orange, label: "Change") {
                        Text("Add a change").font(.headline).foregroundStyle(.tint)
                    }
                }
                Section {
                    FieldRow(symbol: "clock.arrow.2.circlepath", tint: .indigo, label: "At set times") {
                        Text("Show another trip").font(.headline).foregroundStyle(.tint)
                    }
                }
                Section("On the widget") {
                    Toggle(isOn: .constant(true)) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "exclamationmark.triangle.fill", tint: .orange)
                            Text("Service alerts")
                        }
                    }
                    Toggle(isOn: .constant(false)) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "figure.roll", tint: .blue)
                            Text("Elevator outages")
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Edit Widget")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var stage: some View {
        VStack(spacing: 14) {
            MockWidget(both: true)
                .shrunk(0.94)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .padding(.top, 20)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    // Home Screen look: three glass circles, the chosen one tinted
                    HStack(spacing: 4) {
                        ForEach(Array(["sun.max.fill", "circle.dotted", "paintpalette.fill"].enumerated()), id: \.offset) { index, symbol in
                            Button {
                                appearance = index
                            } label: {
                                Image(systemName: symbol).frame(width: 22, height: 22)
                            }
                            .buttonStyle(.glass(index == appearance ? .regular.tint(.accentColor) : .regular))
                            .buttonBorderShape(.circle)
                            .foregroundStyle(index == appearance ? Color.white : Color.primary)
                        }
                    }
                    Menu {
                        Text("Next Train · Small")
                        Text("Next Train · Medium")
                        Text("Transfers · Medium")
                        Text("Transfers · Large")
                    } label: {
                        HStack(spacing: 6) {
                            Text("Next Train · Medium").font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background {
            WallpaperBackdrop()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        }
    }
}

#Preview("Direction · A · List") { DirectionListMock() }
#Preview("Direction · B · Cards") { DirectionCardsMock() }
#Preview("Edit Widget · A · Tidied form") { EditFormMock() }
#Preview("Edit Widget · B · Glass stage") { EditStageMock() }
#endif
