import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Lock Screen / Dynamic Island countdown to one train. Started from the app, a widget's walk
/// button, or a shortcut.
struct TrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivityAttributes.self) { context in
            CountdownBanner(context: context)
                // Always dark; the widget colours adapt to it
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color.boardBlack)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // All below the camera so station and countdown share a row; inset from the edges
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
                                .foregroundStyle(statusColor(context))
                        }
                        .padding(.horizontal, 8)
                        if let notice = shownState(context).notice {
                            noticeLabel(notice)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                        }
                        HStack(spacing: 8) {
                            RefreshButton(route: trainRoute(context), fills: true)
                            WalkButton(intent: StopCountdownIntent(), route: trainRoute(context), running: true, fills: true)
                        }
                        .environment(\.colorScheme, .dark)
                        .padding(.horizontal, 24)
                    }
                }
            } compactLeading: {
                // The mark goes here; the compact countdown has no room for it
                HStack(spacing: 2) {
                    LineBullet(route: trainRoute(context), size: 20)
                    statusMark(context, size: 10)
                        .foregroundStyle(statusColor(context))
                }
            } compactTrailing: {
                countdown(context)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 52)
                    .foregroundStyle(statusColor(context))
                    .accessibilityValue(status(context))
            } minimal: {
                // No room for the countdown; VoiceOver still gives the due time
                LineBullet(route: trainRoute(context), size: 20)
                    .accessibilityValue("\(status(context)), \(Spoken.clock(shownState(context).train))")
            }
            .keylineTint(LineStyle.of(trainRoute(context)).swiftUIColor)
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
                .accessibilityElement(children: .combine)
                Spacer()
                buttons(context)
                    // VoiceOver reads these after the countdown
                    .accessibilityElement(children: .contain)
                    .accessibilitySortPriority(-1)
            }
            // Mark first: the countdown takes all the width it's given
            HStack(spacing: 6) {
                statusMark(context, size: 18)
                countdown(context)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(statusColor(context))
            .accessibilityElement(children: .combine)
            .accessibilityValue(status(context))
            summary(context)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
                .accessibilityLabel(spokenSummary(context))
            HStack {
                if let notice = shownState(context).notice {
                    noticeLabel(notice)
                }
                Spacer()
                // Stale once the train is due, unless it has moved on to a next train, or once
                // its 30 minutes are up (the app or push server then ends it)
                Text(context.attributes.ends.map { $0 <= .now } ?? false
                     ? "This countdown has ended."
                     : context.isStale && shownState(context).train <= .now
                     ? "This train is due. Tap refresh for new times."
                     : "Updated \(Spoken.clock(shownState(context).updated))")
                    .font(.caption)
                    .foregroundStyle(Color.boardGray)
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

/// The state to draw, moved on to the next train once the current one has gone.
private func shownState(_ context: ActivityViewContext<TrainActivityAttributes>) -> TrainActivityAttributes.ContentState {
    context.state.movedOn(at: .now)
}

/// ↻ and a lit walk button (stops the countdown).
private func buttons(_ context: ActivityViewContext<TrainActivityAttributes>) -> some View {
    HStack(spacing: 6) {
        RefreshButton(route: trainRoute(context))
        WalkButton(intent: StopCountdownIntent(), route: trainRoute(context), running: true)
    }
    .environment(\.colorScheme, .dark)
}

/// Live countdown to the train, stopping at 0:00.
private func countdown(_ context: ActivityViewContext<TrainActivityAttributes>) -> Text {
    let state = shownState(context)
    return Text(timerInterval: min(state.updated, state.train)...state.train, countsDown: true)
}

/// The countdown with its live/scheduled mark beside it. A timer text takes all offered width
/// and iOS drops anything concatenated to it, so a hidden placeholder sizes it to its digits.
private func markedCountdown(_ context: ActivityViewContext<TrainActivityAttributes>, markSize: CGFloat, size: CGFloat) -> some View {
    HStack(spacing: 4) {
        statusMark(context, size: markSize)
        Text(TimerText.placeholder(seconds: shownState(context).train.timeIntervalSinceNow))
            .hidden()
            .overlay(alignment: .trailing) {
                countdown(context).multilineTextAlignment(.trailing)
            }
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(status(context))
}

/// Live/scheduled mark per Settings or Differentiate Without Color; VoiceOver reads `status`.
private func statusMark(_ context: ActivityViewContext<TrainActivityAttributes>, size: CGFloat) -> some View {
    let marks = SharedStore.loadSettings().timeMarks(withoutColor: UIAccessibility.shouldDifferentiateWithoutColor)
    return StatusMark(isLive: shownState(context).isLive, marks: marks, size: size)
        .accessibilityHidden(true)
}

/// Green for a live prediction, white for a timetable time.
private func statusColor(_ context: ActivityViewContext<TrainActivityAttributes>) -> Color {
    shownState(context).isLive ? .liveGreen : .white
}

/// "Live" or "Scheduled", which the countdown otherwise shows only by colour.
private func status(_ context: ActivityViewContext<TrainActivityAttributes>) -> String {
    shownState(context).isLive ? "Live" : "Scheduled"
}

/// A service alert (or "no trains") with its kind's symbol and colour, as on the widgets.
private func noticeLabel(_ notice: String) -> some View {
    let kind = Notice.Kind(label: notice)
    return Label(notice, systemImage: kind?.symbol ?? "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(kind?.tint ?? .orange)
        .accessibilityLabel("Alert: \(notice)")
}

/// The counted-down train's line, which may be another line running on yours.
private func trainRoute(_ context: ActivityViewContext<TrainActivityAttributes>) -> String {
    shownState(context).route ?? context.attributes.selection.firstRoute
}

/// "8:22 AM · then 9 minutes, 17 minutes", each later train's minutes counting down by
/// themselves, as the activity only redraws when pushed. Later trains on another line are
/// labelled ("then R 9 minutes").
private func summary(_ context: ActivityViewContext<TrainActivityAttributes>) -> Text {
    let state = shownState(context)
    var text = Text(verbatim: Spoken.clock(state.train))
    guard !state.following.isEmpty else { return text }
    text = Text("\(text) · then ")
    for index in state.following.indices {
        if index > 0 { text = Text("\(text)\(Text(verbatim: ", "))") }
        if let line = otherLine(context, index: index, spoken: false) {
            text = Text("\(text)\(Text(verbatim: line + " "))")
        }
        text = Text("\(text)\(minutesLeft(until: state.following[index]))")
    }
    return text
}

/// The summary for VoiceOver, with clock times as they don't go stale: "8:22 AM, then
/// 8:31 AM, 42 St Shuttle 8:39 AM".
private func spokenSummary(_ context: ActivityViewContext<TrainActivityAttributes>) -> String {
    let state = shownState(context)
    let times = state.following.indices.map { index in
        [otherLine(context, index: index, spoken: true), Spoken.clock(state.following[index])]
            .compactMap { $0 }.joined(separator: " ")
    }
    return ([Spoken.clock(state.train)] + (times.isEmpty ? [] : ["then " + times.joined(separator: ", ")]))
        .joined(separator: ", ")
}

/// The line of the `index`th later train if it's not the counted-down train's: its letter, or
/// when `spoken`, its full name.
private func otherLine(_ context: ActivityViewContext<TrainActivityAttributes>, index: Int, spoken: Bool) -> String? {
    guard let routes = shownState(context).followingRoutes, index < routes.count,
          routes[index] != trainRoute(context) else { return nil }
    return spoken ? Lines.name(of: routes[index]) : LineStyle.of(routes[index]).label
}

/// Whole minutes until `date`, updating as the clock does ("9 minutes"). Before iOS 18, the
/// system's relative style ("9 min, 12 sec").
private func minutesLeft(until date: Date) -> Text {
    if #available(iOS 18.0, *) {
        return Text(.currentDate, format: .offset(to: date, allowedFields: [.minute], maxFieldCount: 1, sign: .never))
    }
    return Text(date, style: .relative)
}
