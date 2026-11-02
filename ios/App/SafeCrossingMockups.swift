#if DEBUG
import SwiftUI

// Throwaway mockups: safe crossings in the step-by-step walking directions. Delete once one's built.

/// What a crossing has, as `Sidewalks` would hand it on.
private enum MockSignal {
    case leading, exclusive, signal, none

    var short: String {
        switch self {
        case .leading: "Walk first"
        case .exclusive: "All-way walk"
        case .signal: "At the light"
        case .none: "No light"
        }
    }

    var long: String {
        switch self {
        case .leading: "At the light · the walk signal comes on before the cars’ green"
        case .exclusive: "At the light · every car stops while you cross"
        case .signal: "At the light"
        case .none: "No light here · look both ways"
        }
    }
}

/// The real TurnCard's look (it's private to WalkingView), with room for a crossing.
private struct MockTurnCard<Extra: View>: View {
    let icon: String
    var tile: Color = .accentColor
    let distance: String
    let instruction: String
    var then: String?
    var thenDistance: String?
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(distance).font(.title.weight(.bold)).monospacedDigit()
                    Text(instruction).font(.title3.weight(.semibold)).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            extra
            if let then {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(then)
                    Spacer(minLength: 8)
                    if let thenDistance { Text(thenDistance).monospacedDigit() }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
    }
}

/// A walk signal's little lit figure, as on the pole: white on black.
private struct WalkLight: View {
    var signal: MockSignal = .signal
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: signal == .none ? "exclamationmark.triangle.fill" : "figure.walk")
            .font(.system(size: size * 0.62, weight: .bold))
            .foregroundStyle(signal == .none ? .black : .white)
            .frame(width: size, height: size)
            .background(signal == .none ? Color.yellow : Color.black, in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}

/// The map's green street sign, with what the crossing has hung under it.
private struct MockStreetSign: View {
    let name: String
    let signal: MockSignal

    private static let green = Color(red: 0, green: 0.42, blue: 0.25)

    var body: some View {
        VStack(spacing: 0) {
            Text(name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Self.green, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 1.5).stroke(.white, lineWidth: 1.5))
            HStack(spacing: 4) {
                WalkLight(signal: signal, size: 16)
                Text(signal.short).font(.caption2.weight(.bold))
            }
            .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 3)
            Rectangle().fill(.secondary).frame(width: 2, height: 24)
        }
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

/// A fake map under the cards: blocks and streets.
private struct MockMap: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.93)))
            for x in stride(from: -40.0, to: size.width, by: 150) {
                for y in stride(from: -60.0, to: size.height, by: 240) {
                    let block = CGRect(x: x + 22, y: y + 22, width: 106, height: 196)
                    context.fill(Path(roundedRect: block, cornerRadius: 6), with: .color(Color(white: 0.84)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: A — the crossing as its own step

/// The fitted walk changes sides where Apple Maps' text says nothing: give that its own step, in
/// order with the turns, its card saying where and what the light does.
private struct OptionA: View {
    var body: some View {
        ZStack(alignment: .top) {
            MockMap()
            VStack(spacing: 10) {
                MockTurnCard(icon: "figure.walk", distance: "40 m", instruction: "Cross 4th Ave at 9th St",
                             then: "Then take a left onto 4th Ave", thenDistance: "120 m") {
                    HStack(spacing: 8) {
                        WalkLight(signal: .leading, size: 22)
                        Text(MockSignal.leading.long)
                            .font(.subheadline.weight(.medium))
                    }
                }
                Spacer()
                VStack(spacing: 6) {
                    MockStreetSign(name: "4th Ave", signal: .leading)
                }
                .padding(.bottom, 220)
            }
            .padding(.top, 8)
        }
    }
}

// MARK: B — a note on the turn's card

/// Apple Maps' steps as they are; the card's foot names the next crossing ahead and its light,
/// changing as you pass each one.
private struct OptionB: View {
    var body: some View {
        ZStack(alignment: .top) {
            MockMap()
            VStack(spacing: 10) {
                MockTurnCard(icon: "arrow.turn.up.left", distance: "160 m", instruction: "Take a left onto 4th Ave",
                             then: nil) {
                    Divider()
                    HStack(spacing: 10) {
                        WalkLight(signal: .leading, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Cross 4th Ave at 9th St").font(.subheadline.weight(.semibold))
                            Text("Walk signal comes on first").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("40 m").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer()
                MockStreetSign(name: "4th Ave", signal: .leading)
                    .padding(.bottom, 220)
            }
            .padding(.top, 8)
        }
    }
}

// MARK: Signs on the map

private struct SignKinds: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            MockStreetSign(name: "4th Ave", signal: .leading)
            MockStreetSign(name: "Broadway", signal: .exclusive)
            MockStreetSign(name: "9th St", signal: .signal)
            MockStreetSign(name: "Prospect Pl", signal: .none)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.9))
    }
}

// MARK: Lock Screen

/// The Lock Screen's walking banner as `TurnRow` draws it, the crossing as the step.
private struct LockScreenRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("40 m").font(.title3.weight(.bold)).monospacedDigit()
                    Text("Cross 4th Ave at the light").font(.subheadline.weight(.semibold))
                    Text("Walk signal comes on first").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("4 min").font(.title3.weight(.bold))
                    Text("to spare").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(20)
        .background(LinearGradient(colors: [.indigo, .teal], startPoint: .top, endPoint: .bottom))
    }
}

#Preview("A: crossing as a step") { OptionA() }
#Preview("B: note on the turn") { OptionB() }
#Preview("Signs") { SignKinds() }
#Preview("Lock Screen") { LockScreenRow() }
#endif
