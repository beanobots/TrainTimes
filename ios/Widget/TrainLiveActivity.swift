import ActivityKit
import SwiftUI
import WidgetKit

/// The countdown to one train on the Lock Screen and in the Dynamic Island,
/// started from the app ("I'm on my way"), a widget's walk button or a shortcut.
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
                        LineBullet(route: trainRoute(context), size: 24)
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
                        buttons(context)
                    }
                }
            } compactLeading: {
                LineBullet(route: trainRoute(context), size: 20)
            } compactTrailing: {
                countdown(context)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 52)
                    .foregroundStyle(context.state.isLive ? Color.liveGreen : .white)
            } minimal: {
                LineBullet(route: trainRoute(context), size: 20)
            }
            .keylineTint(Color(hex: LineStyle.of(trainRoute(context)).color))
        }
    }
}

private struct CountdownBanner: View {
    let context: ActivityViewContext<TrainActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LineBullet(route: trainRoute(context), size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.attributes.stationName).font(.headline).foregroundStyle(.white)
                    Text(context.attributes.heading).font(.caption).foregroundStyle(Color.boardGray)
                }
                .lineLimit(1)
                Spacer()
                buttons(context)
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

/// ↻ and a lit walk button, which stops the countdown.
private func buttons(_ context: ActivityViewContext<TrainActivityAttributes>) -> some View {
    HStack(spacing: 6) {
        RefreshButton()
        WalkButton(intent: StopCountdownIntent(), route: trainRoute(context), isOn: true)
    }
}

/// Counts down to the train, live, and stops at 0:00.
private func countdown(_ context: ActivityViewContext<TrainActivityAttributes>) -> Text {
    let state = context.state
    return Text(timerInterval: min(state.updated, state.train)...state.train, countsDown: true)
}

/// The line of the train it's counting down to, which can be another one running on yours.
private func trainRoute(_ context: ActivityViewContext<TrainActivityAttributes>) -> String {
    context.state.route ?? context.attributes.selection.firstRoute
}

/// "8:22 AM · Forest Hills · then 8:31, 8:39", naming the line of any later
/// train that isn't on this one's: "then R 8:31, 8:39".
private func summary(_ context: ActivityViewContext<TrainActivityAttributes>) -> String {
    let state = context.state
    let route = trainRoute(context)
    var parts = [Spoken.clock(state.train)]
    if let terminal = state.terminal { parts.append(terminal) }
    if !state.following.isEmpty {
        let times = state.following.indices.map { index -> String in
            let time = state.following[index].clock
            guard let routes = state.followingRoutes, index < routes.count, routes[index] != route else { return time }
            return "\(LineStyle.of(routes[index]).label) \(time)"
        }
        parts.append("then " + times.joined(separator: ", "))
    }
    return parts.joined(separator: " · ")
}
