import SwiftUI

/// The app only exists to carry the widget; it explains how to add it.
@main
struct RTrainApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 18) {
            Text("R")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Color(red: 252 / 255, green: 204 / 255, blue: 10 / 255)))
            Text("Next R train")
                .font(.largeTitle.bold())
            Text("Prospect Av, toward Manhattan")
                .foregroundStyle(.secondary)
            Text("To add the widget, touch and hold the Home Screen, tap Edit, then Add Widget, and choose Next R train.")
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
        .padding(32)
    }
}
