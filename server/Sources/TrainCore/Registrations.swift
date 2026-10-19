import Foundation

/// Which APNs servers a token belongs to: a build from Xcode gets sandbox
/// tokens, TestFlight and the App Store production ones.
enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production
}

/// One running countdown on a phone, and what was last pushed to it.
struct Registration: Sendable, Equatable {
    /// The Live Activity's push token, in lowercase hex.
    var token: String
    /// The attest key that registered it (`Owner.secret` with ATTEST_MODE=off);
    /// only it can delete it.
    var owner: String
    var environment: PushEnvironment
    var selection: Selection
    /// The trip the app started counting down to; the last state's trip once there is one.
    var trip: String
    /// When the countdown started, for ending it once iOS would.
    var started: Date
    /// The app's Settings choice of alerts to mention.
    var alertKinds: Set<ServiceAlert.Kind>?
    /// New with every registration of the token, so a poll that began before
    /// it was registered again doesn't record its push against the new one.
    var revision: UUID
    var lastState: ContentState? = nil
    var lastPush: Date? = nil

    var settings: AppSettings {
        var settings = AppSettings()
        if let alertKinds { settings.alertKinds = alertKinds }
        return settings
    }

    var ends: Date { started.addingTimeInterval(ActivityState.lifetime) }

    /// The token's first few characters, for logs.
    var tokenPrefix: String { Self.prefix(of: token) }

    static func prefix(of token: String) -> String { String(token.prefix(8)) + "…" }

    /// Lowercase hex, or nil when `text` isn't a plausible push token. Tokens
    /// only ever go into the APNs URL and the database.
    static func normalizedToken(_ text: String) -> String? {
        let token = text.lowercased()
        guard (32...512).contains(token.utf8.count), token.utf8.count.isMultiple(of: 2),
              token.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                  || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }) else { return nil }
        return token
    }
}

enum Owner {
    /// Registrations made with API_SECRET, when App Attest is off.
    static let secret = "api-secret"
    /// Registrations moved over from registrations.json, made before owners.
    static let legacy = "legacy"
}

/// What the app POSTs to /activities.
struct RegistrationRequest: Decodable, Sendable {
    var token: String
    var environment: PushEnvironment
    /// As the app encodes `Selection`.
    var selection: Selection
    var trip: String
    /// Seconds since 2001, as `JSONEncoder` writes a `Date` by default.
    var started: Date?
    /// `AppSettings.alertKinds`, as the app encodes it: `[0, 1, 2, 3]`.
    var alertKinds: Set<ServiceAlert.Kind>?
}

/// What a poll did to a registration, saved in one transaction per poll.
enum PushOutcome: Sendable, Equatable {
    case pushed(token: String, revision: UUID, state: ContentState, at: Date)
    case drop(token: String, revision: UUID)
}

/// Registrations and attest keys, in SQLite (WAL) in the data directory. The
/// registrations are also kept in memory, for the poll.
actor Store {
    static let fileName = "traintimes.sqlite"
    static let legacyFileName = "registrations.json"

    private let db: SQLite
    private var registrations: [String: Registration] = [:]
    private var tokensByOwner: [String: Set<String>] = [:]

    /// With no `directory`, everything's in memory (for tests).
    init(directory: URL?) throws {
        if let directory {
            let file = directory.appendingPathComponent(Self.fileName)
            db = try SQLite(path: file.path)
            try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else {
            db = try SQLite(path: ":memory:")
        }
        try Self.migrateSchema(db)
        var loaded = try Self.loadRegistrations(db)
        if let directory {
            loaded += try Self.migrateLegacyFile(in: directory, db: db, existing: Set(loaded.map(\.token)))
        }
        registrations = Dictionary(loaded.map { ($0.token, $0) }, uniquingKeysWith: { _, last in last })
        tokensByOwner = Dictionary(grouping: loaded, by: \.owner).mapValues { Set($0.map(\.token)) }
    }

    private static func migrateSchema(_ db: SQLite) throws {
        let version = try db.query("PRAGMA user_version").first?.first?.integer ?? 0
        guard version < 1 else { return }
        try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS registrations (
                    token TEXT PRIMARY KEY,
                    owner TEXT NOT NULL,
                    environment TEXT NOT NULL,
                    selection BLOB NOT NULL,
                    trip TEXT NOT NULL,
                    started REAL NOT NULL,
                    alert_kinds BLOB,
                    revision TEXT NOT NULL,
                    last_state BLOB,
                    last_push REAL
                );
                CREATE INDEX IF NOT EXISTS registrations_owner ON registrations (owner);
                CREATE TABLE IF NOT EXISTS attest_keys (
                    key_id TEXT PRIMARY KEY,
                    public_key BLOB NOT NULL,
                    counter INTEGER NOT NULL,
                    environment TEXT NOT NULL,
                    created REAL NOT NULL,
                    last_used REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS attest_keys_last_used ON attest_keys (last_used);
                PRAGMA user_version = 1;
                """)
        }
    }

    // MARK: Registrations

    var all: [Registration] { Array(registrations.values) }

    var count: Int { registrations.count }

    func registration(for token: String) -> Registration? { registrations[token] }

    func count(ownedBy owner: String) -> Int { tokensByOwner[owner]?.count ?? 0 }

    enum UpsertResult: Equatable {
        /// With the tokens of the owner's oldest registrations dropped to make room.
        case saved(evicted: [String])
        /// MAX_REGISTRATIONS reached.
        case full
        /// The token is another key's.
        case ownedByOther
    }

    /// Adds or replaces a registration. An owner at `maxPerOwner` loses its
    /// oldest ones: the app counts down to one train at a time, and one it
    /// couldn't unregister mustn't stop it registering the next.
    func upsert(_ registration: Registration, maxTotal: Int, maxPerOwner: Int) throws -> UpsertResult {
        let existing = registrations[registration.token]
        if let existing, existing.owner != registration.owner { return .ownedByOther }
        let others = (tokensByOwner[registration.owner] ?? []).subtracting([registration.token])
            .compactMap { registrations[$0] }
            .sorted { $0.started < $1.started }
        let evicted = others.prefix(max(0, others.count - (maxPerOwner - 1))).map(\.token)
        // Full only if it adds one: replacing a token, or dropping one of the owner's to make room, doesn't
        if existing == nil, registrations.count - evicted.count >= maxTotal { return .full }
        try db.transaction {
            try Self.delete(evicted, from: db)
            try write(registration)
        }
        for token in evicted { unindex(token) }
        unindex(registration.token)
        index(registration)
        return .saved(evicted: evicted)
    }

    enum RemoveResult: Equatable { case removed, notFound, notOwner }

    func remove(_ token: String, owner: String) throws -> RemoveResult {
        guard let existing = registrations[token] else { return .notFound }
        guard existing.owner == owner else { return .notOwner }
        try Self.delete([token], from: db)
        unindex(token)
        return .removed
    }

    /// A poll's pushes and drops, in one transaction. Each applies only if the
    /// token hasn't been registered again since the poll read it.
    func apply(_ outcomes: [PushOutcome]) throws {
        guard !outcomes.isEmpty else { return }
        var changed: [Registration] = []
        var dropped: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .pushed(let token, let revision, let state, let date):
                guard var registration = registrations[token], registration.revision == revision else { continue }
                registration.lastState = state
                registration.lastPush = date
                registration.trip = state.trip
                changed.append(registration)
            case .drop(let token, let revision):
                guard registrations[token]?.revision == revision else { continue }
                dropped.append(token)
            }
        }
        let encoder = JSONEncoder()
        try db.transaction {
            for registration in changed {
                try db.query("UPDATE registrations SET last_state = ?, last_push = ?, trip = ? WHERE token = ?", [
                    .blob(try encoder.encode(registration.lastState)),
                    .real(registration.lastPush?.timeIntervalSinceReferenceDate ?? 0),
                    .text(registration.trip), .text(registration.token),
                ])
            }
            try Self.delete(dropped, from: db)
        }
        for registration in changed { registrations[registration.token] = registration }
        for token in dropped { unindex(token) }
    }

    /// Deletes the tokens' rows, and only those: the caller unindexes them
    /// once that's committed.
    private static func delete(_ tokens: [String], from db: SQLite) throws {
        for token in tokens {
            try db.query("DELETE FROM registrations WHERE token = ?", [.text(token)])
        }
    }

    private func write(_ registration: Registration) throws {
        try Self.write(registration, to: db)
    }

    private static func write(_ registration: Registration, to db: SQLite) throws {
        let encoder = JSONEncoder()
        try db.query("""
            INSERT OR REPLACE INTO registrations
                (token, owner, environment, selection, trip, started, alert_kinds, revision, last_state, last_push)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
            .text(registration.token), .text(registration.owner), .text(registration.environment.rawValue),
            .blob(try encoder.encode(registration.selection)), .text(registration.trip),
            .real(registration.started.timeIntervalSinceReferenceDate),
            try registration.alertKinds.map { .blob(try encoder.encode($0)) } ?? .null,
            .text(registration.revision.uuidString),
            try registration.lastState.map { .blob(try encoder.encode($0)) } ?? .null,
            registration.lastPush.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null,
        ])
    }

    /// Each row on its own, so one this build can't read doesn't stop the
    /// server starting: a row it can't read (a selection that doesn't decode,
    /// say) is deleted, and alert kinds or a last state it can't read are left
    /// out (the next pass then pushes afresh).
    private static func loadRegistrations(_ db: SQLite) throws -> [Registration] {
        let decoder = JSONDecoder()
        var loaded: [Registration] = []
        var unreadable: [String] = []
        for row in try db.query("""
            SELECT token, owner, environment, selection, trip, started, alert_kinds, revision, last_state, last_push
            FROM registrations
            """) {
            guard let token = row[0].text else { continue }
            guard let owner = row[1].text,
                  let environment = row[2].text.flatMap(PushEnvironment.init(rawValue:)),
                  let selection = row[3].blob.flatMap({ try? decoder.decode(Selection.self, from: $0) }),
                  let trip = row[4].text, let started = row[5].real,
                  let revision = row[7].text.flatMap(UUID.init(uuidString:)) else {
                unreadable.append(token)
                continue
            }
            let alertKinds = row[6].blob.flatMap { try? decoder.decode(Set<ServiceAlert.Kind>.self, from: $0) }
            let lastState = row[8].blob.flatMap { try? decoder.decode(ContentState.self, from: $0) }
            var lost: [String] = []
            if alertKinds == nil, row[6].blob != nil { lost.append("alert kinds") }
            if lastState == nil, row[8].blob != nil { lost.append("last state") }
            if !lost.isEmpty {
                Log.error("load \(Registration.prefix(of: token)): left out its \(lost.joined(separator: " and ")), which couldn't be read")
            }
            loaded.append(Registration(
                token: token, owner: owner, environment: environment, selection: selection, trip: trip,
                started: Date(timeIntervalSinceReferenceDate: started), alertKinds: alertKinds, revision: revision,
                lastState: lastState, lastPush: row[9].real.map(Date.init(timeIntervalSinceReferenceDate:))
            ))
        }
        if !unreadable.isEmpty {
            try db.transaction { try delete(unreadable, from: db) }
            for token in unreadable {
                Log.error("drop \(Registration.prefix(of: token)): couldn't read it from \(fileName)")
            }
        }
        return loaded
    }

    private func index(_ registration: Registration) {
        registrations[registration.token] = registration
        tokensByOwner[registration.owner, default: []].insert(registration.token)
    }

    private func unindex(_ token: String) {
        guard let registration = registrations.removeValue(forKey: token) else { return }
        tokensByOwner[registration.owner]?.remove(token)
        if tokensByOwner[registration.owner]?.isEmpty == true { tokensByOwner[registration.owner] = nil }
    }

    // MARK: registrations.json, from before the database

    /// The shape registrations.json had. Alert kinds or a last state this build
    /// can't read are left out, as they are from the database.
    private struct LegacyRegistration: Decodable {
        var token: String
        var environment: PushEnvironment
        var selection: Selection
        var trip: String
        var started: Date
        var alertKinds: Set<ServiceAlert.Kind>?
        var revision: UUID
        var lastState: ContentState?
        var lastPush: Date?

        private enum CodingKeys: String, CodingKey {
            case token, environment, selection, trip, started, alertKinds, revision, lastState, lastPush
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = try container.decode(String.self, forKey: .token)
            environment = try container.decode(PushEnvironment.self, forKey: .environment)
            selection = try container.decode(Selection.self, forKey: .selection)
            trip = try container.decode(String.self, forKey: .trip)
            started = try container.decode(Date.self, forKey: .started)
            alertKinds = try? container.decodeIfPresent(Set<ServiceAlert.Kind>.self, forKey: .alertKinds)
            revision = try container.decode(UUID.self, forKey: .revision)
            lastState = try? container.decodeIfPresent(ContentState.self, forKey: .lastState)
            lastPush = try container.decodeIfPresent(Date.self, forKey: .lastPush)
        }
    }

    /// One of registrations.json's entries, or nil when it can't be read.
    private struct LegacyEntry: Decodable {
        var registration: LegacyRegistration?

        init(from decoder: any Decoder) throws {
            registration = try? LegacyRegistration(from: decoder)
        }
    }

    /// Moves registrations.json's registrations into the database, then deletes
    /// it. Entries that can't be read are dropped; a file that can't be read is left as it is.
    private static func migrateLegacyFile(in directory: URL, db: SQLite, existing: Set<String>) throws -> [Registration] {
        let file = directory.appendingPathComponent(legacyFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let entries = try? JSONDecoder().decode([LegacyEntry].self, from: Data(contentsOf: file)) else {
            Log.error("couldn't read \(legacyFileName), so left it in \(directory.path)")
            return []
        }
        let legacy = entries.compactMap(\.registration)
        if legacy.count < entries.count {
            Log.error("dropped \(entries.count - legacy.count) registrations from \(legacyFileName) that couldn't be read")
        }
        let moved = legacy.filter { !existing.contains($0.token) }.map { old in
            Registration(token: old.token, owner: Owner.legacy, environment: old.environment, selection: old.selection,
                         trip: old.trip, started: old.started, alertKinds: old.alertKinds, revision: old.revision,
                         lastState: old.lastState, lastPush: old.lastPush)
        }
        try db.transaction {
            for registration in moved { try write(registration, to: db) }
        }
        try FileManager.default.removeItem(at: file)
        Log.info("migrated \(moved.count) registrations from \(legacyFileName) into \(fileName)")
        return moved
    }

    // MARK: Attest keys

    /// False if the key is already known.
    func addKey(_ key: AttestKey) throws -> Bool {
        try db.query("""
            INSERT OR IGNORE INTO attest_keys (key_id, public_key, counter, environment, created, last_used)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [
            .text(key.id), .blob(key.publicKey), .integer(Int64(key.counter)), .text(key.environment.rawValue),
            .real(key.created.timeIntervalSinceReferenceDate), .real(key.lastUsed.timeIntervalSinceReferenceDate),
        ])
        return db.changes == 1
    }

    func key(id: String) throws -> AttestKey? {
        guard let row = try db.query("""
            SELECT key_id, public_key, counter, environment, created, last_used FROM attest_keys WHERE key_id = ?
            """, [.text(id)]).first,
            let keyID = row[0].text, let publicKey = row[1].blob, let counter = row[2].integer,
            let environment = row[3].text.flatMap(AttestEnvironment.init(rawValue:)),
            let created = row[4].real, let lastUsed = row[5].real else { return nil }
        return AttestKey(id: keyID, publicKey: publicKey, counter: UInt32(clamping: counter), environment: environment,
                         created: Date(timeIntervalSinceReferenceDate: created),
                         lastUsed: Date(timeIntervalSinceReferenceDate: lastUsed))
    }

    func keyCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM attest_keys").first?.first?.integer ?? 0)
    }

    /// Stores an assertion's counter if it's still above the stored one, so two
    /// requests can't both use the same counter. False if it isn't.
    func advanceCounter(keyID: String, to counter: UInt32, now: Date) throws -> Bool {
        try db.query("UPDATE attest_keys SET counter = ?, last_used = ? WHERE key_id = ? AND counter < ?", [
            .integer(Int64(counter)), .real(now.timeIntervalSinceReferenceDate), .text(keyID), .integer(Int64(counter)),
        ])
        return db.changes == 1
    }

    /// Forgets keys unused since `date`, and anything they registered. Returns how many.
    func purgeKeys(unusedSince date: Date) throws -> Int {
        let stale = try db.query("SELECT key_id FROM attest_keys WHERE last_used < ?",
                                 [.real(date.timeIntervalSinceReferenceDate)]).compactMap { $0.first?.text }
        guard !stale.isEmpty else { return 0 }
        try db.transaction {
            for keyID in stale {
                try db.query("DELETE FROM registrations WHERE owner = ?", [.text(keyID)])
                try db.query("DELETE FROM attest_keys WHERE key_id = ?", [.text(keyID)])
            }
        }
        for keyID in stale {
            for token in tokensByOwner[keyID] ?? [] { unindex(token) }
        }
        return stale.count
    }
}
