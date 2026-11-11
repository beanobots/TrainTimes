import BackgroundTasks
import OSLog

extension TimetableStore {
    /// As in project.yml's BGTaskSchedulerPermittedIdentifiers.
    static let refreshTaskID = "dev.dctp.leeway.timetable"

    private static let log = AppLog(category: "Timetable")

    /// The background refresh: a new timetable, the buses' too if it's due, and another refresh
    /// a day on.
    static func backgroundRefresh() async {
        await refreshAll()
        scheduleRefresh()
    }

    /// The subway's timetable and the buses', each if it's due.
    static func refreshAll() async {
        await refresh()
        await buses.refresh()
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
            log.notice("Couldn't schedule a timetable refresh: \(error.localizedDescription)")
        }
    }
}
