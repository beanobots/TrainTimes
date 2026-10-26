import BackgroundTasks
import OSLog

extension TimetableStore {
    /// As in project.yml's BGTaskSchedulerPermittedIdentifiers.
    static let refreshTaskID = "com.rtrainwidget.app.timetable"

    private static let log = Logger(subsystem: "com.rtrainwidget.app", category: "Timetable")

    /// The background refresh: a new timetable, and another refresh a day on.
    static func backgroundRefresh() async {
        await refresh()
        scheduleRefresh()
    }

    /// Asks iOS for a background refresh when the downloaded one's due, so it stays current
    /// while the app isn't opened.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        // iOS decides when, after this
        request.earliestBeginDate = .now.addingTimeInterval(refreshAfter)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.notice("Couldn't schedule a timetable refresh: \(error.localizedDescription, privacy: .public)")
        }
    }
}
