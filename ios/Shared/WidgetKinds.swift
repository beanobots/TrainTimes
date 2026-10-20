import WidgetKit

/// The kinds of the widgets that show a saved widget's train, which reloads and
/// the app's count of placed widgets go by. Trains near you's is
/// `Nearby.widgetKind`.
enum WidgetKind {
    /// Next train.
    static let train = "RTrainWidget"
    static let transfers = "TransfersWidget"
}

extension WidgetCenter {
    /// Reloads the Next train and Transfers widgets, which show the saved
    /// widgets' trains and the countdown; not Trains near you, which would
    /// find you again and fetch every line near you for nothing.
    func reloadTrainWidgets() {
        reloadTimelines(ofKind: WidgetKind.train)
        reloadTimelines(ofKind: WidgetKind.transfers)
    }
}
