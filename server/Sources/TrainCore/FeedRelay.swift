import Foundation

/// The MTA's feeds as the server last read them: every one the app reads, read together once
/// each `POLL_SECONDS` (`refresh`, from the poller's loop), whether or not anyone's counting
/// down. The poller's countdowns and the app and widgets (`GET /feeds`) all use these copies,
/// so requests never reach the MTA. A copy older than `maxAge`, as when the MTA can't be
/// reached for a while, isn't used: the phone then tries the MTA itself.
actor FeedRelay {
    typealias Fetch = @Sendable (URL) async -> Data?

    /// Every feed the app reads, by `TrainService.feedName(of:)`: each line group's, the
    /// alerts and the elevator outages. No other address can be asked for.
    static let feeds: [String: URL] = {
        let urls = Lines.feedURLs(sharingTracksWith: Lines.filterRoutes).own + [AlertsFeed.url, OutagesFeed.url]
        return Dictionary(urls.compactMap { url in TrainService.feedName(of: url).map { ($0, url) } },
                          uniquingKeysWith: { first, _ in first })
    }()

    private let maxAge: TimeInterval
    private let fetch: Fetch
    private var copies: [URL: (data: Data, read: Date)] = [:]
    typealias Served = (data: Data, gzipped: Bool)
    /// What `served` made since the last read, as phones at the same station ask for the same,
    /// and what it's making.
    private var made: [Ask: Served] = [:]
    private var madeBytes = 0
    private var making: [Ask: Task<Served, Never>] = [:]
    /// Counts reads, so what was made from the last one isn't kept.
    private var generation = 0
    /// Beyond this many, or this many bytes, `made` starts over, so a run of different asks
    /// can't fill memory.
    private static let maxMade = 5000
    private static let maxMadeBytes = 64 << 20

    /// What a phone asks `GET /feeds` for (`served`).
    struct Ask: Hashable, Sendable {
        let name: String
        var stops: Set<String>? = nil
        var routes: Set<String>? = nil
        var gzip = false
    }

    /// `maxAge`: a read or two can fail before the last copy is dropped.
    init(interval: TimeInterval, fetch: @escaping Fetch = { await TrainService.optionalData(from: $0) }) {
        maxAge = 2 * interval + 10
        self.fetch = fetch
    }

    /// Reads every feed from the MTA, together; one that can't be read keeps its last copy.
    func refresh(now: Date = .now) async {
        let fetch = self.fetch
        let read = await withTaskGroup(of: (URL, Data?).self) { group in
            for url in Self.feeds.values {
                group.addTask { (url, await fetch(url)) }
            }
            var read: [URL: Data] = [:]
            for await (url, data) in group {
                read[url] = data
            }
            return read
        }
        for (url, data) in read {
            copies[url] = (data, now)
        }
        made = [:]
        madeBytes = 0
        making = [:]
        generation += 1
    }

    /// What `GET /feeds` sends: the feed `ask` names as last read, cut to what the phone reads
    /// (a train feed's trips at `stops`, `SubwayFeed.trimmed`; the alerts for `routes`,
    /// `AlertsFeed.trimmed`) and gzipped if asked (and it could be). A feed that won't cut is
    /// sent whole. Nil as for `feed(named:)`. Cut and gzipped off the actor, once however many
    /// ask the same at once.
    func served(_ ask: Ask, now: Date = .now) async -> Served? {
        let ask = Self.normalised(ask)
        guard let data = feed(named: ask.name, now: now) else { return nil }
        if let served = made[ask] { return served }
        if let under = making[ask] { return await under.value }
        let generation = self.generation
        let task = Task.detached { Self.cut(data, for: ask, now: now) }
        making[ask] = task
        let served = await task.value
        guard generation == self.generation else { return served }
        making[ask] = nil
        if made.count >= Self.maxMade || madeBytes + served.data.count > Self.maxMadeBytes {
            made = [:]
            madeBytes = 0
        }
        made[ask] = served
        madeBytes += served.data.count
        return served
    }

    /// `ask` without what its feed doesn't cut by (`stops` but for a train feed's, `routes` but
    /// for the alerts'), so asks for the same thing are kept as one.
    static func normalised(_ ask: Ask) -> Ask {
        var ask = ask
        let url = feeds[ask.name]
        if url == AlertsFeed.url || url == OutagesFeed.url { ask.stops = nil }
        if url != AlertsFeed.url { ask.routes = nil }
        return ask
    }

    private static func cut(_ data: Data, for ask: Ask, now: Date) -> Served {
        var cut = data
        if let stops = ask.stops {
            cut = (try? SubwayFeed.trimmed(data, toStops: stops)) ?? data
        } else if let routes = ask.routes {
            // The phone keeps what's in effect within the hour; this allows for its clock
            cut = (try? AlertsFeed.trimmed(data, toRoutes: routes, activeFrom: now.addingTimeInterval(-15 * 60),
                                           to: now.addingTimeInterval(2 * 60 * 60))) ?? data
        }
        let gzipped = ask.gzip ? try? Gzip.compress(cut) : nil
        return (gzipped ?? cut, gzipped != nil)
    }

    /// The ids in a comma-separated list (`stops`, `routes`); nil if there are too many, or one
    /// isn't a stop or route id (1 to 8 letters and digits).
    static func ids(in list: String) -> Set<String>? {
        let ids = list.split(separator: ",").map(String.init)
        guard ids.count <= 500, ids.allSatisfy({ (1...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }) else {
            return nil
        }
        return Set(ids)
    }

    /// The feed called `name`, as last read; nil if there's no such feed, or no recent copy.
    func feed(named name: String, now: Date = .now) -> Data? {
        Self.feeds[name].flatMap { current(now: now)[$0] }
    }

    /// Every feed with a recent copy.
    func current(now: Date = .now) -> [URL: Data] {
        copies.filter { $0.value.read.isWithin(maxAge, before: now) }.mapValues(\.data)
    }
}
