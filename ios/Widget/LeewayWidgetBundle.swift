import SwiftUI
import WidgetKit

@main
struct LeewayWidgetBundle: WidgetBundle {
    init() {
        // Alerts and outages shared with the app and kept a few minutes (`TrainService.sharedCache`)
        TrainService.sharedCache = SharedStore.FeedCache()
    }

    var body: some Widget {
        DirectionsWidget()
        LeewayWidget()
        TransfersWidget()
        NearbyWidget()
        TrainLiveActivity()
    }
}
