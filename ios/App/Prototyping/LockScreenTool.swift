import SwiftUI
import WidgetKit

/// Checks the Lock Screen's countdowns and widgets: starts a made-up countdown (`TestActivity`)
/// that then changes with the phone locked, by itself as iOS redraws it or from the app.
struct LockScreenTool: View {
    @State private var test = TestActivity.shared
    @State private var kind = TestActivity.Kind.walk
    @State private var reloaded = false

    var body: some View {
        Form {
            Section {
                Text("Start one below, then lock the phone with the side button and wake it without unlocking. Unlocking brings the app back, which is fine: the made-up countdown is left alone.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("How")
            }

            Section {
                Button("Train Due in 20 s") {
                    Task { await test.start(.train, dueIn: 20) }
                }
                Button("Bus Due in 20 s") {
                    Task { await test.start(.bus, dueIn: 20) }
                }
                Button("On the Train, Off in 1 min") {
                    Task { await test.start(.walk, step: 3) }
                }
            } header: {
                Text("Changes by Itself")
            } footer: {
                Text("iOS redraws it as it goes stale, the app asleep: counts to 0:00, \"At Station\" (a bus \"At Stop\"), then the next. On the train, what to do once off.")
            }

            Section {
                Picker("Countdown", selection: $kind) {
                    ForEach(TestActivity.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                Button("Start, Change in 10 s") {
                    Task {
                        await test.start(kind)
                        if test.kind == kind { test.change(in: 10) }
                    }
                }
                if test.kind != nil {
                    Button("Change in 10 s") { test.change(in: 10) }
                }
                if let changesAt = test.changesAt {
                    Text("Changes \(Text(timerInterval: Date.now...max(changesAt, .now), countsDown: true))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Changed by the App")
            } footer: {
                Text("A walk's next step, else a minute sooner, posted from the app while locked, as a walk's turns are. Walks draw the turn's map a moment after each step.")
            }

            Section {
                Button(reloaded ? "Reloaded" : "Reload All Widgets") {
                    WidgetCenter.shared.reloadAllTimelines()
                    reloaded = true
                }
                .disabled(reloaded)
            } header: {
                Text("Lock Screen Widgets")
            } footer: {
                Text("Every widget fetches again, Lock Screen ones too. Each reload counts against iOS's daily allowance.")
            }

            Section {
                Button("End All", role: .destructive) {
                    Task { await test.endAll() }
                }
            }

            if let message = test.message {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { test.adopt() }
    }
}

#Preview {
    NavigationStack { LockScreenTool() }
}
