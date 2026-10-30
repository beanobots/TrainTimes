import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Lock Screen / Dynamic Island countdown to one train. Started from the app, a widget's walk
/// button, or a shortcut.
struct TrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivityAttributes.self) { context in
            Group {
                if let walk = shownState(context).walk {
                    WalkBanner(context: context, walk: walk)
                } else {
                    CountdownBanner(context: context)
                }
            }
                // Always dark; the widget colours adapt to it
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color.boardBlack)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // All below the camera so station and countdown share a row; inset from the edges
                DynamicIslandExpandedRegion(.bottom) {
                    if let walk = shownState(context).walk {
                        WalkIsland(context: context, walk: walk)
                    } else {
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
                }
            } compactLeading: {
                if let walk = shownState(context).walk {
                    // The next turn and how far, "↰ 250 ft"; the arrow alone where there's no room
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            Image(systemName: walk.symbol).font(.caption.weight(.bold)).foregroundStyle(Color.walkBlue)
                            // On the train, then off it, beside the countdown to getting off or there
                            Text(walk.phase == .riding ? "On" : walk.phase == .off ? "Off" : walk.distance)
                                .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
                                .fixedSize()
                        }
                        Image(systemName: walk.symbol).font(.caption.weight(.bold)).foregroundStyle(Color.walkBlue)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(walk.distance), \(walk.instruction)")
                } else {
                    // The mark goes here; the compact countdown has no room for it
                    HStack(spacing: 2) {
                        LineBullet(route: trainRoute(context), size: 20)
                        statusMark(context, size: 10)
                            .foregroundStyle(statusColor(context))
                    }
                }
            } compactTrailing: {
                if let walk = shownState(context).walk {
                    // The train and its minutes ("R 6:00"), the minutes alone where there's no
                    // room; getting off on it; there, walking out. Sized to the digits, as a
                    // timer takes all the width it's offered.
                    let minutes = sizedWalkCountdown(context, walk: walk)
                        .font(.caption.weight(.semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            if walk.phase != .fromTrain && walk.phase != .off {
                                LineBullet(route: trainRoute(context), size: 16)
                            }
                            minutes
                        }
                        minutes
                    }
                    .foregroundStyle([.fromTrain, .riding, .off].contains(walk.phase) ? .white : statusColor(context))
                } else {
                    countdown(context)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 52)
                        .foregroundStyle(statusColor(context))
                        .accessibilityValue(status(context))
                }
            } minimal: {
                if let walk = shownState(context).walk {
                    Image(systemName: walk.symbol).font(.caption.weight(.bold)).foregroundStyle(Color.walkBlue)
                        .accessibilityLabel("\(walk.distance), \(walk.instruction)")
                } else {
                    // No room for the countdown; VoiceOver still gives the due time
                    LineBullet(route: trainRoute(context), size: 20)
                        .accessibilityValue("\(status(context)), \(Spoken.clock(shownState(context).train))")
                }
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

/// A countdown from New Trip's Go: the next turn over the train, as on the walking screen; on the
/// train, a countdown to getting off; then the turns to the end.
private struct WalkBanner: View {
    let context: ActivityViewContext<TrainActivityAttributes>
    let walk: WalkState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TurnRow(walk: walk, size: 44)
            Divider().overlay(Color.boardGray.opacity(0.4))
            HStack(spacing: 10) {
                walkFooter(context, walk: walk)
                Spacer(minLength: 0)
                walkButtons(context, walk: walk)
                    // VoiceOver reads these after the walk
                    .accessibilityElement(children: .contain)
                    .accessibilitySortPriority(-1)
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

/// The expanded Dynamic Island's walk: the turn, then the train and the buttons.
private struct WalkIsland: View {
    let context: ActivityViewContext<TrainActivityAttributes>
    let walk: WalkState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TurnRow(walk: walk, size: 38)
            HStack(spacing: 10) {
                walkFooter(context, walk: walk)
                Spacer(minLength: 0)
                walkButtons(context, walk: walk)
            }
        }
        .padding(.horizontal, 8)
    }
}

/// A walk's buttons: "I'm on the train" at the station or the change, ↻ while there's a train
/// to catch or ride, and the lit walk button, which ends the walk.
private func walkButtons(_ context: ActivityViewContext<TrainActivityAttributes>, walk: WalkState) -> some View {
    HStack(spacing: 6) {
        if walk.phase == .atStation || walk.phase == .changing {
            BoardButton(route: trainRoute(context))
        }
        if walk.phase != .fromTrain && walk.phase != .off {
            RefreshButton(route: trainRoute(context))
        }
        WalkButton(intent: StopCountdownIntent(), route: trainRoute(context), running: true)
            .accessibilityLabel("End the walk")
    }
    .environment(\.colorScheme, .dark)
}

/// The next turn, big: its arrow in a blue tile, how far, and what to do.
private struct TurnRow: View {
    let walk: WalkState
    let size: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: walk.symbol)
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.walkBlue, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(walk.distance)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                // A little smaller rather than cut off: "Down the stairs at the NE corner of …"
                Text(walk.instruction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                // A faster trip from here over the turn after
                if let line = walk.faster ?? walk.detail {
                    Text(line).font(.caption.weight(walk.faster == nil ? .regular : .semibold))
                        .foregroundStyle(walk.faster == nil ? Color.boardGray : .orange)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Under the turn: the train's countdown and the time to spare, which part to board; on the
/// train, the countdown to getting off; walking out, when you'll get there.
@ViewBuilder
private func walkFooter(_ context: ActivityViewContext<TrainActivityAttributes>, walk: WalkState) -> some View {
    switch walk.phase {
    case .toTrain, .atStation, .changing:
        HStack(spacing: 8) {
            LineBullet(route: trainRoute(context), size: 28)
            VStack(alignment: .leading, spacing: 0) {
                markedCountdown(context, markSize: 12, size: 24)
                    .foregroundStyle(statusColor(context))
                Text(walkNote(walk) ?? context.attributes.heading)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(walkNoteColor(walk))
                    .lineLimit(1)
            }
        }
    case .riding:
        HStack(spacing: 8) {
            LineBullet(route: trainRoute(context), size: 28)
            VStack(alignment: .leading, spacing: 0) {
                if let getOff = walk.getOff, getOff > .now {
                    Text(timerInterval: Date.now...getOff, countsDown: true)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Text("to \(walk.getOffAt ?? "your stop")")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.boardGray).lineLimit(1)
            }
        }
    case .fromTrain, .off:
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white, .red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(walk.endName).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                if let arrives = walk.arrives {
                    Text("Arrive \(Spoken.clock(arrives))").font(.caption.weight(.medium)).foregroundStyle(Color.boardGray)
                }
            }
        }
    }
}

/// "2 min to spare", "You'll miss it", or which part to board once you're there (at a change,
/// once there's no walk to it left to time).
private func walkNote(_ walk: WalkState) -> String? {
    let board = walk.part.map { "Board near the \($0)" }
    if walk.phase == .atStation || (walk.phase == .changing && walk.spare == nil) { return board }
    guard let spare = walk.spare else { return nil }
    return spare < 0 ? "You'll miss it · next train" : "\(spare) min to spare"
}

private func walkNoteColor(_ walk: WalkState) -> Color {
    guard walk.phase == .toTrain || walk.phase == .changing, let spare = walk.spare else { return .boardGray }
    return spare >= 1 ? .liveGreen : .orange
}

/// `walkCountdown` sized to its digits by a hidden placeholder, so it can sit beside a bullet.
private func sizedWalkCountdown(_ context: ActivityViewContext<TrainActivityAttributes>, walk: WalkState) -> some View {
    return Text(TimerText.placeholder(seconds: (walkTarget(context, walk: walk) ?? .now).timeIntervalSinceNow))
        .hidden()
        .overlay(alignment: .trailing) {
            walkCountdown(context, walk: walk).multilineTextAlignment(.trailing)
        }
        .monospacedDigit()
}

/// The compact island's countdown: to the train, to getting off on it, or to getting there.
private func walkCountdown(_ context: ActivityViewContext<TrainActivityAttributes>, walk: WalkState) -> Text {
    guard let target = walkTarget(context, walk: walk), target > .now else {
        return Text(walk.phase == .fromTrain || walk.phase == .off ? "Now" : "Due")
    }
    return Text(timerInterval: Date.now...target, countsDown: true)
}

/// What the compact island counts down to: the train to catch, getting off the one you're on,
/// or getting there.
private func walkTarget(_ context: ActivityViewContext<TrainActivityAttributes>, walk: WalkState) -> Date? {
    switch walk.phase {
    case .toTrain, .atStation, .changing: shownState(context).train
    case .riding: walk.getOff
    case .fromTrain, .off: walk.arrives
    }
}

extension Color {
    /// The walking screen's blue, for turns.
    static let walkBlue = Color(red: 0.0, green: 0.48, blue: 1.0)
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

/// Whole minutes until `date`, updating as the clock does ("9 minutes").
private func minutesLeft(until date: Date) -> Text {
    Text(.currentDate, format: .offset(to: date, allowedFields: [.minute], maxFieldCount: 1, sign: .never))
}

// MARK: Previews

/// Park Slope to The Town Hall on the R, as New Trip's Go counts it down: walking to 4 Av-9 St,
/// at its stairs, on the train, and walking out at Times Sq-42 St.
private extension TrainActivityAttributes {
    static let walkPreview = TrainActivityAttributes(
        selection: Selection(stationID: "R33", routes: ["R"], direction: .north),
        stationName: "4 Av-9 St", heading: "Manhattan", ends: .now.addingTimeInterval(2 * 60 * 60))
}

private extension CountdownState {
    static func walkPreview(_ walk: WalkState, route: String = "R") -> CountdownState {
        CountdownState(train: .now.addingTimeInterval(6 * 60), trip: route, isLive: true, terminal: "Forest Hills-71 Av",
                       following: [.now.addingTimeInterval(14 * 60)], notice: nil, updated: .now, route: route,
                       followingRoutes: [route], walk: walk)
    }

    static let walkPreviews: [CountdownState] = [
        walkPreview(WalkState(phase: .toTrain, symbol: "arrow.turn.up.left", distance: "250 ft",
                              instruction: "Take a left onto 4th Ave",
                              detail: "Then down the stairs at the NE corner of 4 Av & 9 St", spare: 2, part: "front",
                              endName: "The Town Hall")),
        walkPreview(WalkState(phase: .atStation, symbol: "stairs", distance: "Here",
                              instruction: "Down the stairs at the NE corner of 4 Av & 9 St", detail: "Manhattan-bound",
                              part: "front", endName: "The Town Hall")),
        walkPreview(WalkState(phase: .riding, symbol: "tram.fill", distance: "On the train",
                              instruction: "Get off at Times Sq-42 St", detail: "Ride in the front", part: "front",
                              getOff: .now.addingTimeInterval(27 * 60), getOffAt: "Times Sq-42 St",
                              endName: "The Town Hall")),
        walkPreview(WalkState(phase: .fromTrain, symbol: "arrow.turn.up.right", distance: "230 ft",
                              instruction: "Take a right onto W 43rd St", detail: "Then arrive at the destination",
                              endName: "The Town Hall", arrives: .now.addingTimeInterval(3 * 60))),
        // Changing at DeKalb Av to the Q, its countdown in place of the R's
        walkPreview(WalkState(phase: .changing, symbol: "figure.walk", distance: "Change",
                              instruction: "Walk to the Q, 3 min", detail: "Manhattan-bound", spare: 1, part: "middle",
                              endName: "The Town Hall"), route: "Q"),
        // On the train with the app asleep, once it's due: the way up, by itself
        walkPreview(WalkState(phase: .riding, symbol: "tram.fill", distance: "On the train",
                              instruction: "Get off at Times Sq-42 St", detail: "Ride in the front", part: "front",
                              getOff: .now.addingTimeInterval(-30), getOffAt: "Times Sq-42 St",
                              endName: "The Town Hall", arrives: .now.addingTimeInterval(4 * 60),
                              next: "Up the stairs to the NE corner of Broadway & 41 St", nextSymbol: "stairs",
                              nextNote: "Tap for the turns to The Town Hall")),
    ]
}

#Preview("Walk · Lock Screen", as: .content, using: TrainActivityAttributes.walkPreview) {
    TrainLiveActivity()
} contentStates: {
    CountdownState.walkPreviews[0]
    CountdownState.walkPreviews[1]
    CountdownState.walkPreviews[2]
    CountdownState.walkPreviews[3]
    CountdownState.walkPreviews[4]
    CountdownState.walkPreviews[5]
}

#Preview("Walk · Island compact", as: .dynamicIsland(.compact), using: TrainActivityAttributes.walkPreview) {
    TrainLiveActivity()
} contentStates: {
    CountdownState.walkPreviews[0]
    CountdownState.walkPreviews[1]
    CountdownState.walkPreviews[2]
    CountdownState.walkPreviews[3]
    CountdownState.walkPreviews[4]
    CountdownState.walkPreviews[5]
}

#Preview("Walk · Island expanded", as: .dynamicIsland(.expanded), using: TrainActivityAttributes.walkPreview) {
    TrainLiveActivity()
} contentStates: {
    CountdownState.walkPreviews[0]
    CountdownState.walkPreviews[1]
    CountdownState.walkPreviews[2]
    CountdownState.walkPreviews[3]
    CountdownState.walkPreviews[4]
    CountdownState.walkPreviews[5]
}

#Preview("Walk · Island minimal", as: .dynamicIsland(.minimal), using: TrainActivityAttributes.walkPreview) {
    TrainLiveActivity()
} contentStates: {
    CountdownState.walkPreviews[0]
    CountdownState.walkPreviews[3]
}
