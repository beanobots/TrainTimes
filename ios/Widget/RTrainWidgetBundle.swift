import SwiftUI
import WidgetKit

@main
struct RTrainWidgetBundle: WidgetBundle {
    init() {
        // Alerts and outages shared with the app and kept a few minutes (`TrainService.sharedCache`)
        TrainService.sharedCache = SharedStore.FeedCache()
    }

    var body: some Widget {
        DirectionsWidget()
        RTrainWidget()
        TransfersWidget()
        NearbyWidget()
        TrainLiveActivity()
    }
}
