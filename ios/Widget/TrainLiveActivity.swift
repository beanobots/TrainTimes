import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// The countdown to one train on the Lock Screen and in the Dynamic Island,
/// started from the app ("I'm on my way"), a widget's walk button or a shortcut.
struct TrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivityAttributes.self) { context in
            CountdownBanner(context: context)
                // Always on dark, which the widgets' colours follow
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color.boardBlack)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // All of it below the camera, so the station and the countdown share
                // a row; inset from the island's rounded sides and corners
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    LineBullet(route: trainRoute(context), size: 24)
                                    Text(context.attributes.stationName).font(.subheadline.bold())
                                }
                                Text(context.attributes.heading).font(.caption).foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 8)
                            markedCountdown(context, markSize: 14, size: 30)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(shownState(context).isLive ? Color.liveGreen : .white)
                        }
                        .padding(.horizontal, 8)
                        HStack(spacing: 8) {
                            RefreshButton(route: trainRoute(context), fills: true)
                            WalkButton(intent: StopCountdownIntent(), route: trainRoute(context), running: true, fills: true)
                        }
                        .environment(\.colorScheme, .dark)
                        .padding(.horizontal, 24)
                    }
                }
            } compactLeading: {
                LineBullet(route: trainRoute(context), size: 20)
            } compactTrailing: {
                countdown(context)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 52)
                    .foregroundStyle(shownState(context).isLive ? Color.liveGreen : .white)
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
            // The mark goes first: the countdown takes all the width it's given
            HStack(spacing: 6) {
                if marksLive(context) {
                    LiveMark(size: 18)
                } else if marksScheduled(context) {
                    ScheduledMark(size: 18)
                }
                countdown(context)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(shownState(context).isLive ? Color.liveGreen : .white)
            Text(summary(context))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
            HStack {
                if let notice = shownState(context).notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                // Stale once its train is due; with a next train it's moved on to that
                Text(context.isStale && shownState(context).train <= .now
                     ? "This train is due. Tap refresh for new times."
                     : "Updated \(Spoken.clock(shownState(context).updated))")
                    .font(.caption)
                    .foregroundStyle(Color.boardGray)
            }
        }
        .padding(16)
    }
}

extension TrainActivityAttributes.ContentState {
    /// Once the train has gone, the first of the following trains still to
    /// come, as though it were the one counted down to; or, with none, as it
    /// is. The countdown is out of date as its train is due, and iOS redraws
    /// it then, so it moves on without the app. Only once, though: nothing
    /// redraws it again until the app updates it. A following train's trip
    /// and where it ends aren't known; it's taken to be live if this one was.
    func movedOn(at now: Date) -> Self {
        guard train <= now, let index = following.firstIndex(where: { $0 > now }) else { return self }
        var state = self
        state.train = following[index]
        state.trip = ""
        state.terminal = nil
        if let routes = followingRoutes, index < routes.count { state.route = routes[index] }
        state.following = Array(following.dropFirst(index + 1))
        state.followingRoutes = followingRoutes.map { Array($0.dropFirst(index + 1)) }
        return state
    }
}

/// The countdown's state as it's drawn: moved on to the next train once its
/// own has gone.
private func shownState(_ context: ActivityViewContext<TrainActivityAttributes>) -> TrainActivityAttributes.ContentState {
    context.state.movedOn(at: .now)
}

/// ↻ and a lit walk button, which stops the countdown.
private func buttons(_ context: ActivityViewContext<TrainActivityAttributes>) -> some View {
    HStack(spacing: 6) {
        RefreshButton(route: trainRoute(context))
        WalkButton(intent: StopCountdownIntent(), route: trainRoute(context), running: true)
    }
    .environment(\.colorScheme, .dark)
}

/// Counts down to the train, live, and stops at 0:00.
private func countdown(_ context: ActivityViewContext<TrainActivityAttributes>) -> Text {
    let state = shownState(context)
    return Text(timerInterval: min(state.updated, state.train)...state.train, countsDown: true)
}

/// The countdown with its live or scheduled mark right beside it. A live timer
/// takes all the width it's offered, and iOS drops anything joined to its text,
/// so it's held to the width of its digits by a hidden stand-in for them.
private func markedCountdown(_ context: ActivityViewContext<TrainActivityAttributes>, markSize: CGFloat, size: CGFloat) -> some View {
    let remaining = shownState(context).train.timeIntervalSinceNow
    let placeholder = remaining >= 3600 ? "0:00:00" : remaining >= 600 ? "00:00" : "0:00"
    return HStack(spacing: 4) {
        if marksLive(context) {
            LiveMark(size: markSize)
        } else if marksScheduled(context) {
            ScheduledMark(size: markSize)
        }
        Text(placeholder)
            .hidden()
            .overlay(alignment: .trailing) {
                countdown(context).multilineTextAlignment(.trailing)
            }
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
    }
}

/// Whether the countdown's train is live and Settings › Mark live times, or the
/// phone's Differentiate Without Color, is on, as on the widgets.
private func marksLive(_ context: ActivityViewContext<TrainActivityAttributes>) -> Bool {
    shownState(context).isLive
        && (UIAccessibility.shouldDifferentiateWithoutColor || SharedStore.loadSettings().marksLiveTimes)
}

/// Whether the countdown's train is a timetable time and Settings › Mark
/// scheduled times is on, as on the widgets.
private func marksScheduled(_ context: ActivityViewContext<TrainActivityAttributes>) -> Bool {
    !shownState(context).isLive && SharedStore.loadSettings().marksScheduledTimes
}

/// The line of the train it's counting down to, which can be another one running on yours.
private func trainRoute(_ context: ActivityViewContext<TrainActivityAttributes>) -> String {
    shownState(context).route ?? context.attributes.selection.firstRoute
}

/// "8:22 AM · Forest Hills · then 8:31, 8:39", naming the line of any later
/// train that isn't on this one's: "then R 8:31, 8:39".
private func summary(_ context: ActivityViewContext<TrainActivityAttributes>) -> String {
    let state = shownState(context)
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
