import ActivityKit
import SwiftUI
import WidgetKit

/// The countdown to one train on the Lock Screen and in the Dynamic Island,
/// started from the app ("I'm on my way") or a shortcut.
struct TrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivityAttributes.self) { context in
            CountdownBanner(context: context)
                .activityBackgroundTint(Color.boardBlack)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        LineBullet(route: context.attributes.selection.route, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.attributes.stationName).font(.caption.bold()).lineLimit(1)
                            Text(context.attributes.heading).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(context.state.isLive ? Color.liveGreen : .white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(summary(context)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button(intent: RefreshCountdownIntent()) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh")
                    }
                }
            } compactLeading: {
                LineBullet(route: context.attributes.selection.route, size: 20)
            } compactTrailing: {
                countdown(context)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 52)
                    .foregroundStyle(context.state.isLive ? Color.liveGreen : .white)
            } minimal: {
                LineBullet(route: context.attributes.selection.route, size: 20)
            }
            .keylineTint(Color(hex: LineStyle.of(context.attributes.selection.route).color))
        }
    }
}

private struct CountdownBanner: View {
    let context: ActivityViewContext<TrainActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LineBullet(route: context.attributes.selection.route, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.attributes.stationName).font(.headline).foregroundStyle(.white)
                    Text(context.attributes.heading).font(.caption).foregroundStyle(Color.boardGray)
                }
                .lineLimit(1)
                Spacer()
                Button(intent: RefreshCountdownIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.boardGray)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")
            }
            countdown(context)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(context.state.isLive ? Color.liveGreen : .white)
                .multilineTextAlignment(.leading)
            Text(summary(context))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
            HStack {
                if let notice = context.state.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(context.isStale ? "This train is due. Tap refresh for new times." : "Updated \(Spoken.clock(context.state.updated))")
                    .font(.caption)
                    .foregroundStyle(Color.boardGray)
            }
        }
        .padding(16)
    }
}

/// Counts down to the train, live, and stops at 0:00.
private func countdown(_ context: ActivityViewContext<TrainActivityAttributes>) -> Text {
    let state = context.state
    return Text(timerInterval: min(state.updated, state.train)...state.train, countsDown: true)
}

/// "8:22 AM · Forest Hills · then 8:31, 8:39"
private func summary(_ context: ActivityViewContext<TrainActivityAttributes>) -> String {
    let state = context.state
    var parts = [Spoken.clock(state.train)]
    if let terminal = state.terminal { parts.append(terminal) }
    if !state.following.isEmpty { parts.append("then " + state.following.map(\.clock).joined(separator: ", ")) }
    return parts.joined(separator: " · ")
}
