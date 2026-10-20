import Foundation
import TrainResources

// What the symlinked app files in Shared/ need from parts of the app that
// aren't shared with the server, so that those files compile unchanged.

/// Stands in for Foundation's `Bundle` in this module: Stations.swift and
/// Outages.swift load their JSON from `Bundle.main`, which for the server is
/// the package's resource bundle. Nothing else in TrainCore uses `Bundle`.
enum Bundle {
    static var main: Foundation.Bundle { trainResourcesBundle }
}

/// The app's Settings (ios/Shared/SharedStore.swift), with only what the
/// countdown goes by: the kinds of alert it mentions. The app sends its
/// choice when it registers the countdown; by default, all of them.
struct AppSettings: Hashable, Sendable {
    var alertKinds: Set<ServiceAlert.Kind> = Set(ServiceAlert.Kind.allCases)
}
