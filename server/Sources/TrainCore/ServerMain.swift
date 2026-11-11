import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

public enum ServerMain {
    static let usage = """
        Usage:
          TrainTimesServer                     serve, configured by environment variables
          TrainTimesServer send-test --token <hex> [--environment sandbox|production]
                                               push a sample countdown (train in 5 min) to one Live Activity
        """

    /// Runs the command in `arguments` and returns the exit status.
    public static func run(arguments: [String], environment: [String: String]) async -> Int32 {
        let command = Array(arguments.dropFirst())
        do {
            switch command.first {
            case nil:
                try await serve(Config(environment: environment))
                return 0
            case "send-test":
                return try await sendTest(options: Array(command.dropFirst()), environment: environment)
            case "-h", "--help", "help":
                print(usage)
                return 0
            default:
                print(usage)
                return 64
            }
        } catch {
            Log.error(String(describing: error))
            return 1
        }
    }

    private static func serve(_ config: Config) async throws {
        guard !StationDirectory.platforms.isEmpty, !EquipmentDirectory.all.isEmpty else {
            throw Config.Problem(description: "stations.json or equipment.json didn't load from the resource bundle")
        }
        try FileManager.default.createDirectory(at: config.dataDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.dataDirectory.path)
        let store = try Store(directory: config.dataDirectory)
        let pusher = try APNSPusher(config: config.apns)
        // Read once each tick, for the countdowns and for the app and widgets
        let feeds = FeedRelay(interval: config.pollInterval)
        // Bus Time's next buses, for the bus rides in those routes and bus countdowns, with a key
        let buses = config.busTimeKey.map { key in
            BusTime(key: key, perClientPerDay: config.limits.busTimePerIPPerDay, perDay: config.limits.busTimePerDay)
        }
        let poller = Poller(store: store, pusher: pusher, interval: config.pollInterval, timing: config.pushTiming,
                            concurrency: config.pushConcurrency, keyRetention: config.limits.keyRetention,
                            logPushes: config.logPushes, feeds: feeds, buses: buses.map(Poller.liveBuses(from:)),
                            boards: Poller.liveBoards(from: feeds))
        // Built each day, for the app to fall back on when the MTA can't be reached: the subway's
        // week, and for phones saving it for offline its month and the buses' week. From the
        // GTFS zips kept in DATA_DIR/gtfs, downloaded again only once they've changed
        let timetable = TimetableCopy()
        let monthTimetable = TimetableCopy()
        let busTimetable = TimetableCopy()
        let gtfs = config.dataDirectory.appendingPathComponent("gtfs")
        let makers = [
            TimetableMaker(copy: timetable, directory: config.dataDirectory) {
                try await TimetableBuilder.downloadSubway(now: $0, keptIn: gtfs)
            },
            TimetableMaker(copy: monthTimetable, directory: config.dataDirectory, file: "timetable-30.bin",
                           name: "timetable-30", hour: 4, minute: 30) {
                try await TimetableBuilder.downloadSubway(days: 30, now: $0, keptIn: gtfs)
            },
            TimetableMaker(copy: busTimetable, directory: config.dataDirectory, file: "bus-timetable.bin",
                           name: "bus timetable", hour: 5) { try await TimetableBuilder.downloadBuses(now: $0, keptIn: gtfs) },
        ]
        // Trips planned on the subway's and buses' timetables, for New Trip and directions
        // shared to the app
        let routes = TransitRoutes(perClientPerDay: config.limits.routesPerIPPerDay, perDay: config.limits.routesPerDay,
                                   subway: timetable, buses: busTimetable)
        // Crash and hang reports from phones sharing diagnostics
        let diagnostics = try DiagnosticStore(directory: config.dataDirectory, maxReports: config.limits.maxDiagnostics)
        let services = HTTPServices(store: store, auth: config.auth, appID: config.appID, limits: config.limits,
                                    feeds: feeds, timetable: timetable, monthTimetable: monthTimetable,
                                    busTimetable: busTimetable, routes: routes, buses: buses,
                                    diagnostics: diagnostics)

        let authDescription: String
        switch config.auth {
        case .attest(let environments):
            authDescription = "App Attest (\(environments.map(\.rawValue).sorted().joined(separator: ", "))) for \(config.appID)"
        case .secret:
            authDescription = "API_SECRET (ATTEST_MODE=off: for development only)"
        }

        var logger = Logger(label: "TrainTimesServer")
        logger.logLevel = .warning
        var background: [any Service] = [poller] + makers + [DiagnosticPruner(store: diagnostics)]
        if let logFile = config.logFile { background.append(LogReopener(path: logFile)) }
        let app = Application(
            router: HTTPRoutes.router(services),
            // A connection that sits there sending nothing is closed, not held open for good
            server: .http1(configuration: .init(idleTimeout: .seconds(30))),
            configuration: configuration(for: config),
            services: background,
            onServerRunning: { channel in
                Log.info("listening on \(channel.localAddress?.description ?? "\(config.host):\(config.port)")")
            },
            logger: logger
        )
        Log.info("start: \(await store.count) registrations, \(try await store.keyCount()) attest keys, "
            + "polling every \(Int(config.pollInterval)) s, \(config.pushConcurrency) pushes at a time, "
            + "pushing when a train is over \(Int(config.pushTiming.earlier)) s earlier or \(Int(config.pushTiming.later)) s later, "
            + "a following one \(Int(config.pushTiming.following)) s, refreshing after \(Int(config.pushTiming.refresh)) s, "
            + "auth \(authDescription), "
            + "routes up to \(config.limits.routesPerIPPerDay) a client and \(config.limits.routesPerDay) a day"
            + (buses == nil ? ", no Bus Time (no BUS_TIME_API_KEY)"
                : ", Bus Time up to \(config.limits.busTimePerIPPerDay) a client and \(config.limits.busTimePerDay) a day"))
        do {
            try await app.runService()
        } catch {
            await pusher.shutdown()
            throw error
        }
        await pusher.shutdown()
        Log.info("stop")
    }

    /// HOST and PORT, and no Server header.
    static func configuration(for config: Config) -> ApplicationConfiguration {
        .init(address: .hostname(config.host, port: config.port), serverName: nil)
    }

    private static func sendTest(options: [String], environment: [String: String]) async throws -> Int32 {
        var token: String?
        var pushEnvironment = PushEnvironment.sandbox
        var rest = options[...]
        while let option = rest.popFirst() {
            switch option {
            case "--token":
                token = rest.popFirst()
            case "--environment":
                guard let value = rest.popFirst().flatMap(PushEnvironment.init(rawValue:)) else {
                    print("--environment is sandbox or production")
                    return 64
                }
                pushEnvironment = value
            default:
                print(usage)
                return 64
            }
        }
        guard let token = token.flatMap(Registration.normalizedToken) else {
            print("--token needs a Live Activity push token, in hex")
            return 64
        }

        let pusher = try APNSPusher(config: APNSConfig(environment: environment))
        let now = Date.now
        let state = sampleState(now: now)
        let push = Push(token: token, environment: pushEnvironment, event: .update, state: state, priority: 10,
                        timestamp: now, staleDate: ActivityState.staleDate(for: state))
        let result = await pusher.send(push)
        await pusher.shutdown()
        switch result {
        case .sent:
            Log.info("send-test \(Registration.prefix(of: token)) \(pushEnvironment.rawValue): sent")
            return 0
        case .invalidToken(let reason), .failed(let reason):
            Log.error("send-test \(Registration.prefix(of: token)) \(pushEnvironment.rawValue): \(reason)")
            return 1
        }
    }

    /// An R to Bay Ridge in 5 minutes, then two more.
    static func sampleState(now: Date) -> ContentState {
        ContentState(
            train: now.addingTimeInterval(5 * 60),
            trip: "send-test",
            isLive: true,
            terminal: "Bay Ridge-95 St",
            following: [now.addingTimeInterval(12 * 60), now.addingTimeInterval(20 * 60)],
            notice: nil,
            updated: now,
            route: "R",
            followingRoutes: ["R", "R"]
        )
    }
}
