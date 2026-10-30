import SwiftUI
import WidgetKit

/// Transit Directions during a walk from New Trip's Go, on the train or walking out from it
/// (`WalkStage`): where to get off and when, then what to do there; walking out, where to and
/// when you'll be there. A tap opens the walk in the app, for its turns.
struct WalkStageView: View {
    let stage: WalkStage
    /// When it's drawn: a timeline entry's date, as the widget redraws at getting off.
    let date: Date

    /// On the train once it's due where you get off: what to do there.
    private var isOff: Bool {
        stage.phase == .riding && stage.getOff.map { $0 <= date } == true && stage.next != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    // A little smaller rather than cut off: "Off at Atlantic Av-Barclays Ctr"
                    Text(heading)
                        .font(.headline)
                        .foregroundStyle(Color.boardText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(isOff ? stage.next ?? "" : stage.instruction)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOff ? Color.boardText : Color.boardGray)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                EndTripButton()
            }
            Spacer(minLength: 0)
            Divider().overlay(Color.boardGray.opacity(0.4))
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    /// "To Times Sq-42 St", "Off at Times Sq-42 St", "Walk to The Town Hall".
    private var heading: String {
        switch stage.phase {
        case .riding: isOff ? "Off at \(stage.title)" : "To \(stage.title)"
        case .fromTrain: "Walk to \(stage.title)"
        }
    }

    /// The line on the train; what to do once off it, or walking out, in the walk's blue.
    @ViewBuilder private var tile: some View {
        if stage.phase == .riding && !isOff {
            LineBullet(route: stage.route, size: 40)
        } else {
            Image(systemName: isOff ? stage.nextSymbol ?? "figure.walk" : "figure.walk")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.walkBlue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    /// On the train, the countdown to getting off and what then; after, when you'll be there.
    @ViewBuilder private var footer: some View {
        if stage.phase == .riding, !isOff, let getOff = stage.getOff {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timerInterval: date...max(date, getOff), countsDown: true)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.boardText)
                    .frame(maxWidth: 96, alignment: .leading)
                if let next = stage.next {
                    Text("Then \(next.prefix(1).lowercased() + next.dropFirst())")
                        .font(.caption)
                        .foregroundStyle(Color.boardGray)
                        .lineLimit(2)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, .red)
                    .accessibilityHidden(true)
                Text(arrival)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Tap for the turns")
                    .font(.caption)
                    .foregroundStyle(Color.boardGray)
            }
        }
    }

    /// "Arrive 8:42 AM", the heading or the step above naming where.
    private var arrival: String {
        stage.arrives.map { "Arrive \(Spoken.clock($0))" } ?? stage.endName
    }
}

#Preview("On the train", as: .systemMedium) {
    DirectionsWidget()
} timeline: {
    DirectionsEntry(date: .now, walk: .previewRiding)
    DirectionsEntry(date: .now.addingTimeInterval(13 * 60), walk: .previewRiding)
}

#Preview("Walking out", as: .systemMedium) {
    DirectionsWidget()
} timeline: {
    DirectionsEntry(date: .now, walk: .previewWalkingOut)
}

extension WalkStage {
    /// Park Slope to The Town Hall on the R, getting off at Times Sq-42 St in 12 minutes.
    static let previewRiding = WalkStage(
        phase: .riding, route: "R", title: "Times Sq-42 St", instruction: "Ride in the front",
        getOff: .now.addingTimeInterval(12 * 60), next: "Up the stairs to the NE corner of Broadway & 41 St",
        nextSymbol: "stairs", endName: "The Town Hall", arrives: .now.addingTimeInterval(16 * 60),
        expires: .now.addingTimeInterval(60 * 60))

    static let previewWalkingOut = WalkStage(
        phase: .fromTrain, route: "R", title: "The Town Hall",
        instruction: "Up the stairs to the NE corner of Broadway & 41 St", endName: "The Town Hall",
        arrives: .now.addingTimeInterval(4 * 60), expires: .now.addingTimeInterval(60 * 60))
}
