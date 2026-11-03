import SwiftUI

// Throwaway mockup of the reordered Settings page. Delete once the real one's built.

private let margin: CGFloat = 16
private let card = RoundedRectangle(cornerRadius: 26, style: .continuous)
private let faint = Color.primary.opacity(0.05)

private func cardLabel(_ title: String) -> some View {
    Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
}

private func iconRow<Trailing: View>(_ title: String, symbol: String, tint: Color = .accentColor,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
    HStack(spacing: 12) {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .frame(width: 24)
        Text(title)
        Spacer(minLength: 8)
        trailing()
    }
    .padding(.horizontal, margin)
    .frame(minHeight: 52)
}

private func switchRow(_ title: String, symbol: String, tint: Color = .accentColor, isOn: Bool) -> some View {
    iconRow(title, symbol: symbol, tint: tint) {
        Toggle(title, isOn: .constant(isOn)).labelsHidden()
    }
}

private func linkRow(_ title: String, symbol: String, credit: String? = nil) -> some View {
    HStack(spacing: 12) {
        Image(systemName: symbol)
            .foregroundStyle(.tint)
            .frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let credit {
                Text(credit).font(.caption).foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, margin)
    .padding(.vertical, 6)
    .frame(minHeight: 52)
}

private var divider: some View { Divider().padding(.leading, 52) }

private struct MockSettings: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Settings")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)

                cardLabel("Home Station")
                HStack(spacing: 12) {
                    HStack(spacing: -6) {
                        bullet("4", Color(red: 0, green: 0.58, blue: 0.24))
                        bullet("5", Color(red: 0, green: 0.58, blue: 0.24))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Atlantic Av-Barclays Ctr").font(.headline)
                        Text("Toward Manhattan").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.quaternary, in: Circle())
                }
                .padding(margin)
                .glassEffect(.regular, in: card)
                .padding(.bottom, 14)

                cardLabel("Trip Preferences")
                VStack(spacing: 0) {
                    iconRow("Leeway walking routes", symbol: "figure.walk") { EmptyView() }
                    Picker("Walks", selection: .constant(1)) {
                        Text("Fastest").tag(0)
                        Text("Balanced").tag(1)
                        Text("Safest").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.leading, 52)
                    .padding(.trailing, margin)
                    .padding(.bottom, 12)
                    divider
                    iconRow("Comfortable walk", symbol: "figure.walk.motion") {
                        HStack(spacing: 4) {
                            Text("15 min · ¾ mi")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.tint)
                    }
                    divider
                    iconRow("Citi Bike", symbol: "bicycle") {
                        Picker("Citi Bike", selection: .constant(0)) {
                            Text("Both").tag(0)
                            Text("Bikes").tag(1)
                            Text("E-bikes").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                .background(faint, in: card)
                .padding(.bottom, 14)

                cardLabel("Accessibility")
                VStack(spacing: 0) {
                    switchRow("Step-free mode", symbol: "figure.roll", isOn: false)
                    divider
                    switchRow("Mark live times", symbol: "dot.radiowaves.up.forward", tint: .green, isOn: true)
                    divider
                    switchRow("Mark scheduled times", symbol: "clock", tint: .secondary, isOn: false)
                }
                .background(faint, in: card)
                .padding(.bottom, 14)

                cardLabel("Alerts")
                HStack(alignment: .top, spacing: 8) {
                    alert("Delays", "clock.badge.exclamationmark.fill", .orange, on: true)
                    alert("Suspensions", "xmark.octagon.fill", .red, on: true)
                    alert("Service changes", "arrow.triangle.branch", .purple, on: true)
                    alert("Notices", "info.circle.fill", .blue, on: false)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .background(faint, in: card)
                .padding(.bottom, 14)

                cardLabel("Diagnostics")
                VStack(spacing: 0) {
                    switchRow("Share Diagnostics", symbol: "stethoscope", isOn: false)
                    divider
                    iconRow("Run Setup Again", symbol: "arrow.counterclockwise") { EmptyView() }
                }
                .background(faint, in: card)
                .padding(.bottom, 14)

                cardLabel("Data Sources")
                VStack(spacing: 0) {
                    linkRow("MTA", symbol: "tram.fill")
                    divider
                    linkRow("New York State Open Data", symbol: "stairs")
                    divider
                    linkRow("NYC Open Data", symbol: "figure.walk")
                    divider
                    linkRow("OpenStreetMap", symbol: "light.beacon.max.fill", credit: "© OpenStreetMap contributors")
                    divider
                    linkRow("Citi Bike", symbol: "bicycle")
                }
                .background(faint, in: card)
            }
            .padding(.horizontal, margin)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    private func bullet(_ name: String, _ color: Color) -> some View {
        Text(name)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color, in: Circle())
    }

    private func alert(_ name: String, _ symbol: String, _ tint: Color, on: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 48, height: 38)
                .background(on ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary), in: Capsule())
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Settings") {
    MockSettings()
}
