import SwiftUI

@main
struct TrainTimesAdminApp: App {
    @State private var model = ServerModel()

    var body: some Scene {
        Window("Train Times Server", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 760)
    }
}
