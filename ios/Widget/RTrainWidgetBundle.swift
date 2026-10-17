import SwiftUI
import WidgetKit

@main
struct RTrainWidgetBundle: WidgetBundle {
    var body: some Widget {
        RTrainWidget()
        NearbyWidget()
        TrainLiveActivity()
    }
}
